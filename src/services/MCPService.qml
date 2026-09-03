import QtQuick
import Quickshell
import Quickshell.Io

// MCP client: JSON-RPC over stdio to `mcp-remote` (which bridges a
// remote MCP server). Start → initialize → tools/list → connected;
// requests correlated by id; non-JSON stdout lines are status noise.
Item {
    id: root

    // --- Configuration ---
    property string mcpUrl: ""
    property string mcpToken: ""

    // --- State ---
    property bool isConnected: false
    property bool connecting: false
    property string connectionError: ""
    property var tools: []                 // tool objects from tools/list
    property int _nextId: 1
    property var _pendingRequests: ({})    // id → { resolve, reject }
    property string _readBuffer: ""
    property bool _initialized: false

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
            "token len:", mcpToken.length, "enabled-guard pass");
        if (connecting || isConnected) {
            console.warn("NEXUS_MCP: ignored — connecting:", connecting, "connected:", isConnected);
            return;
        }
        if (!mcpUrl || !mcpToken) {
            connectionError = "MCP URL and token are required.";
            console.warn("NEXUS_MCP: missing url/token — url len:", mcpUrl.length);
            return;
        }
        connectionError = "";
        connecting = true;
        _initialized = false;
        _readBuffer = "";
        _pendingRequests = ({});
        _nextId = 1;
        tools = [];
        // Kill leftovers from a previous session/attempt first —
        // mcp-remote spawns children that survive a plain SIGTERM to
        // npx and keep the pipes/port busy. The real start is delayed
        // so the kill lands first.
        _killStragglers();
        connectDelay.restart();
        mcpConnectionStateChanged();
    }

    function disconnectFromServer() {
        if (mcpProcess.running)
            mcpProcess.running = false;
        _killStragglers();
        _reset();
    }

    function reconnectToServer() {
        disconnectFromServer();
        Qt.callLater(connectToServer);
    }

    function _startProcess() {
        console.warn("NEXUS_MCP: spawning mcp-remote");
        mcpProcess.command = [
            "npx", "-y", "mcp-remote",
            mcpUrl,
            "--allow-http",
            "--header", "Authorization: Bearer " + mcpToken
        ];
        mcpProcess.running = true;
    }

    // Call a tool by name with arguments. Returns the request id; the
    // result arrives via onToolResult / onToolFailure callbacks
    // (preferred), or toolCallCompleted / toolCallFailed signals as
    // a fallback for any leftover listener.
    function callTool(toolName, args) {
        var id = _nextId++;
        console.warn("NEXUS_MCP_CALL: id=", id, "tool=", toolName);
        _pendingRequests[id] = {
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
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "tools/call",
            params: {
                name: toolName,
                arguments: args || {}
            }
        });
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

    // --- Internal ---

    function _reset() {
        isConnected = false;
        connecting = false;
        _initialized = false;
        _readBuffer = "";
        _pendingRequests = ({});
        tools = [];
        mcpConnectionStateChanged();
    }

    function _sendRequest(id, req) {
        mcpProcess.write(JSON.stringify(req) + "\n");
    }

    function _sendNotification(method, params) {
        var msg = { jsonrpc: "2.0", method: method };
        if (params) msg.params = params;
        mcpProcess.write(JSON.stringify(msg) + "\n");
    }

    function _handleLine(line) {
        line = line.trim();
        if (!line) return;
        if (line.indexOf("{") !== 0)
            console.warn("NEXUS_MCP: non-json line:", line.substring(0, 160));

        var msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            // Not JSON — mcp-remote status output, ignore
            return;
        }

        // Response to one of our requests
        if (msg.id !== undefined && msg.id !== null) {
            var pending = _pendingRequests[msg.id];
            if (pending) {
                delete _pendingRequests[msg.id];
                if (msg.error)
                    pending.reject(msg.error.message || JSON.stringify(msg.error));
                else
                    pending.resolve(msg.result);
            }
            return;
        }

        // Server notification
        if (msg.method) _handleNotification(msg.method, msg.params);
    }

    function _handleNotification(method, params) {
        if (method === "notifications/tools/list_changed") _listTools();
    }

    function _sendInitialize() {
        console.warn("NEXUS_MCP: sending initialize");
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function (result) { _onInitialized(result); },
            reject: function (err) {
                connectionError = "Initialize failed: " + err;
                connecting = false;
                mcpConnectionStateChanged();
            }
        };
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "initialize",
            params: {
                protocolVersion: "2024-11-05",
                capabilities: { tools: {} },
                clientInfo: { name: "nexus", version: "1.0.0" }
            }
        });
    }

    function _onInitialized(result) {
        _sendNotification("notifications/initialized");
        _initialized = true;
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
                connectionError = "Failed to list tools: " + err;
                connecting = false;
                mcpConnectionStateChanged();
            }
        };
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "tools/list",
            params: {}
        });
    }

    function _processBuffer() {
        var lines = _readBuffer.split("\n");
        // Last element may be incomplete — keep it in the buffer
        _readBuffer = lines.pop();
        for (var i = 0; i < lines.length; i++)
            _handleLine(lines[i]);
    }

    // --- Process ---

    Timer {
        id: connectDelay
        interval: 350
        onTriggered: root._startProcess()
    }

    // Kills mcp-remote children orphaned by an earlier session —
    // they hold the stdio pipes and local port otherwise.
    Process {
        id: stragglerKill
        command: ["pkill", "-f", "mcp-remote"]
    }

    function _killStragglers() {
        console.warn("NEXUS_MCP: killing stragglers");
        stragglerKill.running = true;
    }

    Process {
        id: mcpProcess
        running: false
        stdinEnabled: true

        onRunningChanged: {
            console.warn("NEXUS_MCP: process running =", running);
            // StdioCollector.text accumulates across runs — re-arm the
            // read cursor or run 2's output is invisible.
            mcpStdout.lastLen = 0;
            mcpStderr.lastLen = 0;
            if (running) {
                // Send initialize once the process starts
                Qt.callLater(root._sendInitialize);
            } else if (root.isConnected || root.connecting) {
                root.connectionError = "MCP process exited unexpectedly.";
                root._reset();
            }
        }

        stderr: StdioCollector {
            id: mcpStderr
            waitForEnd: false
            property int lastLen: 0
            onTextChanged: {
                var fresh = text.substring(lastLen);
                lastLen = text.length;
                var t = fresh.trim();
                if (t.length > 0) console.warn("NEXUS_MCP_STDERR:", t.substring(0, 300));
            }
        }

        stdout: StdioCollector {
            id: mcpStdout
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                // Defensive: a shorter text means the collector reset
                if (lastLen > text.length) lastLen = 0;
                var fresh = text.substring(lastLen);
                lastLen = text.length;
                root._readBuffer += fresh;
                root._processBuffer();
            }
        }

        onExited: exitCode => {
            console.warn("NEXUS_MCP: process exited, code:", exitCode);
            if (exitCode !== 0 && (root.isConnected || root.connecting))
                root.connectionError = "MCP process exited with code " + exitCode + ".";
            root._reset();
        }
    }
}
