import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/McpWire.js" as McpWire
import "../lib/StreamParser.js" as StreamParser

// MCP client: JSON-RPC over HTTP via curl — no npx/Node. Two
// transports, probed automatically per server:
//   - Streamable HTTP (2025-03-26): POST JSON-RPC to the endpoint;
//     responses arrive as JSON or SSE; optional Mcp-Session-Id
//     session; optional GET push stream (405 tolerated).
//   - Legacy HTTP+SSE (2024-11-05): long-lived GET stream; the
//     `endpoint` event names the POST target; responses ride the GET.
// One curl Process per JSON-RPC POST (secrets via stdin config only);
// responses correlate by id. Start → initialize → tools/list →
// connected, same lifecycle as before.
Item {
    id: root

    // --- Configuration ---
    property string mcpUrl: ""
    property string mcpToken: ""
    // Bounds every tools/call POST; NexusService pushes the shared
    // timeout setting here. Connect-phase POSTs cap at 30 s.
    property int toolTimeoutSeconds: 300

    // --- State ---
    property bool isConnected: false
    property bool connecting: false
    property string connectionError: ""
    property var tools: []                 // tool objects from tools/list
    property int _nextId: 1
    property var _pendingRequests: ({})    // id → { resolve, reject }
    property bool _initialized: false

    // Transport state
    property string _transport: ""         // "" | "streamable" | "legacy"
    property string _sessionHeader: ""     // streamable Mcp-Session-Id
    property string _postTarget: ""        // legacy POST target
    property bool _initRetried: false      // one protocol-version retry
    property var _livePosts: []            // in-flight POST Process objects

    // Result delivery callbacks (set by NexusService); called
    // directly from resolve()/reject() — signal-to-signal connects
    // proved unreliable here.
    property var onToolResult: null
    property var onToolFailure: null

    // --- Signals ---
    signal toolCallCompleted(var callId, string result)
    signal toolCallFailed(var callId, string error)
    signal mcpToolsUpdated()
    signal mcpConnectionStateChanged()

    // --- Public API ---

    function connectToServer() {
        console.warn("NEXUS_MCP: connect requested — url:", mcpUrl,
            "token len:", mcpToken.length);
        if (connecting || isConnected) return;
        if (!mcpUrl || !mcpToken) {
            connectionError = "MCP URL and token are required.";
            return;
        }
        connectionError = "";
        connecting = true;
        mcpConnectionStateChanged();
        _probeStreamable();
    }

    function disconnectFromServer() {
        _teardown(true);
    }

    function reconnectToServer() {
        disconnectFromServer();
        Qt.callLater(connectToServer);
    }

    // Call a tool by name with arguments. Returns the request id; the
    // result arrives via onToolResult / onToolFailure callbacks, or
    // the toolCallCompleted / toolCallFailed signals as a fallback.
    function callTool(toolName, args) {
        var id = _nextId++;
        console.warn("NEXUS_MCP_CALL: id=", id, "tool=", toolName);
        _pendingRequests[id] = _pendingEntry(id);
        _postRequest(id,
            McpWire.buildRequest(id, "tools/call",
                                 McpWire.toolsCallParams(toolName, args)),
            _transport === "streamable", root.toolTimeoutSeconds);
        return id;
    }

    // Tools formatted for chat requests (OpenAI tool shape — accepted
    // natively by Ollama and converted per format by Providers.js).
    function getTools() {
        var result = [];
        for (var i = 0; i < tools.length; i++) {
            var t = tools[i];
            result.push({
                type: "function",
                function: {
                    name: t.name,
                    description: t.description || "",
                    parameters: t.inputSchema || { type: "object", properties: {} }
                }
            });
        }
        return result;
    }

    // --- Internal: handshake ---

    // Probe: POST initialize to the user URL. A valid JSON-RPC answer
    // means Streamable HTTP; 404/405 falls back to legacy SSE.
    function _probeStreamable() {
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function (result) { _onInitialized(); },
            reject: function (err) {
                if (McpWire.isProtocolVersionError(err) && !_initRetried) {
                    _initRetried = true;
                    // A JSON-RPC version complaint (not a 404/405)
                    // means the server is streamable-shaped — mark the
                    // transport BEFORE retrying so the retried
                    // initialize dispatches inline instead of ack.
                    _transport = "streamable";
                    _sendInitialize(McpWire.LEGACY_PROTOCOL_VERSION);
                    return;
                }
                _fail("Initialize failed: " + err);
            }
        };
        _spawnPost(McpWire.buildPostRequest(
            mcpUrl, mcpToken,
            McpWire.buildRequest(id, "initialize",
                                 McpWire.initializeParams(McpWire.PROTOCOL_VERSION)),
            "", 30), id, "probe");
    }

    // (Re-)send initialize over the established transport.
    function _sendInitialize(version) {
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function (result) { _onInitialized(); },
            reject: function (err) {
                if (McpWire.isProtocolVersionError(err) && !_initRetried
                    && _transport === "streamable") {
                    _initRetried = true;
                    _sendInitialize(McpWire.LEGACY_PROTOCOL_VERSION);
                    return;
                }
                _fail("Initialize failed: " + err);
            }
        };
        _spawnPost(McpWire.buildPostRequest(
            _postUrl(), mcpToken,
            McpWire.buildRequest(id, "initialize",
                                 McpWire.initializeParams(version)),
            _transport === "streamable" ? _sessionHeader : "", 30),
            id, _transport === "streamable" ? "inline" : "ack");
    }

    function _onInitialized() {
        _initialized = true;
        _postRequest(0, McpWire.buildNotification("notifications/initialized"),
                     false, 30);
        if (_transport === "streamable") _startGetStream();
        _listTools();
    }

    function _listTools() {
        console.warn("NEXUS_MCP: listing tools");
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function (result) {
                tools = (result && result.tools) ? result.tools : [];
                isConnected = true;
                connecting = false;
                connectionError = "";
                mcpConnectionStateChanged();
                mcpToolsUpdated();
            },
            reject: function (err) {
                _fail("Failed to list tools: " + err);
            }
        };
        _postRequest(id,
            McpWire.buildRequest(id, "tools/list", McpWire.toolsListParams()),
            _transport === "streamable", root.toolTimeoutSeconds);
    }

    // --- Internal: POST machinery ---

    function _postUrl() {
        return _transport === "legacy" ? _postTarget : mcpUrl;
    }

    // Fire one JSON-RPC POST. dispatchInline (streamable): the POST
    // body carries the response — parse it. Otherwise (legacy ack,
    // notifications) the POST result is not dispatched: responses ride
    // the GET stream. requestId 0 = no pending to resolve.
    function _postRequest(requestId, bodyObj, dispatchInline, timeoutSeconds) {
        _spawnPost(McpWire.buildPostRequest(
            _postUrl(), mcpToken, bodyObj,
            _transport === "streamable" ? _sessionHeader : "",
            timeoutSeconds || 30), requestId,
            dispatchInline ? "inline" : "ack");
    }

    function _spawnPost(req, requestId, purpose) {
        var proc = postProcComp.createObject(root);
        proc._requestId = requestId;
        proc._purpose = purpose;
        proc._config = req.body;
        _livePosts.push(proc);
        proc.command = req.cmd;
        proc.running = true;
    }

    // Route a finished POST. StdioCollector's onStreamFinished fires
    // before Process.onExited (modelsFetcher ordering), so the body is
    // complete here.
    function _onPostFinished(proc) {
        _forgetPost(proc);
        var raw = proc.stdout.text;
        var purpose = proc._purpose;
        var requestId = proc._requestId;
        if (purpose === "cancelled") return;
        var parsed = StreamParser.extractHttpStatus(raw);
        var session = McpWire.extractSessionHeader(raw);
        if (purpose === "probe") {
            var verdict = McpWire.classifyProbe(parsed.status, parsed.body);
            if (verdict === "streamable") {
                _transport = "streamable";
                if (session) _sessionHeader = session;
                _dispatchBody(parsed.body);
            } else if (verdict === "legacy-fallback") {
                _transport = "legacy";
                _startGetStream();
            } else {
                _rejectPending(requestId,
                    McpWire.parseProtocolError(parsed.status, parsed.body));
                _fail(McpWire.parseProtocolError(parsed.status, parsed.body));
            }
            return;
        }
        // Non-2xx: HTTP-level failure for this single request.
        if (parsed.status < 200 || parsed.status >= 300) {
            var err = McpWire.parseProtocolError(parsed.status, parsed.body);
            _rejectPending(requestId, err);
            // Session expired mid-session (streamable) — surface it
            // and require manual reconnect.
            if (_transport === "streamable" && isConnected
                && (parsed.status === 404 || parsed.status === 400)) {
                _fail("MCP session expired — reconnecting is required.");
            }
            return;
        }
        // 2xx: echo the server's latest session header regardless of
        // purpose — the probe branch stored its own; a streamable
        // server that mints Mcp-Session-Id on the retried/inline
        // initialize would otherwise leave later POSTs session-less
        // (→ 400s). Echoing the latest value is always safe. Legacy /
        // ack traffic keeps no session (transport gate).
        if (_transport === "streamable" && session) _sessionHeader = session;
        if (purpose === "inline") _dispatchBody(parsed.body);
        // purpose "ack": 2xx empty ack — the GET stream delivers.
    }

    function _forgetPost(proc) {
        var next = [];
        for (var i = 0; i < _livePosts.length; i++)
            if (_livePosts[i] !== proc) next.push(_livePosts[i]);
        _livePosts = next;
    }

    // Dispatch every JSON-RPC message in a response body.
    function _dispatchBody(body) {
        var msgs = McpWire.extractJsonRpcMessages(body);
        for (var i = 0; i < msgs.length; i++)
            _dispatchMessage(msgs[i]);
    }

    function _dispatchMessage(msg) {
        if (!msg) return;
        if (msg.id === undefined || msg.id === null) return;
        var pending = _pendingRequests[msg.id];
        if (!pending) return;
        delete _pendingRequests[msg.id];
        if (msg.error)
            pending.reject(msg.error.message || JSON.stringify(msg.error));
        else
            pending.resolve(msg.result);
    }

    function _rejectPending(id, err) {
        if (!id) return;
        var pending = _pendingRequests[id];
        if (!pending) return;
        delete _pendingRequests[id];
        pending.reject(err);
    }

    function _pendingEntry(id) {
        return {
            resolve: function (result) {
                var text = typeof result === "string"
                    ? result : JSON.stringify(result);
                console.warn("NEXUS_MCP_CALL: id=", id, "resolved len=", text.length);
                if (root.onToolResult) {
                    try { root.onToolResult(id, text); }
                    catch (e) { console.warn("NEXUS_MCP_CALL: onToolResult threw:", e); }
                }
                root.toolCallCompleted(id, text);
            },
            reject: function (err) {
                console.warn("NEXUS_MCP_CALL: id=", id, "rejected:", err);
                if (root.onToolFailure) {
                    try { root.onToolFailure(id, err); }
                    catch (e) { console.warn("NEXUS_MCP_CALL: onToolFailure threw:", e); }
                }
                root.toolCallFailed(id, err);
            }
        };
    }

    // --- Internal: GET stream ---

    function _startGetStream() {
        if (getStream.running) return;
        var req = McpWire.buildGetStreamRequest(mcpUrl, mcpToken);
        getStream._config = req.body;
        getStream.stdinEnabled = true;   // re-arm — a previous session disabled it
        getStream.command = req.cmd;
        getStream.running = true;
    }

    function _onGetChunk(fresh) {
        var frames = McpWire.parseSseChunk(fresh, getStream._sseBuffer);
        getStream._sseBuffer = frames.buffer;
        for (var i = 0; i < frames.events.length; i++) {
            var ev = frames.events[i];
            if (_transport === "legacy" && _postTarget === "") {
                var target = McpWire.extractEndpointEvent([ev]);
                if (target) {
                    _postTarget = McpWire.resolveEndpoint(mcpUrl, target);
                    console.warn("NEXUS_MCP: legacy endpoint:", _postTarget);
                    _sendInitialize(McpWire.LEGACY_PROTOCOL_VERSION);
                    continue;
                }
            }
            var routed = McpWire.routeStreamEvent(ev);
            if (routed.kind === "response") _dispatchMessage(routed.message);
            else if (routed.kind === "tools-list-changed" && isConnected)
                _listTools();
        }
    }

    // --- Internal: lifecycle ---

    // Deliberate disconnect: reject pendings so awaiting chat turns
    // surface the disconnect (symmetrical with _teardownQuiet), stop
    // every process, best-effort session DELETE. The DELETE is spawned
    // AFTER the kill loop — spawning before it would push the proc
    // into _livePosts and get it killed before curl connects. Spawned
    // last, nothing sets running = false on it; it self-destroys via
    // onExited (its _onPostFinished sees purpose "cancelled" and
    // _forgetPost removes it). Failure (stream drop mid-session):
    // _fail() rejects pendings so chat turns surface the error.
    function _teardown(deliberate) {
        for (var i = 0; i < _livePosts.length; i++) {
            _livePosts[i]._purpose = "cancelled";
            _livePosts[i].running = false;
        }
        _livePosts = [];
        if (deliberate && _transport === "streamable" && _sessionHeader) {
            _spawnPost(McpWire.buildDeleteRequest(
                mcpUrl, mcpToken, _sessionHeader, 5), 0, "cancelled");
        }
        if (getStream.running) getStream.running = false;
        getStream._sseBuffer = "";
        // Reject every pending BEFORE clearing the map — a chat turn
        // awaiting callTool must not hang until the stream watchdog.
        // Delete-from-map first so no path can double-reject.
        var ids = [];
        for (var k in _pendingRequests) ids.push(k);
        for (var j = 0; j < ids.length; j++) {
            var pending = _pendingRequests[ids[j]];
            delete _pendingRequests[ids[j]];
            if (pending) pending.reject("MCP disconnected.");
        }
        _pendingRequests = ({});
        _reset();
    }

    function _fail(message) {
        connectionError = message;
        console.warn("NEXUS_MCP: fail:", message);
        _teardownQuiet();
        connecting = false;
        mcpConnectionStateChanged();
    }

    // Failure teardown: reject every pending (chat turns surface the
    // error) and stop all processes.
    function _teardownQuiet() {
        var ids = [];
        for (var k in _pendingRequests) ids.push(k);
        for (var i = 0; i < ids.length; i++) {
            var pending = _pendingRequests[ids[i]];
            delete _pendingRequests[ids[i]];
            if (pending) pending.reject(connectionError);
        }
        for (var p = 0; p < _livePosts.length; p++) {
            _livePosts[p]._purpose = "cancelled";
            _livePosts[p].running = false;
        }
        _livePosts = [];
        if (getStream.running) getStream.running = false;
        getStream._sseBuffer = "";
        _reset();
    }

    function _reset() {
        isConnected = false;
        connecting = false;
        _initialized = false;
        _transport = "";
        _sessionHeader = "";
        _postTarget = "";
        _initRetried = false;
        _pendingRequests = ({});
        tools = [];
        mcpConnectionStateChanged();
    }

    // Guard: a handshake that never completes (no endpoint event, hung
    // probe) fails loudly instead of spinning "connecting" forever.
    Timer {
        id: connectGuard
        interval: 30000
        onTriggered: if (root.connecting) root._fail("MCP handshake timed out.")
    }
    onConnectingChanged: {
        if (connecting) connectGuard.restart();
        else connectGuard.stop();
    }

    // --- Processes ---

    // One dynamically-created curl Process per JSON-RPC POST. StdioCollector
    // accumulates the whole body (waitForEnd default) — routing happens in
    // _onPostFinished, fired from onStreamFinished (which lands before
    // onExited, per the modelsFetcher ordering).
    Component {
        id: postProcComp

        Process {
            id: postProc
            property string _config: ""
            property int _requestId: 0
            // "probe" | "inline" | "ack" | "cancelled"
            property string _purpose: "ack"

            stdinEnabled: true
            onRunningChanged: {
                if (running && _config) {
                    postProc.write(_config);
                    postProc.stdinEnabled = false;
                    _config = "";
                }
            }

            stdout: StdioCollector {
                waitForEnd: true
                onStreamFinished: root._onPostFinished(postProc)
            }

            onExited: (exitCode, exitStatus) => {
                // curl-level failure (timeout, refused): no HTTP status.
                // _onPostFinished already ran via onStreamFinished and
                // rejected the pending with parseProtocolError(0, …).
                postProc.destroy();
            }
        }
    }

    // Long-lived GET stream (server push / legacy response channel).
    // --fail (in the McpWire builder) makes a 405 exit non-zero so the
    // streamable path degrades silently; for legacy the stream IS the
    // session, so a drop is a connection failure.
    Process {
        id: getStream
        property string _config: ""
        property string _sseBuffer: ""
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && _config) {
                getStream.write(_config);
                getStream.stdinEnabled = false;
                _config = "";
            }
        }

        stdout: StdioCollector {
            id: getOut
            waitForEnd: false
            property int lastLen: 0
            onTextChanged: {
                if (lastLen > text.length) lastLen = 0;
                var fresh = text.substring(lastLen);
                lastLen = text.length;
                if (fresh.length > 0) root._onGetChunk(fresh);
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (root._transport === "streamable" && !root.isConnected
                && root._initialized) {
                // Streamable servers may not support server push (405).
                console.warn("NEXUS_MCP: no push stream (GET failed) — continuing without.");
                return;
            }
            if (root.isConnected || root.connecting) {
                root.connectionError = "MCP connection lost.";
                root._teardownQuiet();
                root.connecting = false;
                root.mcpConnectionStateChanged();
            }
        }
    }
}
