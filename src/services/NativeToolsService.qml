import QtQuick
import Quickshell.Io
import "../lib/WebTools.js" as WebTools
import "../lib/ShellTools.js" as ShellTools
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
        _awaitingApproval = true;
        _approvalRequest = {
            callId: _currentId,
            kind: verdict.kind,
            command: _shellMeta.command,
            cwd: _shellMeta.cwd,
            timeoutSeconds: _shellMeta.timeoutSeconds
        };
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
            _deliverError("The user denied permission to run this command.");
            return;
        }
        _runShell();
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
