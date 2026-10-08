.pragma library

var PROTOCOL_VERSION = "2025-03-26";
var LEGACY_PROTOCOL_VERSION = "2024-11-05";

var STATUS_MARKER = "NEXUS_STATUS:";
var SESSION_MARKER = "NEXUS_SESSION:";
var POST_TRAILER = "\\nNEXUS_STATUS:%{http_code}\\nNEXUS_SESSION:%header{mcp-session-id}\\n";

function escapeCurlConfig(s) {
    if (typeof s !== "string") return "";
    return s.replace(/\\/g, "\\\\")
            .replace(/"/g, '\\"')
            .replace(/\n/g, "\\n")
            .replace(/\r/g, "\\r")
            .replace(/\t/g, "\\t");
}

function baseCurlArgs() {
    return ["curl", "-K", "-", "-sS", "--show-error", "--connect-timeout", "5"];
}

// --- JSON-RPC builders ------------------------------------------------

function buildRequest(id, method, params) {
    var msg = { jsonrpc: "2.0", id: id, method: method };
    if (params !== undefined && params !== null) msg.params = params;
    return msg;
}

function buildNotification(method, params) {
    var msg = { jsonrpc: "2.0", method: method };
    if (params !== undefined && params !== null) msg.params = params;
    return msg;
}

function initializeParams(protocolVersion) {
    return {
        protocolVersion: String(protocolVersion || PROTOCOL_VERSION),
        capabilities: { tools: {} },
        clientInfo: { name: "nexus", version: "1.0.0" }
    };
}

function toolsListParams() {
    return {};
}

function toolsCallParams(name, args) {
    return { name: String(name || ""), arguments: args || {} };
}

function isProtocolVersionError(message) {
    return /version|protocol/i.test(String(message || ""));
}

// --- Response body parsing --------------------------------------------

function extractJsonRpcMessages(body) {
    var text = String(body == null ? "" : body).trim();
    if (!text) return [];
    var out = [];
    try {
        var obj = JSON.parse(text);
        if (Array.isArray(obj)) {
            for (var i = 0; i < obj.length; i++)
                if (obj[i] && typeof obj[i] === "object") out.push(obj[i]);
            return out;
        }
        if (obj && typeof obj === "object") return [obj];
        return [];
    } catch (e) {}
    var frames = parseSseChunk(String(body == null ? "" : body), "");
    for (var f = 0; f < frames.events.length; f++) {
        var d = frames.events[f].data;
        if (!d) continue;
        try {
            var m = JSON.parse(d);
            if (m && typeof m === "object") out.push(m);
        } catch (e2) {}
    }
    return out;
}

// Transport probe classification
function classifyProbe(status, body) {
    if (status === 401 || status === 403) return "auth";
    if (status === 404 || status === 405) return "legacy-fallback";
    if (status < 200 || status >= 300) return "error";
    return extractJsonRpcMessages(body).length > 0 ? "streamable" : "error";
}

// Error handling
function parseProtocolError(status, body) {
    if (status === 401 || status === 403)
        return "Authentication failed (HTTP " + status + ") — check the server token.";
    if (status === 0)
        return "Connection failed — the server is unreachable (curl could not complete the request).";
    var msgs = extractJsonRpcMessages(body);
    for (var i = 0; i < msgs.length; i++)
        if (msgs[i] && msgs[i].error && msgs[i].error.message)
            return String(msgs[i].error.message);
    return "Request failed (HTTP " + status + ").";
}

// --- SSE parsing -------------------------------------------------------

function parseSseChunk(text, buffer) {
    var combined = String(buffer || "") + String(text == null ? "" : text);
    combined = combined.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
    var out = { events: [], buffer: "" };
    var blocks = combined.split("\n\n");
    out.buffer = blocks.pop();
    for (var b = 0; b < blocks.length; b++) {
        var lines = blocks[b].split("\n");
        var eventName = "";
        var dataLines = [];
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (!line || line.charAt(0) === ":") continue;
            if (line.indexOf("event:") === 0)
                eventName = line.substring(6).trim();
            else if (line.indexOf("data:") === 0)
                dataLines.push(line.substring(5).trim());
        }
        if (dataLines.length > 0)
            out.events.push({ event: eventName, data: dataLines.join("\n") });
    }
    return out;
}

// Legacy handshake
function extractEndpointEvent(events) {
    for (var i = 0; i < events.length; i++)
        if (events[i] && events[i].event === "endpoint" && events[i].data)
            return String(events[i].data).trim();
    return "";
}

// Absolute targets pass through
function resolveEndpoint(getUrl, endpoint) {
    var e = String(endpoint || "").trim();
    if (!e) return "";
    if (/^https?:\/\//i.test(e)) return e;
    var m = /^(https?:\/\/[^\/]+)/i.exec(String(getUrl || ""));
    if (!m) return "";
    if (e.charAt(0) !== "/") e = "/" + e;
    return m[1] + e;
}

function extractSessionHeader(rawText) {
    var text = String(rawText == null ? "" : rawText);
    var idx = text.lastIndexOf(SESSION_MARKER);
    if (idx < 0) return "";
    var v = text.substring(idx + SESSION_MARKER.length).trim();
    if (!v || v.indexOf("%header{") === 0) return "";
    return v;
}

function routeStreamEvent(ev) {
    var none = { kind: "ignore", message: null };
    if (!ev || !ev.data) return none;
    var msg;
    try { msg = JSON.parse(ev.data); } catch (e) { return none; }
    if (!msg || typeof msg !== "object") return none;
    if (msg.id !== undefined && msg.id !== null)
        return { kind: "response", message: msg };
    if (msg.method === "notifications/tools/list_changed")
        return { kind: "tools-list-changed", message: msg };
    return none;
}

// --- curl builders ------------------------------------------------------

function authHeader(token) {
    if (!token) return "";
    return 'header = "Authorization: Bearer ' + escapeCurlConfig(String(token)) + '"\n';
}

function buildPostRequest(url, token, bodyObj, sessionHeader, timeoutSeconds) {
    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "POST"\n';
    config += 'header = "Content-Type: application/json"\n';
    config += 'header = "Accept: application/json, text/event-stream"\n';
    config += authHeader(token);
    if (sessionHeader)
        config += 'header = "Mcp-Session-Id: '
                  + escapeCurlConfig(String(sessionHeader)) + '"\n';
    config += 'data = "' + escapeCurlConfig(JSON.stringify(bodyObj)) + '"\n';
    config += 'write-out = "' + POST_TRAILER + '"\n';
    var cmd = baseCurlArgs().concat([
        "-N", "--max-time", String(Math.max(5, Math.floor(timeoutSeconds || 30)))]);
    return { cmd: cmd, body: config };
}

function buildGetStreamRequest(url, token) {
    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "GET"\n';
    config += 'header = "Accept: text/event-stream"\n';
    config += authHeader(token);
    var cmd = baseCurlArgs().concat(["--fail", "-N"]);
    return { cmd: cmd, body: config };
}

function buildDeleteRequest(url, token, sessionHeader, timeoutSeconds) {
    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "DELETE"\n';
    config += 'header = "Accept: application/json"\n';
    config += authHeader(token);
    if (sessionHeader)
        config += 'header = "Mcp-Session-Id: '
                  + escapeCurlConfig(String(sessionHeader)) + '"\n';
    var cmd = baseCurlArgs().concat([
        "--max-time", String(Math.max(2, Math.floor(timeoutSeconds || 5)))]);
    return { cmd: cmd, body: config };
}
