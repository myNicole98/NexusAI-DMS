import QtQuick
import Quickshell.Io
import "../lib/WebTools.js" as WebTools
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/Providers.js" as Providers

  // Native chat tools executor (web_search + webfetch + take_screenshot):
  // one process at a time, curl config via stdin. All validation/parsing
  // lives in WebTools.js; this file is transport + delivery only.
Item {
    id: root

    // Assigned by NexusService: (callId, modelText, images) — text the
    // model sees, plus an optional [{mime, data}] image array (screen
    // capture only; null for the web tools).
    property var onResult: null
    // Assigned by NexusService: (callId, errorText).
    property var onError: null

    property var _queue: []            // {callId, toolName, args}
    property bool _busy: false
    property int _currentId: -1
    property string _currentTool: ""
    property var _currentArgs: null
    property string _stdin: ""
    // Per-job stdout cap: curl downloads keep the 4 MB guard; a screen
    // capture is a base64 image and gets its own, larger cap.
    property int _maxBytes: 4 * 1024 * 1024
    // Escape hatch for a hung capture. A normal capture is sub-second;
    // StreamingService.cancel() (Stop) only stops its own stream, so a
    // wedged compositor call would otherwise block the tool loop forever.
    readonly property int _jobTimeoutMs: 60000

    function execute(callId, toolName, argsJson) {
        _queue.push({ callId: callId, toolName: String(toolName || ""),
                      args: Providers.parseToolArgs(argsJson) });
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
        collector.lastLen = 0;        // re-arm: collector text accumulates
        fetcher.stdinEnabled = _stdin.length > 0;  // re-arm per request
        fetcher.command = req.cmd;
        fetcher.running = true;
        jobTimer.start();
    }

    function _deliverOk(text, images) {
        var id = _currentId;
        jobTimer.stop();
        _busy = false;
        _currentId = -1;
        _currentTool = "";
        _currentArgs = null;
        if (root.onResult) {
            try { root.onResult(id, text, images || null); }
            catch (e) { console.warn("NEXUS_NATIVE: onResult threw:", e); }
        }
        _pump();
    }

    function _deliverError(message) {
        var id = _currentId;
        jobTimer.stop();
        _busy = false;
        _currentId = -1;
        _currentTool = "";
        _currentArgs = null;
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
                if (text.length > root._maxBytes) {
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

    // Bounds a capture job that never returns (see _jobTimeoutMs). Any
    // delivery path stops it; a fire kills the process and reports.
    Timer {
        id: jobTimer
        interval: root._jobTimeoutMs
        repeat: false
        onTriggered: {
            if (!root._busy) return;
            if (fetcher.running) fetcher.running = false;
            root._deliverError(root._currentTool === "take_screenshot"
                ? "Screenshot capture timed out — the compositor did not answer."
                : "Request timed out.");
        }
    }
}
