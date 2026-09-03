import QtQuick
import Quickshell.Io
import "../lib/StreamParser.js" as StreamParser
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/Providers.js" as Providers

Item {
    id: root

    property int timeoutSeconds: 300
    property bool isStreaming: false
    property string activeStreamId: ""
    // Wire format of the active provider ("openai" | "anthropic" |
    // "gemini" | "ollama"); set before begin() so chunks parse right.
    property string format: "openai"

    // stream-scoped accumulators
    property string _content: ""
    property string _thinking: ""
    property string _lineBuffer: ""
    property string _tagBuffer: ""
    property bool _insideThinkTag: false
    property real _startMs: 0
    property int _deltaCount: 0
    property int _apiTokens: 0

    signal streamContentUpdated(string streamId, string delta)
    signal streamThinkingUpdated(string streamId, string delta)
    // usage: {input, output} token counts for the request, or null
    // when the provider reported nothing.
    signal streamFinalized(string streamId, string stats, var usage)
    signal streamError(string streamId, string message)
    signal streamCancelled(string streamId, string stats)

    readonly property int maxStreamBytes: 5 * 1024 * 1024
    property string _pendingStdin: ""
    property var _queuedReq: null
    property int _gen: 0
    property int _launchGen: -1

    // ── MCP tool rounds ───────────────────────────────────────────
    // Model answers with tool calls → execute over MCP → relaunch
    // with results appended, until a round ends without calls.
    property var mcpService: null
    property bool _seenToolCalls: false
    property var _pendingToolCalls: []
    property var _allToolCalls: []
    property var _toolResults: []
    property var _toolAcc: ({})            // per-round parse accumulator
    property var _conversationMessages: [] // neutral payload messages
    // Token usage reported by the provider ({input, output}), latest
    // wins. Not reset across tool rounds — the last round reports
    // the full conversation position.
    property var _usage: null
    property int _pendingCallId: -1
    property var _pendingToolCallMeta: null
    // True while an MCP call is in flight; completion handlers clear
    // it and drive the loop. Guards _executeNextToolCall against
    // re-entry (which used to drop the in-flight result).
    property bool _toolExecActive: false

    signal streamToolRoundReady(string streamId, var messages)
    signal toolActivity(string streamId, string toolName, string phase, string detail)

    // Tool-call results arrive via NexusService calling
    // _onToolCallCompleted / _onToolCallFailed directly.

    function begin(streamId) {
        _gen++;
        activeStreamId = streamId;
        isStreaming = true;
        _content = "";
        _thinking = "";
        _lineBuffer = "";
        _tagBuffer = "";
        _insideThinkTag = false;
        _startMs = 0;
        _deltaCount = 0;
        _apiTokens = 0;
        _seenToolCalls = false;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolResults = [];
        _toolAcc = {};
        _conversationMessages = [];
        _usage = null;
        _pendingCallId = -1;
        _pendingToolCallMeta = null;
        _toolExecActive = false;
    }

    function launchCurl(req) {
        if (!req) return;
        if (fetcher.running) {
            _queuedReq = req;
            fetcher.running = false;   // stop the old process; queued req starts from onExited
            return;
        }
        _startFetch(req);
    }

    // Cancel → relaunch race: cancel() flushes and marks dead
    // (_gen changes), the old curl's callbacks no-op, and its
    // onExited drains the queued request under the new generation.
    function _startFetch(req) {
        _launchGen = _gen;
        collector.lastLen = 0;          // re-arm collector for this run
        _pendingStdin = req.body;
        fetcher.stdinEnabled = true;   // re-arm for every request
        fetcher.command = req.cmd;
        fetcher.running = true;
    }

    function cancel() {
        if (!isStreaming) return;
        var id = activeStreamId;
        _flushTagBuffer();
        _queuedReq = null;           // a Stop must never launch a parked request later
        isStreaming = false;
        activeStreamId = "";
        fetcher.running = false;
        streamCancelled(id, _stats());
    }

    function reset() {
        if (fetcher.running) fetcher.running = false;
        isStreaming = false;
        activeStreamId = "";
        _lineBuffer = "";
        _pendingStdin = "";
        _queuedReq = null;
    }

    function _live() {
        return isStreaming && _launchGen === _gen;
    }

    // ── internals ─────────────────────────────────────────────────

    function _flushTagBuffer() {
        if (_tagBuffer.length === 0) return;
        if (_insideThinkTag) { _thinking += _tagBuffer; streamThinkingUpdated(activeStreamId, _tagBuffer); }
        else { _content += _tagBuffer; streamContentUpdated(activeStreamId, _tagBuffer); }
        _tagBuffer = "";
    }

    function _contentDelta(id, text) {
        if (!text) return;
        if (_startMs === 0) _startMs = Date.now();
        _deltaCount++;
        _content += text;
        streamContentUpdated(id, text);
    }

    function _thinkingDelta(id, text) {
        if (!text) return;
        if (_startMs === 0) _startMs = Date.now();
        _thinking += text;
        streamThinkingUpdated(id, text);
    }

    function _handleChunk(chunk) {
        if (!_live()) return;
        var split = StreamParser.splitLines(chunk, _lineBuffer);
        _lineBuffer = split.buffer;

        for (var i = 0; i < split.lines.length; i++) {
            var line = split.lines[i];
            var jsonPart;
            if (line.indexOf("data:") === 0) jsonPart = line.substring(5).trim();
            else if (line.indexOf("{") === 0) jsonPart = line;
            else continue;

            var d = StreamParser.parseDelta(jsonPart, root.format, _toolAcc);
            if (d.outputTokens > 0) _apiTokens = d.outputTokens;
            if (d.inputTokens > 0 || d.outputTokens > 0) {
                var prev = _usage || { input: 0, output: 0 };
                _usage = {
                    input: d.inputTokens > 0 ? d.inputTokens : prev.input,
                    output: d.outputTokens > 0 ? d.outputTokens : prev.output
                };
            }

            if (d.toolCalls && d.toolCalls.length > 0) {
                _seenToolCalls = true;
                for (var tc = 0; tc < d.toolCalls.length; tc++) {
                    var call = d.toolCalls[tc];
                    // Synthesize missing ids (Z.AI omits them); the
                    // round-trip 400s if assistant/result ids differ.
                    if (!call.id)
                        call.id = "call_" + _allToolCalls.length;
                    _pendingToolCalls.push(call);
                    _allToolCalls.push(call);
                }
            }

            if (d.thinking) _thinkingDelta(activeStreamId, d.thinking);

            if (d.content) {
                var routed = StreamParser.routeThinkTags(d.content, _tagBuffer, _insideThinkTag);
                _tagBuffer = routed.tagBuffer;
                _insideThinkTag = routed.insideThinkTag;
                for (var t = 0; t < routed.thinkingParts.length; t++)
                    _thinkingDelta(activeStreamId, routed.thinkingParts[t]);
                for (var c = 0; c < routed.contentParts.length; c++)
                    _contentDelta(activeStreamId, routed.contentParts[c]);
            }

            // Tool calls end the round — execute them, then the
            // coordinator relaunches with the results appended.
            if (d.done && _seenToolCalls && _pendingToolCalls.length > 0) {
                _executeNextToolCall();
                return;
            }
        }
    }

    function _handleFinished(raw) {
        if (!_live()) return;
        var parsed = StreamParser.extractHttpStatus(raw);

        if (isStreaming && _content.length === 0 && _thinking.length === 0 &&
            parsed.status >= 200 && parsed.status < 400 && parsed.body) {
            var fallback = StreamParser.extractNonStreamingText(parsed.body, root.format);
            if (fallback) {
                var routed = StreamParser.routeThinkTags(fallback, "", false);
                for (var t = 0; t < routed.thinkingParts.length; t++)
                    _thinkingDelta(activeStreamId, routed.thinkingParts[t]);
                for (var c = 0; c < routed.contentParts.length; c++)
                    _contentDelta(activeStreamId, routed.contentParts[c]);
                _finalize();
                return;
            }
        }

        if (parsed.status >= 400) {
            var msg = "Request failed (HTTP " + parsed.status + ")";
            var hint = ErrorHints.httpErrorHint(parsed.status);
            if (hint) msg += "\n" + hint;
            var preview = parsed.body.length > 600
                ? parsed.body.substring(0, 600) + "\u2026" : parsed.body.trim();
            if (preview) msg += "\n\n" + preview;
            _fail(msg);
            return;
        }

        // Tool calls were seen but execution never started (provider
        // ended the stream without a completion event we recognize).
        if (isStreaming && _seenToolCalls && _pendingToolCalls.length > 0) {
            _executeNextToolCall();
            return;
        }

        if (isStreaming) {
            if (!_seenToolCalls && _content.length === 0 && _thinking.length === 0) {
                _fail("No response received.\nCheck the base URL and model, and that the server is reachable.");
                return;
            }
            _finalize();
        }
    }

    function _finalize() {
        if (!isStreaming) return;
        // A tool round is never final — the coordinator relaunches.
        if (_seenToolCalls) return;
        var id = activeStreamId;
        _flushTagBuffer();
        _insideThinkTag = false;
        isStreaming = false;
        activeStreamId = "";
        streamFinalized(id, _stats(), _usage);
    }

    function _fail(message) {
        if (!isStreaming) return;
        var id = activeStreamId;
        isStreaming = false;
        activeStreamId = "";
        streamError(id, message);
    }

    // ── MCP tool round execution ──────────────────────────────────

    function _executeNextToolCall() {
        // One MCP call in flight at a time.
        if (_toolExecActive) return;
        if (_pendingToolCalls.length === 0) {
            _resumeWithToolResults();
            return;
        }
        var call = _pendingToolCalls.shift();
        var toolName = call.function ? call.function.name : call.name;
        var toolArgs = Providers.parseToolArgs(
            call.function ? call.function.arguments : call.arguments);
        if (!mcpService || !mcpService.isConnected) {
            _toolResults.push({ tool_call_id: call.id || toolName, name: toolName,
                                role: "tool", content: "Error: MCP service not connected" });
            _executeNextToolCall();
            return;
        }
        toolActivity(activeStreamId, toolName, "call", "");
        var callId = mcpService.callTool(toolName, toolArgs);
        _toolExecActive = true;
        _pendingCallId = callId;
        _pendingToolCallMeta = { id: call.id || ("call_" + callId), name: toolName };
    }

    function _onToolCallCompleted(callId, result) {
        if (callId !== _pendingCallId) return;
        _pendingCallId = -1;
        _toolExecActive = false;
        var meta = _pendingToolCallMeta;
        // Full envelope for the UI log, unwrapped text for the model
        // (Providers.unwrapMcpResult; the raw envelope can prompt
        // duplicate tool calls on long responses).
        var rawText = (typeof result === "string") ? result : JSON.stringify(result);
        toolActivity(activeStreamId, meta.name, "result", rawText);
        var modelText = Providers.unwrapMcpResult(result);
        _toolResults.push({
            role: "tool",
            tool_call_id: meta.id,
            name: meta.name,
            content: modelText
        });
        _pendingToolCallMeta = null;
        _executeNextToolCall();
    }

    function _onToolCallFailed(callId, error) {
        if (callId !== _pendingCallId) return;
        _pendingCallId = -1;
        _toolExecActive = false;
        var meta = _pendingToolCallMeta;
        toolActivity(activeStreamId, meta ? meta.name : "", "error", error);
        _toolResults.push({
            role: "tool",
            tool_call_id: meta ? meta.id : String(callId),
            name: meta ? meta.name : "",
            content: "Error: " + error
        });
        _pendingToolCallMeta = null;
        _executeNextToolCall();
    }

    function _resumeWithToolResults() {
        _toolExecActive = false;
        if (_toolResults.length === 0) { _finalize(); return; }
        // Append the assistant tool_calls turn + results, then
        // relaunch. Everything else persists across rounds.
        var updated = _conversationMessages.slice();
        updated.push({
            role: "assistant",
            content: _content || "",
            tool_calls: _allToolCalls.slice()
        });
        for (var i = 0; i < _toolResults.length; i++)
            updated.push(_toolResults[i]);
        _toolResults = [];
        _seenToolCalls = false;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolAcc = {};
        streamToolRoundReady(activeStreamId, updated);
    }

    function _stats() {
        if (_startMs === 0) return "";
        var seconds = (Date.now() - _startMs) / 1000;
        var label = seconds.toFixed(1) + "s";
        var tokens = _apiTokens > 0 ? _apiTokens : _deltaCount;
        if (tokens > 0 && seconds > 0.5)
            label += " \u00b7 " + (_apiTokens > 0 ? "" : "~") +
                     (tokens / seconds).toFixed(1) + " tok/s";
        return label;
    }

    Process {
        id: fetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root._pendingStdin) {
                fetcher.write(root._pendingStdin);
                fetcher.stdinEnabled = false;
                root._pendingStdin = "";
            }
        }

        stdout: StdioCollector {
            id: collector
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                if (text.length > root.maxStreamBytes) {
                    fetcher.running = false;
                    root._fail("Response exceeded the 5 MB stream cap.");
                    return;
                }
                var fresh = text.substring(lastLen);
                lastLen = text.length;
                root._handleChunk(fresh);
            }

            onStreamFinished: {
                root._handleFinished(text);
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && root._live()) {
                var msg = "Connection failed (curl exit " + exitCode + ")";
                var hint = ErrorHints.curlExitHint(exitCode);
                if (hint) msg += "\n" + hint;
                root._fail(msg);
            }
            if (root._queuedReq) {
                var queued = root._queuedReq;
                root._queuedReq = null;
                root._startFetch(queued);
            }
        }
    }
}
