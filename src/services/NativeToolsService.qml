import QtQuick
import Quickshell.Io
import "../lib/WebTools.js" as WebTools
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/Providers.js" as Providers

  // Native chat tools executor (web_search + webfetch): one curl
  // process at a time, config via stdin. All validation/parsing
  // lives in WebTools.js; this file is transport + delivery only.
Item {
    id: root

    // Assigned by NexusService: (callId, modelText) — text the model sees.
    property var onResult: null
    // Assigned by NexusService: (callId, errorText).
    property var onError: null

    property var _queue: []            // {callId, toolName, args}
    property bool _busy: false
    property int _currentId: -1
    property string _currentTool: ""
    property var _currentArgs: null
    property string _stdin: ""
    readonly property int _maxBytes: 4 * 1024 * 1024

    function execute(callId, toolName, argsJson) {
        _queue.push({ callId: callId, toolName: String(toolName || ""),
                      args: Providers.parseToolArgs(argsJson) });
        _pump();
    }

    function _pump() {
        if (_busy || _queue.length === 0) return;
        // Previous curl still dying (async exit): starting now would
        // skip the stdin write and hang the job. Queue it; onExited
        // drains the queue.
        if (fetcher.running) return;
        var job = _queue.shift();
        // Claim the id first so even an invalid-args rejection is
        // delivered against the right callId.
        _currentId = job.callId;
        _currentTool = job.toolName;
        var req = job.toolName === "web_search"
            ? WebTools.buildSearchRequest(job.args)
            : WebTools.buildFetchRequest(job.args);
        if (!req || !req.ok) {
            _deliverError(req && req.error ? req.error : "Unknown native tool");
            return;
        }
        _busy = true;
        _currentArgs = req.args || job.args;
        _stdin = req.config;
        collector.lastLen = 0;        // re-arm: collector text accumulates
        fetcher.stdinEnabled = true;  // re-arm for every request
        fetcher.command = req.cmd;
        fetcher.running = true;
    }

    function _deliverOk(text) {
        var id = _currentId;
        _busy = false;
        _currentId = -1;
        _currentTool = "";
        _currentArgs = null;
        if (root.onResult) {
            try { root.onResult(id, text); }
            catch (e) { console.warn("NEXUS_NATIVE: onResult threw:", e); }
        }
        _pump();
    }

    function _deliverError(message) {
        var id = _currentId;
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

    function _handleFinished(raw) {
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
                            "Response exceeded the 4 MB download cap.");
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
                var msg = exitCode !== 0
                    ? "Connection failed (curl exit " + exitCode + ")"
                    : "No response received.";
                var hint = exitCode !== 0
                    ? ErrorHints.curlExitHint(exitCode) : "";
                if (hint) msg += "\n" + hint;
                root._deliverError(msg);
            }
            // Old process fully dead — safe to start the next job.
            root._pump();
        }
    }
}
