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
    // Which inline block is open: "" | "think" | "narrate".
    property string _tagState: ""
    // The model's own status lines, each terminated with "\n" by the parser
    // so lines stay separable for the activity row's label.
    property string _narration: ""
    // Generation time excluding tool-call waits (see _pauseGeneration).
    property real _genMs: 0
    property real _genStartMs: 0
    property int _deltaCount: 0
    property int _apiTokens: 0

    signal streamContentUpdated(string streamId, string delta)
    signal streamThinkingUpdated(string streamId, string delta)
    // One chunk of the model's in-band status line(s) — never part of the
    // answer, never sent back to the provider.
    signal streamNarration(string streamId, string delta)
    signal streamActivity(string streamId)
    // A tool call still being streamed: friendly name + argument chars so
    // far. Lets the chat show "Writing Shell… 1,234 chars" instead of
    // looking frozen while a big heredoc arrives.
    signal streamToolDraft(string streamId, string name, int chars)
    // Fired once data actually arrives; the coordinator disarms its
    // never-responded watchdog so silent reasoning cannot kill a live turn.
    // Live stats + estimated usage (~2/s).
    signal streamProgress(string streamId, string stats, var usage)
    // usage: {input, output} token counts for the request, or null
    // when the provider reported nothing.
    signal streamFinalized(string streamId, string stats, var usage)
    signal streamError(string streamId, string message)
    signal streamCancelled(string streamId, string stats)

    // Raw-stdout memory backstop (SSE envelope ~10x the text).
    readonly property int maxStreamBytes: 64 * 1024 * 1024
    // Model-visible runaway guard (chars).
    readonly property int maxOutputChars: 4000000
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
    // Tool-call draft reported to the UI (name + argument chars so far).
    // Last token/thinking delta: a long silence is reported as
    // "waiting…" instead of a tok/s that keeps dropping.
    property real _lastDeltaMs: 0
    property string _draftName: ""
    property int _draftChars: -1
    property var _conversationMessages: [] // neutral payload messages
    // Offset into _content where the current tool round's text starts
    // (_content accumulates across rounds for display; each round's
    // assistant tool_calls turn carries only its own text).
    property int _roundStart: 0
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
        _tagState = "";
        _narration = "";
        _genMs = 0;
        _genStartMs = 0;
        _deltaCount = 0;
        _apiTokens = 0;
        _seenToolCalls = false;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolResults = [];
        _toolAcc = {};
        _conversationMessages = [];
        _roundStart = 0;
        _draftName = "";
        _draftChars = -1;
        _lastDeltaMs = 0;
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
        _pauseGeneration();          // freeze clock before the readout
        _queuedReq = null;           // a Stop must never launch a parked request later
        isStreaming = false;
        activeStreamId = "";
        fetcher.running = false;
        // Drop the in-flight tool round: a capture that lands after Stop
        // must not push its image into a fresh request (the screenshot
        // would reach the provider after the user asked it to stop).
        _pendingCallId = -1;
        _pendingToolCallMeta = null;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolResults = [];
        _toolExecActive = false;
        _seenToolCalls = false;
        streamCancelled(id, _stats());
    }

    function reset() {
        if (fetcher.running) fetcher.running = false;
        isStreaming = false;
        activeStreamId = "";
        _lineBuffer = "";
        _pendingStdin = "";
        _queuedReq = null;
        _pendingCallId = -1;
        _pendingToolCallMeta = null;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolResults = [];
        _toolExecActive = false;
    }

    function _live() {
        return isStreaming && _launchGen === _gen;
    }

    // ── internals ─────────────────────────────────────────────────

    function _flushTagBuffer() {
        if (_tagBuffer.length === 0) return;
        if (_tagState === "think") _thinkingDelta(activeStreamId, _tagBuffer);
        else if (_tagState === "narrate") _narrationDelta(activeStreamId, _tagBuffer);
        else _contentDelta(activeStreamId, _tagBuffer);
        _tagBuffer = "";
    }

    function _contentDelta(id, text) {
        if (!text) return;
        if (_genStartMs === 0) _genStartMs = Date.now();
        _lastDeltaMs = Date.now();
        _deltaCount++;
        _content += text;
        streamContentUpdated(id, text);
    }

    function _thinkingDelta(id, text) {
        if (!text) return;
        if (_genStartMs === 0) _genStartMs = Date.now();
        _lastDeltaMs = Date.now();
        _deltaCount++;
        _thinking += text;
        streamThinkingUpdated(id, text);
    }

    // Narration is proof the provider is producing output (it feeds the
    // liveness clock), but never the answer: it does not touch _content and
    // is outside the runaway guard's length check.
    function _narrationDelta(id, text) {
        if (!text) return;
        if (_genStartMs === 0) _genStartMs = Date.now();
        _lastDeltaMs = Date.now();
        _deltaCount++;
        _narration += text;
        streamNarration(id, text);
    }

    // Stop the generation clock during a tool wait.
    function _pauseGeneration() {
        if (_genStartMs > 0) {
            _genMs += Date.now() - _genStartMs;
            _genStartMs = 0;
        }
    }

    function _genSeconds() {
        var ms = _genMs + (_genStartMs > 0 ? (Date.now() - _genStartMs) : 0);
        return ms / 1000;
    }

    function _handleChunk(chunk) {
        if (!_live()) return;
        if (chunk && chunk.length > 0) streamActivity(activeStreamId);
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

            // Live draft of the call being written (openai/anthropic
            // fragment the arguments; gemini/ollama send them complete).
            var draft = StreamParser.toolDraft(root.format, _toolAcc);
            if (draft && (draft.name !== _draftName || draft.chars !== _draftChars)) {
                _draftName = draft.name;
                _draftChars = draft.chars;
                streamToolDraft(activeStreamId, draft.name, draft.chars);
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
                var routed = StreamParser.routeStreamTags(d.content, _tagBuffer, _tagState);
                _tagBuffer = routed.tagBuffer;
                _tagState = routed.state;
                for (var n = 0; n < routed.narrateParts.length; n++)
                    _narrationDelta(activeStreamId, routed.narrateParts[n]);
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

        // Runaway guard.
        if (_content.length + _thinking.length > maxOutputChars) {
            fetcher.running = false;
            _fail("Response exceeded the output cap (" +
                  Math.round(maxOutputChars / 1000) +
                  "k characters). The model appears to be repeating itself.");
        }
    }

    function _handleFinished(raw) {
        if (!_live()) return;
        var parsed = StreamParser.extractHttpStatus(raw);

        if (isStreaming && _content.length === 0 && _thinking.length === 0 &&
            parsed.status >= 200 && parsed.status < 400 && parsed.body) {
            var fallback = StreamParser.extractNonStreamingText(parsed.body, root.format);
            if (fallback) {
                var routed = StreamParser.routeStreamTags(fallback, "", "");
                for (var n = 0; n < routed.narrateParts.length; n++)
                    _narrationDelta(activeStreamId, routed.narrateParts[n]);
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
            if (!_seenToolCalls && _content.length === 0 && _thinking.length === 0
                    && _narration.length === 0) {
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
        _tagState = "";
        _pauseGeneration();          // close clock
        isStreaming = false;
        activeStreamId = "";
        streamFinalized(id, _stats(), _usage);
    }

    function _fail(message) {
        if (!isStreaming) return;
        var id = activeStreamId;
        _tagState = "";
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
        _pauseGeneration();          // don't count the tool wait
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
        if (callId === -1) {
            // Unknown or refused (a native tool switched off mid-flight):
            // a completion can never arrive, so waiting would hang the
            // round forever. Report it like any other tool failure.
            var why = "tool \"" + toolName + "\" is not available.";
            toolActivity(activeStreamId, toolName, "error", why);
            _toolResults.push({ role: "tool",
                                tool_call_id: call.id || toolName,
                                name: toolName,
                                content: "Error: " + why });
            _executeNextToolCall();
            return;
        }
        _toolExecActive = true;
        _pendingCallId = callId;
        _pendingToolCallMeta = { id: call.id || ("call_" + callId), name: toolName };
    }

    function _onToolCallCompleted(callId, result, images) {
        // No pending meta means this completion belongs to a round that is
        // already gone (refused/cancelled) — the -1 sentinel must never let
        // it inject a result into a newer turn.
        if (callId !== _pendingCallId || !_pendingToolCallMeta) return;
        _pendingCallId = -1;
        _toolExecActive = false;
        var meta = _pendingToolCallMeta;
        // Full envelope for the UI log, unwrapped text for the model
        // (Providers.unwrapMcpResult; the raw envelope can prompt
        // duplicate tool calls on long responses).
        var rawText = (typeof result === "string") ? result : JSON.stringify(result);
        toolActivity(activeStreamId, meta.name, "result", rawText);
        var modelText = Providers.unwrapMcpResult(result);
        var rec = {
            role: "tool",
            tool_call_id: meta.id,
            name: meta.name,
            content: modelText
        };
        // Screen captures arrive with an image; it rides the tool record
        // and Providers places it per wire format. Turn-scoped: this
        // array never reaches the persisted message rows.
        var imgs = Providers.sanitizeImages(images);
        if (imgs.length > 0) rec.images = imgs;
        _toolResults.push(rec);
        _pendingToolCallMeta = null;
        _executeNextToolCall();
    }

    function _onToolCallFailed(callId, error) {
        if (callId !== _pendingCallId || !_pendingToolCallMeta) return;
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
        // Only the text produced in THIS round belongs on its tool_calls
        // turn — _content accumulates across rounds for display.
        var roundText = _content.substring(_roundStart);
        updated.push({
            role: "assistant",
            content: roundText,
            tool_calls: _allToolCalls.slice()
        });
        for (var i = 0; i < _toolResults.length; i++)
            updated.push(_toolResults[i]);
        // Keep the memory in step with what was sent. Without this the
        // next round rebuilds from the pre-turn snapshot and drops the
        // previous tool block — including any captured screenshot.
        _conversationMessages = updated.slice();
        _roundStart = _content.length;
        _toolResults = [];
        _seenToolCalls = false;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolAcc = {};
        // A round boundary ends any inline block: an unterminated
        // <narrate> (or a half-buffered tag) must not swallow the next
        // round's first line into narration.
        _tagBuffer = "";
        _tagState = "";
        streamToolRoundReady(activeStreamId, updated);
    }

    // "45s" / "2m05s" — the silence counter next to a stalled label.
    function _silenceText(ms) {
        var s = Math.max(0, Math.round(ms / 1000));
        if (s < 60) return s + "s";
        return Math.floor(s / 60) + "m" + ("0" + (s % 60)).slice(-2) + "s";
    }

    function _stats() {
        var seconds = _genSeconds();
        if (seconds <= 0) return "";
        var label = seconds.toFixed(1) + "s";
        // A silent provider during a tool-enabled turn is composing the
        // tool call (Ollama delivers it complete, so nothing streams while
        // it assembles the JSON). The counter next to the label keeps
        // moving, so it reads as progress rather than a freeze; past two
        // minutes it is honest about having no response at all.
        if (_lastDeltaMs > 0) {
            var silent = Date.now() - _lastDeltaMs;
            if (silent > 120000)
                return label + " \u00b7 no response for " + _silenceText(silent);
            if (silent > 2500)
                return label + (mcpService
                    ? " \u00b7 writing tool call\u2026 " + _silenceText(silent)
                    : " \u00b7 waiting for the model\u2026 " + _silenceText(silent));
        }
        var tokens = _apiTokens > 0 ? _apiTokens : _deltaCount;
        if (tokens > 0 && seconds > 0.5)
            label += " \u00b7 " + (_apiTokens > 0 ? "" : "~") +
                     (tokens / seconds).toFixed(1) + " tok/s";
        return label;
    }

    // Estimated usage: real counts when known, else chars/4.
    function _liveUsage() {
        var input = (_usage && _usage.input > 0) ? _usage.input : 0;
        var output = _apiTokens > 0
            ? _apiTokens
            : Math.round((_content.length + _thinking.length) / 4);
        return { input: input, output: output };
    }

    function _emitProgress() {
        // Also emits during a tool wait, showing the frozen tok/s.
        if (!isStreaming || (_genStartMs === 0 && _genMs === 0)) return;
        streamProgress(activeStreamId, _stats(), _liveUsage());
    }

    // Live stats ticker (runs while streaming).
    Timer {
        id: progressTimer
        interval: 500
        repeat: true
        running: root.isStreaming
        onTriggered: root._emitProgress()
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
