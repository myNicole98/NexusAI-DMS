.pragma library

// Multi-provider registry + wire-format request builders (openai,
// anthropic, gemini, ollama). All secrets travel via curl stdin
// config — never argv.

var STATUS_TRAILER = "\\nNEXUS_STATUS:%{http_code}\\n";

// Built-in provider types. Instances are {id, type, name, baseUrl,
// checkedModels[], envVar?}; format/baseUrl/envVar below are the
// defaults a new instance starts from. `custom` takes its base URL
// (and optional env-var name) from the instance itself.
var REGISTRY = {
    openai:   { name: "OpenAI",    format: "openai",    baseUrl: "https://api.openai.com/v1",                 envVar: "OPENAI_API_KEY",    needsKey: true },
    claude:   { name: "Anthropic", format: "anthropic", baseUrl: "https://api.anthropic.com",                 envVar: "ANTHROPIC_API_KEY", needsKey: true },
    google:   { name: "Google Generative AI", format: "gemini",    baseUrl: "https://generativelanguage.googleapis.com", envVar: "GEMINI_API_KEY",    needsKey: true },
    groq:     { name: "Groq",      format: "openai",    baseUrl: "https://api.groq.com/openai/v1",            envVar: "GROQ_API_KEY",      needsKey: true },
    deepseek: { name: "DeepSeek",  format: "openai",    baseUrl: "https://api.deepseek.com/v1",               envVar: "DEEPSEEK_API_KEY",  needsKey: true },
    openrouter: { name: "OpenRouter", format: "openai",  baseUrl: "https://openrouter.ai/api/v1",              envVar: "OPENROUTER_API_KEY", needsKey: true },
    perplexity: { name: "Perplexity", format: "openai",  baseUrl: "https://api.perplexity.ai",                 envVar: "PERPLEXITY_API_KEY", needsKey: true },
    zai:      { name: "Z.ai",      format: "openai",    baseUrl: "https://api.z.ai/api/paas/v4",              envVar: "ZAI_API_KEY",       needsKey: true },
    moonshot: { name: "Moonshot",  format: "openai",    baseUrl: "https://api.moonshot.ai/v1",                envVar: "MOONSHOT_API_KEY",  needsKey: true },
    ollama:   { name: "Ollama",    format: "ollama",    baseUrl: "http://localhost:11434/v1",                 envVar: "",                  needsKey: false },
    lmstudio: { name: "LM Studio", format: "openai",    baseUrl: "http://localhost:1234/v1",                  envVar: "",                  needsKey: false },
    custom:   { name: "OpenAI Compatible", format: "openai",    baseUrl: "",                                          envVar: "",                  needsKey: false }
};

var REGISTRY_TYPES = ["openai", "claude", "google", "groq", "deepseek",
                      "openrouter", "perplexity", "zai", "moonshot", "ollama",
                      "lmstudio", "custom"];

function normalizeBaseUrl(url) {
    if (typeof url !== "string") return "";
    var u = url.trim();
    if (u.length === 0 || u.length > 2048) return "";
    if (!/^https?:\/\/.+/ .test(u)) return "";
    if (u[u.length - 1] === "/") u = u.substring(0, u.length - 1);
    return u;
}

// Dynamic per-instance env var for custom providers so several
// custom setups don't share one key: "My Proxy" -> CUSTOM_MY_PROXY_KEY.
function customEnvVar(name) {
    var s = String(name || "").toUpperCase().replace(/[^A-Z0-9]+/g, "_");
    s = s.replace(/^_+|_+$/g, "");
    if (!s) s = "CUSTOM";
    return "CUSTOM_" + s + "_KEY";
}

function sanitizeApiKey(key) {
    if (typeof key !== "string") return "";
    // Strip control chars anywhere (blocks config/header injection), trim ends
    return key.replace(/[\x00-\x1f\x7f]/g, "").trim();
}

// Escape a value for a double-quoted curl config directive.
function escapeCurlConfig(s) {
    if (typeof s !== "string") return "";
    return s.replace(/\\/g, "\\\\")
            .replace(/"/g, '\\"')
            .replace(/\n/g, "\\n")
            .replace(/\r/g, "\\r")
            .replace(/\t/g, "\\t");
}

function curlCmd(timeoutSeconds) {
    return ["curl", "-K", "-", "-N", "-sS", "--no-buffer", "--show-error",
            "--connect-timeout", "5",
            "--max-time", String(Math.max(5, Math.floor(timeoutSeconds || 300))),
            "-w", STATUS_TRAILER];
}

function endsWithVersion(u) {
    return /\/v\d+$/.test(u);
}

// Strip a trailing version segment from a normalized base so the
// versioned path appended below never doubles it (…/v1/v1/messages).
// anthropic bases may end in /v<N>; gemini bases in /v<N> or /v<N>beta.
function stripVersion(base, allowBeta) {
    return base.replace(allowBeta ? /\/v\d+(beta)?$/ : /\/v\d+$/, "");
}

// OpenAI-compatible chat endpoint: append /v1 unless the base already
// ends in a version segment.
function chatUrl(baseUrl) {
    var base = normalizeBaseUrl(baseUrl);
    if (!base) return "";
    return endsWithVersion(base) ? base + "/chat/completions"
                                 : base + "/v1/chat/completions";
}

function noEnv() { return ""; }

// Wire format for an instance: explicit instance.format wins, else the
// registry entry for its type, else openai.
function formatOf(instance) {
    if (instance && instance.format) return instance.format;
    var reg = instance ? REGISTRY[instance.type] : null;
    return (reg && reg.format) || "openai";
}

// API key resolution per instance:
// session key (memory) → registry env var → (custom only) instance
// envVar → NEXUS_API_KEY → "". envLookup(name) returns the raw env
// string; results are sanitized before use.
function resolveInstanceKey(instance, sessionKey, envLookup) {
    var k = sanitizeApiKey(sessionKey);
    if (k) return k;
    if (!instance) return "";
    var reg = REGISTRY[instance.type] || {};
    if (reg.envVar) {
        k = sanitizeApiKey(envLookup ? envLookup(reg.envVar) : "");
        if (k) return k;
    }
    if (instance.type === "custom") {
        var dyn = customEnvVar(instance.name);
        k = sanitizeApiKey(envLookup ? envLookup(dyn) : "");
        if (k) return k;
        if (instance.envVar) {
            k = sanitizeApiKey(envLookup ? envLookup(instance.envVar) : "");
            if (k) return k;
        }
        k = sanitizeApiKey(envLookup ? envLookup("NEXUS_API_KEY") : "");
        if (k) return k;
    }
    return "";
}

// ── Images (vision) ───────────────────────────────────────────────
// Neutral shape: images: [{mime, data}] (raw base64, no data:
// prefix). sanitizeImages is the single validation gate, applied at
// payload build AND in each wire builder.

var IMAGE_MIMES = ["image/png", "image/jpeg", "image/webp", "image/gif"];
var DEFAULT_MAX_IMAGES = 4;
var DEFAULT_MAX_IMAGE_BYTES = 10 * 1024 * 1024;

// "IMAGE/PNG;charset=x" → "image/png"; garbage → ""
function normalizeMime(m) {
    var s = String(m || "").toLowerCase();
    var semi = s.indexOf(";");
    if (semi >= 0) s = s.substring(0, semi);
    return s.trim();
}

function isBase64(s) {
    return /^[A-Za-z0-9+/]*={0,2}$/.test(s);
}

// Returns a clean array (at most maxImages entries); entries with an
// unsupported mime, non-base64 data, or a decoded size over maxBytes
// are dropped silently — the caller compares lengths if it needs to
// surface a rejection hint.
function sanitizeImages(images, maxImages, maxBytes) {
    var max = typeof maxImages === "number" && maxImages > 0
        ? Math.floor(maxImages) : DEFAULT_MAX_IMAGES;
    var bytes = typeof maxBytes === "number" && maxBytes > 0
        ? maxBytes : DEFAULT_MAX_IMAGE_BYTES;
    if (!Array.isArray(images)) return [];
    var out = [];
    for (var i = 0; i < images.length && out.length < max; i++) {
        var e = images[i];
        if (!e || typeof e !== "object") continue;
        var mime = normalizeMime(e.mime);
        if (IMAGE_MIMES.indexOf(mime) < 0) continue;
        var data = String(e.data || "").replace(/\s+/g, "");
        if (!data || !isBase64(data)) continue;
        if (Math.floor(data.length * 3 / 4) > bytes) continue;
        out.push({ mime: mime, data: data });
    }
    return out;
}

// Per-format content builders: images first, then the text part when
// non-empty (image-only turns omit the text part entirely).

function openaiImageParts(images, text) {
    var parts = [];
    for (var i = 0; i < images.length; i++)
        parts.push({ type: "image_url",
                     image_url: { url: "data:" + images[i].mime
                         + ";base64," + images[i].data } });
    if (text) parts.push({ type: "text", text: text });
    return parts;
}

function anthropicContent(images, text) {
    var blocks = [];
    for (var i = 0; i < images.length; i++)
        blocks.push({ type: "image",
                      source: { type: "base64",
                                media_type: images[i].mime,
                                data: images[i].data } });
    if (text) blocks.push({ type: "text", text: text });
    return blocks;
}

function geminiParts(images, text) {
    var parts = [];
    for (var i = 0; i < images.length; i++)
        parts.push({ inline_data: { mime_type: images[i].mime,
                                    data: images[i].data } });
    if (text) parts.push({ text: text });
    return parts;
}

// Ollama takes bare base64 strings in a per-message images array
// (mime is inferred by the server).

function imagesForOllama(images) {
    var out = [];
    for (var i = 0; i < images.length; i++)
        if (images[i] && images[i].data) out.push(images[i].data);
    return out;
}

// Map conversation records ({role, content, state}) to a format-
// agnostic payload: trimmed system string + history messages. User
// messages always pass; assistant messages only when state === "done".
// Role mapping (gemini assistant → "model") happens in the builders.
function buildApiPayload(instance, opts) {
    opts = opts || {};
    var out = { system: (opts.systemPrompt || "").trim(), messages: [] };
    var hist = opts.messages || [];
    for (var i = 0; i < hist.length; i++) {
        var m = hist[i];
        if (!m) continue;
        if (m.role === "user") {
            // Image-only turns (empty text) must survive the filter.
            var imgs = sanitizeImages(m.images);
            if (!m.content && imgs.length === 0) continue;
            var rec = { role: "user", content: m.content };
            if (imgs.length > 0) rec.images = imgs;
            out.messages.push(rec);
        }
        else if (m.role === "assistant" && m.state === "done" && m.content)
            out.messages.push({ role: "assistant", content: m.content });
    }
    return out;
}

// ── Tool calling (MCP) ────────────────────────────────────────────
// Neutral shapes flowing through the request builders:
//   tools:      [{ type: "function", function: { name, description, parameters } }]
//   assistant:  { role: "assistant", content, tool_calls: [{id, function: {name, arguments}}] }
//   results:    { role: "tool", tool_call_id, name, content }

// Tool-call arguments may be a JSON string (OpenAI wire) or an object
// (Gemini/Ollama shapes) — normalize to an object.

function parseToolArgs(args) {
    if (typeof args !== "string") return args || {};
    try { return JSON.parse(args); } catch (e) { return {}; }
}

// Unwrap an MCP result envelope to model-visible text:
// string → as-is; {content:[{text}]} → blocks joined; isError →
// "[Tool error]: " prefix; else JSON.stringify. Raw envelopes can
// prompt duplicate tool calls on long responses.
function unwrapMcpResult(result) {
    if (result === null || result === undefined) return "";
    if (typeof result === "string") return result;
    if (typeof result !== "object") return String(result);
    if (Array.isArray(result.content)) {
        var parts = [];
        for (var i = 0; i < result.content.length; i++) {
            var c = result.content[i];
            if (!c || typeof c !== "object") continue;
            if (c.type === "text" && typeof c.text === "string")
                parts.push(c.text);
        }
        var joined = parts.join("\n\n");
        if (result.isError === true) joined = "[Tool error]: " + joined;
        return joined;
    }
    return JSON.stringify(result);
}

// OpenAI wire: assistant tool calls serialize their arguments as a
// JSON string; plain messages pass through unchanged.

function messagesForOpenai(messages) {
    var out = [];
    for (var i = 0; i < messages.length; i++) {
        var m = messages[i];
        if (m.tool_calls && m.tool_calls.length > 0) {
            var tcs = [];
            for (var t = 0; t < m.tool_calls.length; t++) {
                var fn = m.tool_calls[t].function || {};
                tcs.push({
                    // OpenAI-compat spec requires a non-empty id;
                    // some providers omit it on streaming deltas.
                    id: m.tool_calls[t].id || ("call_" + t),
                    type: "function",
                    function: {
                        name: fn.name || "",
                        arguments: typeof fn.arguments === "string"
                            ? fn.arguments : JSON.stringify(fn.arguments || {})
                    }
                });
            }
            out.push({ role: "assistant", content: m.content || "", tool_calls: tcs });
        } else {
            out.push(m);
        }
    }
    return out;
}

// OpenAI-shaped tool definitions → Anthropic `tools` field.

function toolsForAnthropic(tools) {
    var out = [];
    for (var i = 0; i < tools.length; i++) {
        var fn = tools[i].function || {};
        out.push({
            name: fn.name,
            description: fn.description || "",
            input_schema: fn.parameters || { type: "object", properties: {} }
        });
    }
    return out;
}

// OpenAI-shaped tool definitions → Gemini `tools` field. Gemini
// 400s on non-Gemini schema keywords, so schemas are deep-sanitized.

// Fields Gemini's Schema proto actually accepts. Everything else in
// the input schema is dropped.
var GEMINI_SCHEMA_KEYS = {
    type: 1, format: 1, description: 1, nullable: 1, enum: 1,
    items: 1, properties: 1, required: 1, minItems: 1, maxItems: 1,
    minLength: 1, maxLength: 1, minimum: 1, maximum: 1, pattern: 1,
    anyOf: 1
};

var GEMINI_SCHEMA_TYPES = ["string", "number", "integer", "boolean",
                           "array", "object"];

function sanitizeGeminiSchema(schema) {
    if (!schema || typeof schema !== "object" || Array.isArray(schema))
        return null;
    var out = {};
    for (var k in schema) {
        if (!Object.prototype.hasOwnProperty.call(GEMINI_SCHEMA_KEYS, k))
            continue;
        var v = schema[k];
        if (k === "type") {
            var t = String(v).toLowerCase();
            if (GEMINI_SCHEMA_TYPES.indexOf(t) >= 0) out.type = t;
        } else if (k === "items") {
            out.items = sanitizeGeminiSchema(v) || { type: "string" };
        } else if (k === "properties") {
            var props = {};
            if (v && typeof v === "object" && !Array.isArray(v))
                for (var p in v)
                    props[p] = sanitizeGeminiSchema(v[p]) || { type: "string" };
            out.properties = props;
        } else if (k === "anyOf") {
            if (Array.isArray(v))
                out.anyOf = v.map(sanitizeGeminiSchema);
        } else if (k === "required" || k === "enum") {
            if (Array.isArray(v)) out[k] = v;
        } else {
            out[k] = v;   // scalars: format, description, nullable, bounds, pattern
        }
    }
    return out;
}

function toolsForGemini(tools) {
    var decls = [];
    for (var i = 0; i < tools.length; i++) {
        var fn = tools[i].function || {};
        var params = sanitizeGeminiSchema(fn.parameters)
                     || { type: "object", properties: {} };
        if (!params.type) params.type = "object";
        decls.push({
            name: fn.name,
            description: fn.description || "",
            parameters: params
        });
    }
    return [{ functionDeclarations: decls }];
}

// Build { cmd, body } for a streaming chat request on the instance's
// wire format. opts: {sessionKey, model, messages, systemPrompt,
// temperature (number|null), maxTokens (0 = default), numCtx
// (0 = omit; ollama only), timeoutSeconds, envLookup?, tools?,
// rawMessages?}. Null when base/model unusable.
function buildChatRequest(instance, opts) {
    opts = opts || {};
    var base = normalizeBaseUrl(instance && instance.baseUrl);
    var model = (opts.model || "").trim();
    if (!base || !model) return null;

    var format = formatOf(instance);
    var payload = opts.rawMessages
        ? { system: (opts.systemPrompt || "").trim(), messages: opts.messages || [] }
        : buildApiPayload(instance, opts);
    if (opts.tools && opts.tools.length > 0) payload.tools = opts.tools;
    var key = resolveInstanceKey(instance, opts.sessionKey, opts.envLookup || noEnv);

    var url;
    var body;
    var i;
    if (format === "anthropic") {
        url = stripVersion(base, false) + "/v1/messages";
        // max_tokens is required by the Anthropic API — default 4096.
        // Tool rounds carry tool/tool_use messages that map to
        // user tool_result blocks and assistant tool_use blocks.
        var amsgs = [];
        for (i = 0; i < payload.messages.length; i++) {
            var tm = payload.messages[i];
            if (tm.role === "tool") {
                amsgs.push({ role: "user", content: [{
                    type: "tool_result",
                    tool_use_id: tm.tool_call_id || "",
                    content: tm.content || ""
                }] });
            } else if (tm.tool_calls && tm.tool_calls.length > 0) {
                var blocks = [];
                if (tm.content && tm.content.length > 0)
                    blocks.push({ type: "text", text: tm.content });
                for (var t = 0; t < tm.tool_calls.length; t++) {
                    var tfn = tm.tool_calls[t].function || {};
                    blocks.push({
                        type: "tool_use",
                        id: tm.tool_calls[t].id || "",
                        name: tfn.name || "",
                        input: parseToolArgs(tfn.arguments)
                    });
                }
                amsgs.push({ role: "assistant", content: blocks });
            } else if (tm.role === "user"
                       && sanitizeImages(tm.images).length > 0) {
                amsgs.push({ role: "user",
                             content: anthropicContent(
                                 sanitizeImages(tm.images), tm.content) });
            } else {
                amsgs.push({ role: tm.role === "assistant" ? "assistant" : "user",
                             content: tm.content });
            }
        }
        body = { model: model,
                 max_tokens: opts.maxTokens > 0 ? opts.maxTokens : 4096,
                 messages: amsgs, stream: true };
        if (typeof opts.temperature === "number") body.temperature = opts.temperature;
        if (payload.system) body.system = payload.system;
        if (payload.tools && payload.tools.length > 0)
            body.tools = toolsForAnthropic(payload.tools);
    } else if (format === "gemini") {
        url = stripVersion(base, true) + "/v1beta/models/" + model + ":streamGenerateContent?alt=sse";
        var contents = [];
        for (i = 0; i < payload.messages.length; i++) {
            var gm = payload.messages[i];
            var parts = [];
            if (gm.role === "assistant" && gm.tool_calls && gm.tool_calls.length > 0) {
                for (var g = 0; g < gm.tool_calls.length; g++) {
                    var gfn = gm.tool_calls[g].function || {};
                    var part = {
                        functionCall: {
                            name: gfn.name || "",
                            args: parseToolArgs(gfn.arguments)
                        }
                    };
                    if (g === 0) {
                        var raw = gm.tool_calls[g].thoughtSignature;
                        var sig = (typeof raw === "string" && raw.length > 0)
                            ? raw
                            : "skip_thought_signature_validator";
                        part.thoughtSignature = sig;
                    }
                    parts.push(part);
                }
                contents.push({ role: "model", parts: parts });
            } else if (gm.role === "tool") {
                parts.push({ functionResponse: {
                    name: gm.name || "",
                    response: { result: gm.content || "" }
                } });
                contents.push({ role: "user", parts: parts });
            } else if (gm.role === "user"
                       && sanitizeImages(gm.images).length > 0) {
                parts = geminiParts(sanitizeImages(gm.images), gm.content);
                contents.push({ role: "user", parts: parts });
            } else {
                parts.push({ text: gm.content });
                contents.push({ role: gm.role === "assistant" ? "model" : "user",
                                parts: parts });
            }
        }
        var gen = {};
        if (typeof opts.temperature === "number") gen.temperature = opts.temperature;
        if (opts.maxTokens > 0) gen.maxOutputTokens = opts.maxTokens;
        body = { contents: contents, generationConfig: gen };
        if (payload.system)
            body.systemInstruction = { parts: [{ text: payload.system }] };
        if (payload.tools && payload.tools.length > 0)
            body.tools = toolsForGemini(payload.tools);
    } else if (format === "ollama") {
        // Native /api/chat — the only Ollama endpoint honoring
        // options.num_ctx (/v1 pins the default context).
        url = stripVersion(base, false) + "/api/chat";
        var omsgs = [];
        if (payload.system) omsgs.push({ role: "system", content: payload.system });
        for (i = 0; i < payload.messages.length; i++) {
            var nm = payload.messages[i];
            if (nm.role === "assistant" && nm.tool_calls
                    && nm.tool_calls.length > 0) {
                var ocalls = [];
                for (var oc = 0; oc < nm.tool_calls.length; oc++) {
                    var nfn = nm.tool_calls[oc].function || {};
                    ocalls.push({ function: {
                        name: nfn.name || "",
                        arguments: parseToolArgs(nfn.arguments)
                    } });
                }
                omsgs.push({ role: "assistant", content: nm.content || "",
                             tool_calls: ocalls });
            } else if (nm.role === "tool") {
                // Results ride as plain tool messages in call order —
                // ollama matches them by order, not by id.
                omsgs.push({ role: "tool", content: nm.content || "" });
            } else if (nm.role === "user"
                       && sanitizeImages(nm.images).length > 0) {
                omsgs.push({ role: "user", content: nm.content || "",
                             images: imagesForOllama(sanitizeImages(nm.images)) });
            } else {
                omsgs.push({ role: nm.role === "assistant" ? "assistant" : "user",
                             content: nm.content });
            }
        }
        body = { model: model, messages: omsgs, stream: true };
        var oopts = {};
        if (opts.numCtx > 0) oopts.num_ctx = opts.numCtx;
        if (typeof opts.temperature === "number")
            oopts.temperature = opts.temperature;
        if (opts.maxTokens > 0) oopts.num_predict = opts.maxTokens;
        if (Object.keys(oopts).length > 0) body.options = oopts;
        if (payload.tools && payload.tools.length > 0) body.tools = payload.tools;
    } else {
        url = chatUrl(base);
        var msgs = [];
        if (payload.system) msgs.push({ role: "system", content: payload.system });
        // User turns with images become multipart content arrays; the
        // neutral `images` key itself never rides into the wire body.
        for (i = 0; i < payload.messages.length; i++) {
            var om = payload.messages[i];
            var oi = om.role === "user" ? sanitizeImages(om.images) : [];
            if (oi.length > 0)
                msgs.push({ role: "user",
                            content: openaiImageParts(oi, om.content) });
            else
                msgs.push(om);
        }
        body = { model: model, messages: messagesForOpenai(msgs), stream: true,
                 stream_options: { include_usage: true } };
        if (typeof opts.temperature === "number") body.temperature = opts.temperature;
        if (opts.maxTokens > 0) body.max_tokens = opts.maxTokens;
        // No options block on openai: /v1 pins context to the server
        // default no matter what is sent — see the ollama branch.
        if (payload.tools && payload.tools.length > 0) body.tools = payload.tools;
    }

    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "POST"\n';
    config += 'header = "Content-Type: application/json"\n';
    config += 'header = "Accept: application/json"\n';

    if (format === "anthropic") {
        config += 'header = "anthropic-version: 2023-06-01"\n';
        if (key) config += 'header = "x-api-key: ' + escapeCurlConfig(key) + '"\n';
    } else if (format === "gemini") {
        if (key) config += 'header = "x-goog-api-key: ' + escapeCurlConfig(key) + '"\n';
    } else if (key) {
        config += 'header = "Authorization: Bearer ' + escapeCurlConfig(key) + '"\n';
    }

    config += 'data = "' + escapeCurlConfig(JSON.stringify(body)) + '"\n';
    return { cmd: curlCmd(opts.timeoutSeconds), body: config };
}

// Build { cmd, body } for GET <models endpoint>. Null when base invalid.
function buildModelsRequest(instance, sessionKey) {
    var base = normalizeBaseUrl(instance && instance.baseUrl);
    if (!base) return null;
    var format = formatOf(instance);
    var key = sanitizeApiKey(sessionKey || "");

    var url;
    if (format === "anthropic") url = stripVersion(base, false) + "/v1/models";
    else if (format === "gemini") url = stripVersion(base, true) + "/v1beta/models";
    else url = endsWithVersion(base) ? base + "/models" : base + "/v1/models";

    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "GET"\n';

    if (format === "anthropic") {
        config += 'header = "anthropic-version: 2023-06-01"\n';
        if (key) config += 'header = "x-api-key: ' + escapeCurlConfig(key) + '"\n';
    } else if (format === "gemini") {
        if (key) config += 'header = "x-goog-api-key: ' + escapeCurlConfig(key) + '"\n';
    } else if (key) {
        config += 'header = "Authorization: Bearer ' + escapeCurlConfig(key) + '"\n';
    }

    return { cmd: curlCmd(30), body: config };
}

// models.dev registry snapshot — NexusService slims + caches it.
function buildRegistryRequest(timeoutSeconds) {
    var url = "https://models.dev/api.json";
    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "GET"\n';
    return { cmd: curlCmd(timeoutSeconds), body: config };
}

// Ollama loaded-model probe; models[].context_length is the real
// loaded context (server default without num_ctx). Empty list when
// the model isn't loaded.
function buildOllamaPsRequest(instance, timeoutSeconds) {
    var base = normalizeBaseUrl(instance && instance.baseUrl);
    if (!base) return null;
    var url = stripVersion(base, false) + "/api/ps";
    var config = 'url = "' + escapeCurlConfig(url) + '"\n';
    config += 'request = "GET"\n';
    return { cmd: curlCmd(timeoutSeconds), body: config };
}

// Parse a model list per wire format → sorted, deduped [{ id, label }].
// openai: {data:[{id}]}; anthropic: {data:[{id, display_name}]};
// gemini: {models:[{name: "models/x", displayName}]} — the leading
// "models/" is stripped from ids. Bad/absent shapes → [].
function parseModelList(json, format) {
    var fmt = format || "openai";
    var out = [];
    try {
        var obj = JSON.parse(json);
        var arr = fmt === "gemini" ? (obj && obj.models) : (obj && obj.data);
        if (!Array.isArray(arr)) return [];
        var seen = {};
        for (var i = 0; i < arr.length; i++) {
            var e = arr[i];
            if (!e) continue;
            var id;
            var label;
            if (fmt === "gemini") {
                if (typeof e.name !== "string" || e.name.length === 0) continue;
                id = e.name.replace(/^models\//, "");
                if (!id) continue;
                label = (typeof e.displayName === "string" && e.displayName) || id;
            } else {
                if (typeof e.id !== "string" || e.id.length === 0) continue;
                id = e.id;
                label = (fmt === "anthropic" &&
                         typeof e.display_name === "string" && e.display_name) || id;
            }
            if (seen[id]) continue;
            seen[id] = true;
            out.push({ id: id, label: label });
        }
    } catch (err) { return []; }
    out.sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
    return out;
}

// Drop per-instance model state for models the provider no longer
// serves (ghost picker entries). Pure: returns {removed,
// checkedModels, labels}. extraIds (pins) widen the stale scan;
// customModels are never pruned.
function pruneStaleModels(inst, discovered, extraIds) {
    if (!inst) return { removed: [], checkedModels: [], labels: {} };
    var avail = {};
    var disc = Array.isArray(discovered) ? discovered : [];
    for (var i = 0; i < disc.length; i++)
        if (disc[i] && typeof disc[i].id === "string" && disc[i].id)
            avail[disc[i].id] = true;
    var custom = Array.isArray(inst.customModels) ? inst.customModels : [];
    for (var c = 0; c < custom.length; c++)
        if (typeof custom[c] === "string" && custom[c]) avail[custom[c]] = true;

    var known = {};
    var checked = Array.isArray(inst.checkedModels) ? inst.checkedModels : [];
    for (var k = 0; k < checked.length; k++)
        if (typeof checked[k] === "string" && checked[k]) known[checked[k]] = true;
    var labelsIn = inst.modelLabels || {};
    for (var lk in labelsIn) known[lk] = true;
    if (Array.isArray(extraIds))
        for (var e = 0; e < extraIds.length; e++)
            if (typeof extraIds[e] === "string" && extraIds[e]) known[extraIds[e]] = true;

    var removed = [];
    for (var kid in known) if (!avail[kid]) removed.push(kid);

    var kept = [];
    for (var j = 0; j < checked.length; j++)
        if (typeof checked[j] === "string" && avail[checked[j]]) kept.push(checked[j]);
    var labels = {};
    for (var mk in labelsIn) if (avail[mk]) labels[mk] = labelsIn[mk];

    return { removed: removed, checkedModels: kept, labels: labels };
}
