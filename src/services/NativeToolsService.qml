import QtQuick
import Quickshell.Io
import "../lib/WebTools.js" as WebTools
import "../lib/ShellTools.js" as ShellTools
import "../lib/FileTools.js" as FileTools
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/Providers.js" as Providers

  // Native chat tools executor (web_search + webfetch + take_screenshot +
  // run_command): one process at a time, curl config via stdin. All
  // validation, parsing and shell policy live in the JS libs; this file
  // is transport, approval hold and delivery only.
Item {
    id: root

    // Assigned by NexusService: (callId, modelText, images) — text the
    // model sees, plus an optional [{mime, data}] image array (screen
    // capture only; null for the web tools).
    property var onResult: null
    // Assigned by NexusService: (callId, errorText).
    property var onError: null
    // Shell tool: (callId, request) when a command needs the user's
    // permission; the job stays held until answerApproval(callId, …).
    property var onApprovalNeeded: null
    property var _queue: []            // {callId, toolName, args, policy}
    property bool _busy: false
    property int _currentId: -1
    property string _currentTool: ""
    property var _currentArgs: null
    property string _stdin: ""
    // Per-job stdout cap: curl downloads keep the 4 MB guard; a screen
    // capture is a base64 image and gets its own, larger cap; shell
    // output is capped hard (hitting it kills the command).
    property int _maxBytes: 4 * 1024 * 1024
    // Escape hatch for a hung job. A normal capture is sub-second;
    // StreamingService.cancel() (Stop) only stops its own stream, so a
    // wedged compositor call would otherwise block the tool loop forever.
    property int _jobTimeoutMs: 60000

    // ── Shell (run_command) state ─────────────────────────────────
    property var _policy: null          // {yolo, home}
    property var _shellMeta: null       // {command, cwd, timeoutSeconds}
    property string _shellKilled: ""    // "" | "cap" | "timeout"
    property real _shellStarted: 0
    // StdioCollector.text is replaced per process but keeps the PREVIOUS
    // job's text when the new process prints nothing — a flag set by the
    // first chunk is the only honest way to tell "no output" from "stale
    // output".
    property bool _shellSawChunk: false
    property bool _awaitingApproval: false
    property var _approvalRequest: null
    // A held permission request must not outlive the user's patience.
    readonly property int _approvalTimeoutMs: 180000

    // ── File tools state ──────────────────────────────────────────
    // One phase machine per job: stat → (read|diff|approval) → write.
    property var _fileMeta: null      // {tool, path, args}
    property string _filePhase: ""    // stat|read|readForDiff|reread|write|move
    property int _fileSize: -1        // -1 = missing
    property string _fileSnapshot: "" // content the diff was computed from
    property var _fileEdit: null      // {count, oldLines, newLines, diff}
    property string _pendingWrite: ""
    // StdioCollector.text keeps the previous job's text when a read
    // produces nothing — a chunk flag is the only honest signal.
    property bool _fileSawChunk: false
    readonly property string _tmpSuffix: ".nexus-tmp"

    function execute(callId, toolName, argsJson, policy) {
        _queue.push({ callId: callId, toolName: String(toolName || ""),
                      args: Providers.parseToolArgs(argsJson),
                      policy: policy || null });
        _pump();
    }

    function _pump() {
        if (_busy || _queue.length === 0) return;
        // Previous process still dying (async exit): starting now would
        // skip the stdin write and hang the job. Queue it; onExited
        // drains the queue.
        if (fetcher.running) return;
        var job = _queue.shift();
        // Claim the id first so even an invalid-args rejection is
        // delivered against the right callId.
        _currentId = job.callId;
        _currentTool = job.toolName;
        if (job.toolName === "run_command") {
            _busy = true;
            _startShellJob(job);
            return;
        }
        if (FileTools.isNativeTool(job.toolName)) {
            _busy = true;
            _startFileJob(job);
            return;
        }
        var req;
        if (job.toolName === "web_search")
            req = WebTools.buildSearchRequest(job.args);
        else if (job.toolName === "webfetch")
            req = WebTools.buildFetchRequest(job.args);
        else if (job.toolName === "take_screenshot")
            req = WebTools.buildScreenshotRequest(job.args);
        else
            // Never guess a tool: an unknown name must not silently
            // become a screen capture.
            req = { ok: false, error: "Unknown native tool: " + job.toolName };
        if (!req || !req.ok) {
            _deliverError(req && req.error ? req.error : "Unknown native tool");
            return;
        }
        _busy = true;
        _currentArgs = req.args || job.args;
        _stdin = req.config || "";
        _maxBytes = job.toolName === "take_screenshot"
            ? WebTools.MAX_SCREENSHOT_BYTES : 4 * 1024 * 1024;
        _jobTimeoutMs = job.toolName === "take_screenshot" ? 60000 : 0;
        collector.lastLen = 0;        // re-arm: collector text accumulates
        fetcher.stdinEnabled = _stdin.length > 0;  // re-arm per request
        fetcher.workingDirectory = "";
        fetcher.command = req.cmd;
        fetcher.running = true;
        if (_jobTimeoutMs > 0) jobTimer.start();
    }

    // ── Shell (run_command) ───────────────────────────────────────

    // Validate, then either run (policy says auto), or hold the job and
    // ask the user. `_busy` is already true: this job owns the service.
    function _startShellJob(job) {
        var v = ShellTools.validateArgs(job.args);
        if (!v.ok) { _deliverError(v.error); return; }
        var policy = job.policy || {};
        _policy = policy;
        var cwd = v.args.cwd || String(policy.home || "/");
        _shellMeta = { command: v.args.command, cwd: cwd,
                       timeoutSeconds: v.args.timeoutSeconds };
        _shellKilled = "";
        _shellSawChunk = false;
        var verdict = ShellTools.analyze(v.args.command, cwd, policy);
        if (verdict.verdict !== "auto") { _raiseApproval(verdict); return; }
        _runShell();
    }

    function _raiseApproval(verdict) {
        return _raiseApprovalRequest({ kind: verdict.kind,
                                       command: _shellMeta.command,
                                       cwd: _shellMeta.cwd,
                                       timeoutSeconds: _shellMeta.timeoutSeconds });
    }

    // One place to park a job until the user decides, whatever the tool.
    function _raiseApprovalRequest(fields) {
        var req = fields || {};
        req.callId = _currentId;
        _awaitingApproval = true;
        _approvalRequest = req;
        jobTimer.stop();          // a person is thinking, not a process
        approvalTimer.start();
        if (root.onApprovalNeeded) {
            try { root.onApprovalNeeded(_currentId, _approvalRequest); }
            catch (e) { console.warn("NEXUS_NATIVE: onApprovalNeeded threw:", e); }
        }
    }

    // decision: {action:"allow-once"|"deny"}. One card, one command,
    // no persisted grants — anything else is a refusal.
    function answerApproval(callId, decision) {
        if (!_awaitingApproval || !_approvalRequest) return;
        if (String(callId) !== String(_approvalRequest.callId)) return;
        approvalTimer.stop();
        var d = decision || {};
        var action = String(d.action || "deny");
        _awaitingApproval = false;
        _approvalRequest = null;
        if (action !== "allow-once") {
            _deliverError(_fileMeta
                ? "The user denied permission for this file operation."
                : "The user denied permission to run this command.");
            return;
        }
        if (_fileMeta) { _fileApproved(); return; }
        _runShell();
    }

    // ── File tools (read_file / write_file / edit_file) ───────────
    // argv processes only: stat → cat → approval → tee+mv. No shell, so
    // no path or content is ever quoted into a command string.

    function _startFileJob(job) {
        var v = FileTools.validateArgs(job.toolName, job.args);
        if (!v.ok) { _deliverError(v.error); return; }
        var home = String((job.policy && job.policy.home) || "/");
        _fileMeta = { tool: job.toolName,
                      path: FileTools.resolvePath(v.args.path, home),
                      args: v.args,
                      yolo: !!(job.policy && job.policy.yolo === true) };
        _fileSnapshot = "";
        _fileEdit = null;
        _pendingWrite = "";
        _fileSize = -1;
        _jobTimeoutMs = 30000;
        _filePhase = "stat";
        statProc.command = ["stat", "-c", "%s", _fileMeta.path];
        statProc.running = true;
        jobTimer.start();
    }

    function _onStatDone(code, text) {
        if (_filePhase !== "stat") return;
        if (code !== 0) {
            _fileSize = -1;
        } else {
            _fileSize = parseInt(String(text || "").trim(), 10);
            if (!isFinite(_fileSize)) _fileSize = -1;
        }
        var meta = _fileMeta;
        if (_fileSize > FileTools.MAX_FILE_BYTES) {
            _deliverError(meta.path + " is "
                          + FileTools.humanSize(_fileSize)
                          + " — too large for the file tools; use run_command.");
            return;
        }
        if (meta.tool === "read_file") {
            if (_fileSize < 0) {
                _deliverError("No such file: " + meta.path);
                return;
            }
            if (meta.yolo) { _filePhase = "read"; _runCat(); return; }
            _raiseApprovalRequest({ kind: "read", path: meta.path,
                                    size: _fileSize });
            return;
        }
        if (meta.tool === "write_file") {
            if (meta.yolo) { _fileWriteApproved(); return; }
            var content = meta.args.content;
            _raiseApprovalRequest({
                kind: "write", path: meta.path,
                size: content.length,
                preview: FileTools.unifiedDiff("", content, 0).rows
                    .slice(0, 6).map(function (r) { return r.text; }),
                existed: _fileSize >= 0
            });
            return;
        }
        // edit_file needs the current content to build the diff.
        if (_fileSize < 0) {
            _deliverError("No such file: " + meta.path
                          + " — use write_file to create it.");
            return;
        }
        _filePhase = "readForDiff";
        _runCat();
    }

    function _runCat() {
        if (_filePhase === "write" || _filePhase === "move") return;
        _fileSawChunk = false;      // re-arm the collector for this read
        fileProc.stdinEnabled = false;
        fileProc.command = ["cat", "--", _fileMeta.path];
        fileProc.running = true;
        jobTimer.start();
    }

    function _onCatDone(code) {
        if (code !== 0) {
            _deliverError("Could not read " + _fileMeta.path
                          + " (cat exit " + code + ").");
            return;
        }
        var text = _fileSawChunk ? fileOut.text : "";
        var meta = _fileMeta;

        if (_filePhase === "read") {
            var r = FileTools.formatRead(text, meta.args.offset,
                                         meta.args.limit);
            _deliverOk(r.text.length > 0 ? r.text
                                         : "(no lines at offset "
                                           + meta.args.offset + ")");
            return;
        }

        if (_filePhase === "readForDiff") {
            if (FileTools.looksBinary(text)) {
                _deliverError(meta.path + " looks binary — use run_command.");
                return;
            }
            if (FileTools.isLossyText(text)) {
                _deliverError(meta.path + " is not valid UTF-8 — editing it "
                              + "would corrupt it; use run_command.");
                return;
            }
            var res = FileTools.applyEdit(text, meta.args.oldString,
                                          meta.args.newString,
                                          meta.args.replaceAll);
            if (!res.ok) {
                _deliverError(res.error + " (" + meta.path + ")");
                return;
            }
            var diff = FileTools.unifiedDiff(text, res.content, 3);
            _fileSnapshot = text;
            _pendingWrite = res.content;
            _fileEdit = { count: res.count,
                          oldLines: FileTools.countLines(text),
                          newLines: FileTools.countLines(res.content),
                          diff: diff };
            var rows = diff.rows;
            if (meta.yolo) { _writeFileText(res.content); return; }
            _raiseApprovalRequest({
                kind: "edit", path: meta.path,
                added: diff.added, removed: diff.removed,
                diff: rows.slice(0, 40),
                more: Math.max(0, rows.length - 40)
            });
            return;
        }

        if (_filePhase === "reread") {
            if (text !== _fileSnapshot) {
                _deliverError(meta.path + " changed while the edit was "
                              + "waiting for approval — call read_file and "
                              + "retry.");
                return;
            }
            _writeFileText(_pendingWrite);
            return;
        }
    }

    // The user approved: run the operation that was parked.
    function _fileApproved() {
        var meta = _fileMeta;
        if (!meta) { _deliverError("File job lost its target."); return; }
        jobTimer.start();
        if (meta.tool === "read_file") {
            _filePhase = "read";
            _runCat();
            return;
        }
        if (meta.tool === "edit_file") {
            // Re-read and compare: never write over a stale view.
            _filePhase = "reread";
            _runCat();
            return;
        }
        _fileWriteApproved();
    }

    function _fileWriteApproved() {
        var meta = _fileMeta;
        if (!meta) return;
        if (meta.args.content.length === 0) {
            // A zero-byte temp write would never reach the rename.
            _filePhase = "truncate";
            truncProc.command = ["truncate", "-s", "0", meta.path];
            truncProc.running = true;
            return;
        }
        _writeFileText(meta.args.content);
    }

    // Content → <path>.nexus-tmp → mv. Atomic on one filesystem.
    function _writeFileText(content) {
        _filePhase = "write";
        _pendingWrite = content;
        _fileSawChunk = false;
        fileProc.command = ["tee", "--", _fileMeta.path + _tmpSuffix];
        fileProc.stdinEnabled = true;
        fileProc.running = true;
        jobTimer.start();
    }

    function _onWriteDone(code) {
        var meta = _fileMeta;
        if (code !== 0) {
            _deliverError("Could not write " + meta.path + " (exit " + code
                          + ").");
            return;
        }
        _filePhase = "move";
        mvProc.command = ["mv", "--", meta.path + _tmpSuffix, meta.path];
        mvProc.running = true;
    }

    function _onMoveDone(code) {
        var meta = _fileMeta;
        if (code !== 0) {
            _deliverError("Could not replace " + meta.path + " (mv exit "
                          + code + ").");
            return;
        }
        if (meta.tool === "edit_file") {
            var e = _fileEdit || { count: 1, oldLines: 0, newLines: 0, diff: null };
            _deliverOk(FileTools.formatEditResult(meta.path, e.count,
                                                  e.oldLines, e.newLines,
                                                  e.diff));
            return;
        }
        _deliverOk(FileTools.formatWriteResult(meta.path,
                                               meta.args.content));
    }

    function _clearFileJob() {
        _fileMeta = null;
        _filePhase = "";
        _fileSize = -1;
        _fileSnapshot = "";
        _fileEdit = null;
        _pendingWrite = "";
        _fileSawChunk = false;
    }

    function _runShell() {
        var m = _shellMeta;
        if (!m) { _deliverError("Shell job lost its command."); return; }
        var r = ShellTools.buildRunArgs(m.command, m.cwd, m.timeoutSeconds);
        _stdin = "";
        _maxBytes = ShellTools.MAX_OUTPUT_BYTES;
        // The `timeout` wrapper is the primary killer; this timer is the
        // backstop for a wedged process.
        _jobTimeoutMs = (m.timeoutSeconds + 10) * 1000;
        _shellStarted = Date.now();
        _shellSawChunk = false;
        collector.lastLen = 0;
        fetcher.stdinEnabled = false;
        fetcher.workingDirectory = r.cwd;
        fetcher.command = r.cmd;
        fetcher.running = true;
        jobTimer.start();
    }

    // Every turn-ending path calls this: Stop, new chat, open chat,
    // clear chat, tool switched off mid-flight.
    function abortAll() {
        _queue = [];
        approvalTimer.stop();
        jobTimer.stop();
        _awaitingApproval = false;
        _approvalRequest = null;
        _shellMeta = null;
        _shellKilled = "";
        _clearFileJob();
        if (statProc.running) statProc.running = false;
        if (fileProc.running) fileProc.running = false;
        if (mvProc.running) mvProc.running = false;
        if (truncProc.running) truncProc.running = false;
        if (fetcher.running) fetcher.running = false;
        if (_busy) {
            _busy = false;
            _currentId = -1;
            _currentTool = "";
            _currentArgs = null;
        }
    }

    function _deliverOk(text, images) {
        var id = _currentId;
        jobTimer.stop();
        approvalTimer.stop();
        _awaitingApproval = false;
        _approvalRequest = null;
        _busy = false;
        _currentId = -1;
        _currentTool = "";
        _currentArgs = null;
        _shellMeta = null;
        _shellKilled = "";
        _shellStarted = 0;
        _clearFileJob();
        if (root.onResult) {
            try { root.onResult(id, text, images || null); }
            catch (e) { console.warn("NEXUS_NATIVE: onResult threw:", e); }
        }
        _pump();
    }

    function _deliverError(message) {
        var id = _currentId;
        jobTimer.stop();
        approvalTimer.stop();
        _awaitingApproval = false;
        _approvalRequest = null;
        _busy = false;
        _currentId = -1;
        _currentTool = "";
        _currentArgs = null;
        _shellMeta = null;
        _shellKilled = "";
        _clearFileJob();
        if (root.onError) {
            try { root.onError(id, message); }
            catch (e) { console.warn("NEXUS_NATIVE: onError threw:", e); }
        }
        _pump();
    }

    // Screen capture: the collected stdout is the base64 image itself
    // (no HTTP trailer on this path).
    function _handleScreenshot(raw) {
        var b64 = String(raw || "").replace(/\s+/g, "");
        if (!b64) {
            _deliverError("Screenshot capture failed — dms returned no image data.");
            return;
        }
        var mime = WebTools.sniffImageMime(b64);
        if (!mime) {
            _deliverError("Screenshot capture produced unrecognized image data.");
            return;
        }
        // Match Providers.sanitizeImages' per-image cap: report it here
        // instead of having the image silently dropped on the wire.
        if (Math.floor(b64.length * 3 / 4) > 10 * 1024 * 1024) {
            _deliverError("Screenshot too large for the 10 MB image limit — "
                          + "try mode \"window\" instead of \"full\".");
            return;
        }
        var mode = _currentArgs ? String(_currentArgs.mode || "") : "";
        _deliverOk(WebTools.screenshotResultText(mode),
                   [{ mime: mime, data: b64 }]);
    }

    function _handleFinished(raw) {
        // The timeout may already have delivered for this call id.
        if (!_busy) return;
        // Shell output is delivered from onExited, where the exit code is
        // known — a non-zero exit is data, not an error.
        if (_currentTool === "run_command") return;
        if (_currentTool === "take_screenshot") {
            _handleScreenshot(raw);
            return;
        }
        var parsed = WebTools.extractHttpStatus(raw);
        // status 0 → no trailer: curl failed; onExited attributes it.
        if (parsed.status === 0) return;
        if (parsed.status >= 400) {
            _deliverError("HTTP " + parsed.status +
                          " — the site returned an error for this request.");
            return;
        }
        var body = parsed.body || "";
        if (_currentTool === "web_search") {
            var r = WebTools.parseSearchResults(body);
            if (!r.ok) { _deliverError(r.error); return; }
            _deliverOk(WebTools.formatSearchResults(
                r.results, _currentArgs ? _currentArgs.query : ""));
            return;
        }
        // webfetch
        var text;
        var title = "";
        if (WebTools.isHtmlContent(parsed.contentType, body)) {
            var page = WebTools.htmlToText(body);
            text = page.text;
            title = page.title;
        } else {
            text = body;
            if (text.length > WebTools.MAX_BODY_BYTES)
                text = text.substring(0, WebTools.MAX_BODY_BYTES);
        }
        _deliverOk(WebTools.pageContent(
            text, _currentArgs ? _currentArgs.start_index : 0, title));
    }

    Process {
        id: fetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root._stdin) {
                fetcher.write(root._stdin);
                fetcher.stdinEnabled = false;
                root._stdin = "";
            }
        }

        stdout: StdioCollector {
            id: collector
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                if (root._currentTool === "run_command" && root._busy)
                    root._shellSawChunk = true;
                if (text.length > root._maxBytes) {
                    if (root._currentTool === "run_command") {
                        // Keep what we have and let onExited format it as a
                        // normal result with a "stopped at the cap" marker.
                        if (root._shellKilled === "")
                            root._shellKilled = "cap";
                        fetcher.running = false;
                        return;
                    }
                    fetcher.running = false;
                    if (root._busy)
                        root._deliverError(
                            root._currentTool === "take_screenshot"
                            ? "Screenshot exceeded the size cap."
                            : "Response exceeded the 4 MB download cap.");
                    return;
                }
            }

            onStreamFinished: {
                // No params — must read collector.text by id.
                root._handleFinished(collector.text);
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (root._busy && root._currentTool === "run_command") {
                var killed = root._shellKilled;
                if (killed === "" && exitCode === 124) killed = "timeout";
                var meta = root._shellMeta;
                root._deliverOk(ShellTools.formatResult({
                    command: meta ? meta.command : "",
                    exitCode: exitCode,
                    output: root._shellSawChunk ? collector.text : "",
                    ms: root._shellStarted > 0
                        ? (Date.now() - root._shellStarted) : 0,
                    killed: killed
                }));
                root._pump();
                return;
            }
            // onStreamFinished ran first; a still-busy state here means
            // it deliberately deferred (status 0) for this handler.
            if (root._busy) {
                if (root._currentTool === "take_screenshot") {
                    root._deliverError(exitCode !== 0
                        ? "Screenshot capture failed (dms exited with code "
                          + exitCode + ")."
                        : "Screenshot capture failed — no image data.");
                } else {
                    var msg = exitCode !== 0
                        ? "Connection failed (curl exit " + exitCode + ")"
                        : "No response received.";
                    var hint = exitCode !== 0
                        ? ErrorHints.curlExitHint(exitCode) : "";
                    if (hint) msg += "\n" + hint;
                    root._deliverError(msg);
                }
            }
            // Old process fully dead — safe to start the next job.
            root._pump();
        }
    }

    // File IO: argv only (never a shell), one process per phase.
    Process {
        id: statProc
        command: ["true"]
        stdout: StdioCollector { id: statOut }
        onExited: (code, st) => root._onStatDone(code, statOut.text)
    }

    Process {
        id: fileProc
        command: ["true"]
        stdinEnabled: false
        onRunningChanged: {
            if (running && root._pendingWrite && root._filePhase === "write") {
                fileProc.write(root._pendingWrite);
                fileProc.stdinEnabled = false;   // EOF, or tee waits forever
                root._pendingWrite = "";
            }
        }
        stdout: StdioCollector {
            id: fileOut
            onTextChanged: if (root._fileMeta) root._fileSawChunk = true
        }
        onExited: (code, st) => {
            if (root._filePhase === "read" || root._filePhase === "readForDiff"
                    || root._filePhase === "reread")
                root._onCatDone(code);
            else if (root._filePhase === "write")
                root._onWriteDone(code);
        }
    }

    Process {
        id: mvProc
        command: ["true"]
        onExited: (code, st) => root._onMoveDone(code)
    }

    Process {
        id: truncProc
        command: ["true"]
        onExited: (code, st) => {
            if (root._filePhase !== "truncate") return;
            if (code === 0)
                root._deliverOk("Wrote 0 lines (0 B) to "
                                + (root._fileMeta ? root._fileMeta.path : ""));
            else
                root._deliverError("Could not truncate the file (exit "
                                   + code + ").");
        }
    }

    // Bounds a job that never returns (see _jobTimeoutMs; 0 = no timer,
    // the curl requests carry their own --max-time). Any delivery path
    // stops it; a fire kills the process and reports.
    Timer {
        id: jobTimer
        interval: root._jobTimeoutMs > 0 ? root._jobTimeoutMs : 60000
        repeat: false
        onTriggered: {
            if (!root._busy) return;
            if (fetcher.running) fetcher.running = false;
            if (root._currentTool === "run_command") {
                if (root._shellKilled === "") root._shellKilled = "timeout";
                return;      // onExited formats and delivers
            }
            root._deliverError(root._currentTool === "take_screenshot"
                ? "Screenshot capture timed out — the compositor did not answer."
                : "Request timed out.");
        }
    }

    // A held permission request must not hang the tool loop forever.
    Timer {
        id: approvalTimer
        interval: root._approvalTimeoutMs
        repeat: false
        onTriggered: {
            if (!root._awaitingApproval) return;
            root._deliverError("The permission request timed out.");
        }
    }
}
