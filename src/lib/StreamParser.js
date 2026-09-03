.pragma library

// SSE / NDJSON parsing for OpenAI, Anthropic, Gemini and Ollama
// native streaming endpoints, plus <think> tag routing and the
// NEXUS_STATUS trailer handling.

var OPEN_TAG = "<think>";
var CLOSE_TAG = "</think>";

// Split a raw stdout chunk into complete lines, carrying any partial
// line across reads. CRLF tolerated; blank lines dropped.

function splitLines(chunk, carry) {
    var combined = (carry || "") + (chunk || "");
    var lines = [];
    var start = 0;
    for (var i = 0; i < combined.length; i++) {
        if (combined[i] === "\n") {
            var end = i;
            if (end > start && combined[end - 1] === "\r") end--;
            if (end > start) lines.push(combined.substring(start, end));
            start = i + 1;
        }
    }
    return { lines: lines, buffer: combined.substring(start) };
}

// Parse one stream chunk. `format` picks the wire protocol; `acc`
// accumulates fragmented tool calls across chunks of one round.
// Returns content/thinking deltas, token counts, done flag, toolCalls.

function parseDelta(jsonPart, format, acc) {
    acc = acc || {};
    if (format === "anthropic") return parseAnthropicDelta(jsonPart, acc);
    if (format === "gemini") return parseGeminiDelta(jsonPart);
    if (format === "ollama") return parseOllamaDelta(jsonPart);
    return parseOpenAiDelta(jsonPart, acc);
}

function newDelta() {
    // toolCalls is added only when a provider actually emits calls —
    // consumers treat "absent" as "none".
    return { content: "", thinking: "", inputTokens: 0,
             outputTokens: 0, done: false };
}

function parseOpenAiDelta(jsonPart, acc) {
    var out = newDelta();
    var obj = null;
    try { obj = JSON.parse(jsonPart); } catch (e) { return out; }
    if (!obj || typeof obj !== "object" || obj.error) return out;

    if (obj.usage && typeof obj.usage.completion_tokens === "number")
        out.outputTokens = obj.usage.completion_tokens;
    if (obj.usage && typeof obj.usage.prompt_tokens === "number")
        out.inputTokens = obj.usage.prompt_tokens;

    var choice = (obj.choices && obj.choices.length > 0) ? obj.choices[0] : null;
    if (!choice) return out;

    if (choice.delta) {
        if (typeof choice.delta.content === "string") out.content = choice.delta.content;
        if (typeof choice.delta.reasoning_content === "string")
            out.thinking = choice.delta.reasoning_content;
        else if (typeof choice.delta.reasoning === "string")
            out.thinking = choice.delta.reasoning;
        // Tool calls stream as fragments — merge by index in the accumulator
        if (Array.isArray(choice.delta.tool_calls)) {
            acc.openaiTools = acc.openaiTools || {};
            for (var ti = 0; ti < choice.delta.tool_calls.length; ti++) {
                var tc = choice.delta.tool_calls[ti];
                if (!tc) continue;
                var idx = (tc.index !== undefined) ? tc.index : 0;
                if (!acc.openaiTools[idx])
                    acc.openaiTools[idx] = { id: "", name: "", arguments: "" };
                if (tc.id) acc.openaiTools[idx].id = tc.id;
                if (tc.function) {
                    if (tc.function.name && !acc.openaiTools[idx].name)
                        acc.openaiTools[idx].name = tc.function.name;
                    if (tc.function.arguments) {
                        var arg = tc.function.arguments;
                        acc.openaiTools[idx].arguments += (typeof arg === "string")
                            ? arg : JSON.stringify(arg);
                    }
                }
            }
        }
    } else if (choice.message && typeof choice.message.content === "string") {
        out.content = choice.message.content;
        // Non-streaming shape: complete tool calls ride on the message
        if (Array.isArray(choice.message.tool_calls) && choice.message.tool_calls.length > 0)
            out.toolCalls = choice.message.tool_calls;
    }

    if (choice.finish_reason) {
        out.done = true;
        // Materialize accumulated fragments on completion
        if (acc.openaiTools) {
            var calls = [];
            var idxs = Object.keys(acc.openaiTools).sort(function (a, b) { return a - b; });
            for (var oi = 0; oi < idxs.length; oi++) {
                var t = acc.openaiTools[idxs[oi]];
                if (t.name)
                    calls.push({ id: t.id, function: { name: t.name, arguments: t.arguments } });
            }
            if (calls.length > 0) out.toolCalls = calls;
        }
    }
    return out;
}

// Anthropic streaming payloads are single JSON objects; the `event:` SSE
// lines never reach the parser (splitLines/handler drops them).

function parseAnthropicDelta(jsonPart, acc) {
    var out = newDelta();
    var obj = null;
    try { obj = JSON.parse(jsonPart); } catch (e) { return out; }
    if (!obj || typeof obj !== "object") return out;

    // Error events carry the provider's message; surface it and finish.
    if (obj.type === "error") {
        var msg = (obj.error && typeof obj.error.message === "string")
            ? obj.error.message : "unknown error";
        out.content = "API error: " + msg;
        out.done = true;
        return out;
    }
    if (obj.error) return out;

    // message_start carries the prompt-side usage (input_tokens);
    // the cumulative output count arrives later on message_delta.
    if (obj.type === "message_start" && obj.message && obj.message.usage
            && typeof obj.message.usage.input_tokens === "number")
        out.inputTokens = obj.message.usage.input_tokens;

    if (obj.type === "content_block_start" && obj.content_block
            && obj.content_block.type === "tool_use") {
        // Tool use block: remember id/name, input arrives as fragments
        acc.anthropicBlocks = acc.anthropicBlocks || {};
        acc.anthropicBlocks[obj.index] = {
            id: obj.content_block.id || "",
            name: obj.content_block.name || "",
            json: ""
        };
    } else if (obj.type === "content_block_delta" && obj.delta) {
        if (obj.delta.type === "text_delta" && typeof obj.delta.text === "string")
            out.content = obj.delta.text;
        else if (obj.delta.type === "thinking_delta" && typeof obj.delta.thinking === "string")
            out.thinking = obj.delta.thinking;
        else if (obj.delta.type === "input_json_delta" && obj.delta.partial_json) {
            acc.anthropicBlocks = acc.anthropicBlocks || {};
            if (acc.anthropicBlocks[obj.index])
                acc.anthropicBlocks[obj.index].json += obj.delta.partial_json;
        }
    } else if (obj.type === "content_block_stop") {
        var blk = (acc.anthropicBlocks || {})[obj.index];
        if (blk) {
            acc.anthropicTools = acc.anthropicTools || [];
            var args = {};
            try { args = blk.json ? JSON.parse(blk.json) : {}; } catch (e) { args = {}; }
            acc.anthropicTools.push({ id: blk.id, function: { name: blk.name, arguments: args } });
        }
    } else if (obj.type === "message_delta") {
        out.done = true;
        if (obj.delta && obj.delta.stop_reason === "tool_use"
                && acc.anthropicTools && acc.anthropicTools.length > 0)
            out.toolCalls = acc.anthropicTools.slice();
        if (obj.usage && typeof obj.usage.output_tokens === "number")
            out.outputTokens = obj.usage.output_tokens;
    } else if (obj.type === "message_stop") {
        out.done = true;
    }
    // message_start / ping → empty
    return out;
}

function parseGeminiDelta(jsonPart) {
    var out = newDelta();
    var obj = null;
    try { obj = JSON.parse(jsonPart); } catch (e) { return out; }
    if (!obj || typeof obj !== "object" || obj.error) return out;

    if (obj.usageMetadata) {
        if (typeof obj.usageMetadata.candidatesTokenCount === "number")
            out.outputTokens = obj.usageMetadata.candidatesTokenCount;
        if (typeof obj.usageMetadata.promptTokenCount === "number")
            out.inputTokens = obj.usageMetadata.promptTokenCount;
    }

    var cand = (obj.candidates && obj.candidates.length > 0) ? obj.candidates[0] : null;
    if (!cand) return out;

    var parts = (cand.content && cand.content.parts) || [];
    var text = "";
    var think = "";
    for (var i = 0; i < parts.length; i++) {
        if (!parts[i]) continue;
        // Gemini emits function calls complete (never fragmented) —
        // check before the text guard: these parts carry no text.
        if (parts[i].functionCall) {
            if (!Array.isArray(out.toolCalls))
                out.toolCalls = [];
            // thoughtSignature must be echoed back on relaunch or
            // Gemini 400s; accept both spellings.
            var sig = parts[i].thoughtSignature
                      || parts[i].thought_signature
                      || null;
            out.toolCalls.push({
                id: "",
                function: {
                    name: parts[i].functionCall.name || "",
                    arguments: parts[i].functionCall.args || {}
                },
                thoughtSignature: sig
            });
        }
        if (typeof parts[i].text !== "string") continue;
        if (parts[i].thought === true) think += parts[i].text;
        else text += parts[i].text;
    }
    out.content = text;
    out.thinking = think;

    if (cand.finishReason) out.done = true;
    return out;
}

// Ollama native /api/chat: NDJSON lines; deltas in message.content /
// message.thinking; tool calls arrive complete (object arguments);
// final line has done:true + token counts.

function parseOllamaDelta(jsonPart) {
    var out = newDelta();
    var obj = null;
    try { obj = JSON.parse(jsonPart); } catch (e) { return out; }
    if (!obj || typeof obj !== "object" || obj.error) return out;

    var msg = obj.message;
    if (msg && typeof msg === "object") {
        if (typeof msg.content === "string") out.content = msg.content;
        if (typeof msg.thinking === "string") out.thinking = msg.thinking;
        if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
            out.toolCalls = [];
            for (var i = 0; i < msg.tool_calls.length; i++) {
                var tc = msg.tool_calls[i];
                var fn = (tc && tc.function) || {};
                out.toolCalls.push({
                    id: tc.id || "",
                    function: { name: fn.name || "", arguments: fn.arguments || {} }
                });
            }
        }
    }

    if (obj.done === true) {
        out.done = true;
        if (typeof obj.eval_count === "number") out.outputTokens = obj.eval_count;
        if (typeof obj.prompt_eval_count === "number")
            out.inputTokens = obj.prompt_eval_count;
    }
    return out;
}

function couldStartTag(tail, tag) {
    return tail.length < tag.length && tag.indexOf(tail) === 0;
}

// Route streamed text into content vs thinking, tracking <think> tags
// that may be split across chunks. Newlines directly after a tag are
// stripped. tagBuffer/insideThinkTag are carried between calls.

function routeThinkTags(text, tagBuffer, insideThinkTag) {
    var res = {
        contentParts: [],
        thinkingParts: [],
        tagBuffer: "",
        insideThinkTag: !!insideThinkTag
    };
    var input = (tagBuffer || "") + (text || "");

    function emit(s) {
        if (s.length === 0) return;
        if (res.insideThinkTag) res.thinkingParts.push(s);
        else res.contentParts.push(s);
    }

    var plain = "";
    var i = 0;
    while (i < input.length) {
        if (input[i] === "<") {
            var rest = input.substring(i);
            if (!res.insideThinkTag && rest.indexOf(OPEN_TAG) === 0) {
                emit(plain); plain = "";
                res.insideThinkTag = true;
                i += OPEN_TAG.length;
                if (input[i] === "\n") i++;
                continue;
            }
            if (res.insideThinkTag && rest.indexOf(CLOSE_TAG) === 0) {
                emit(plain); plain = "";
                res.insideThinkTag = false;
                i += CLOSE_TAG.length;
                if (input[i] === "\n") i++;
                continue;
            }
            // Not a full tag — might be a tag split across chunks
            var relevant = res.insideThinkTag ? CLOSE_TAG : OPEN_TAG;
            if (couldStartTag(rest, relevant)) {
                emit(plain); plain = "";
                res.tagBuffer = rest;
                return res;
            }
        }
        plain += input[i];
        i++;
    }
    emit(plain);
    return res;
}

// Extract the HTTP status appended by curl -w "NEXUS_STATUS:%{http_code}".
// Returns { status, body } — status 0 when the marker is absent.

function extractHttpStatus(text) {
    var out = { status: 0, body: text || "" };
    if (!text) return out;
    var marker = "NEXUS_STATUS:";
    var idx = text.lastIndexOf(marker);
    if (idx < 0) return out;
    var tail = text.substring(idx + marker.length).trim();
    var status = parseInt(tail, 10);
    if (isNaN(status)) return out;
    out.status = status;
    out.body = text.substring(0, idx);
    if (out.body.length > 0 && out.body[out.body.length - 1] === "\n")
        out.body = out.body.substring(0, out.body.length - 1);
    return out;
}

// Pull assistant text out of a non-streaming completion response
// (used when a "streaming" endpoint answers with a single JSON body).

function extractNonStreamingText(body, format) {
    if (format === "anthropic") return extractAnthropicText(body);
    if (format === "gemini") return extractGeminiText(body);
    if (format === "ollama") return extractOllamaText(body);
    try {
        var obj = JSON.parse(body);
        if (obj && obj.choices && obj.choices.length > 0 && obj.choices[0].message)
            return typeof obj.choices[0].message.content === "string"
                ? obj.choices[0].message.content : "";
    } catch (e) {}
    return "";
}

function extractAnthropicText(body) {
    try {
        var obj = JSON.parse(body);
        if (obj && Array.isArray(obj.content)) {
            var text = "";
            for (var i = 0; i < obj.content.length; i++)
                if (obj.content[i] && typeof obj.content[i].text === "string")
                    text += obj.content[i].text;
            return text;
        }
    } catch (e) {}
    return "";
}

function extractOllamaText(body) {
    try {
        var obj = JSON.parse(body);
        if (obj && obj.message && typeof obj.message.content === "string")
            return obj.message.content;
    } catch (e) {}
    return "";
}

function extractGeminiText(body) {
    try {
        var obj = JSON.parse(body);
        var parts = (obj && obj.candidates && obj.candidates.length > 0 &&
                     obj.candidates[0].content && obj.candidates[0].content.parts) || [];
        var text = "";
        for (var i = 0; i < parts.length; i++)
            if (parts[i] && typeof parts[i].text === "string" &&
                parts[i].thought !== true) text += parts[i].text;
        return text;
    } catch (e) {}
    return "";
}
