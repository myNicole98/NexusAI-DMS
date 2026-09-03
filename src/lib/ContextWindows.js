.pragma library

// Context windows from a models.dev snapshot + token formatting.
// Pure JS. NexusService fetches/slims/caches the snapshot; ollama is
// dynamic (num_ctx / /api/ps) and never registry-matched.

// Plugin registry type → models.dev provider key. Absent → no lookup.
var PROVIDER_KEYS = {
    openai: "openai",
    claude: "anthropic",
    google: "google",
    groq: "groq",
    deepseek: "deepseek",
    openrouter: "openrouter",
    perplexity: "perplexity",
    zai: "zai",
    moonshot: "moonshotai"
};

// Reduce a full models.dev snapshot to { key: { id: context } },
// keeping only models that actually declare limit.context. Bad JSON
// or malformed shapes degrade to {} — the meter then shows tokens
// without a window.

function slim(apiJson) {
    var out = {};
    var root = null;
    try { root = JSON.parse(apiJson); } catch (e) { return out; }
    if (!root || typeof root !== "object") return out;
    for (var key in root) {
        var prov = root[key];
        var models = prov && prov.models;
        if (!models || typeof models !== "object") continue;
        var entry = {};
        for (var id in models) {
            var limit = models[id] && models[id].limit;
            var ctx = limit && limit.context;
            if (typeof ctx === "number" && ctx > 0) entry[id] = ctx;
        }
        if (Object.keys(entry).length > 0) out[key] = entry;
    }
    return out;
}

// Drop one trailing "-segment" ("x-4-5-20250929" → "x-4-5"); suffix
// trimming never prefix-matches INTO longer keys.

function trimSegment(id) {
    var idx = id.lastIndexOf("-");
    return idx > 0 ? id.substring(0, idx) : "";
}

// Window for a model, or 0 when unknown. Exact id first, then
// progressively trimmed suffixes; exact entries always win over
// shorter bases.

function lookup(slimMap, providerType, modelId) {
    if (!slimMap || typeof slimMap !== "object") return 0;
    var key = PROVIDER_KEYS[providerType];
    if (!key) return 0;
    var models = slimMap[key];
    if (!models) return 0;
    var id = String(modelId || "").trim();
    if (!id) return 0;
    for (;;) {
        if (typeof models[id] === "number") return models[id];
        id = trimSegment(id);
        if (!id) return 0;
    }
}

// Human token counts: 0 → "0", 999 → "999", 8192 → "8.2k",
// 1000000 → "1M", 1183232 → "1.2M". Negative/non-numeric → "".

function formatTokens(n) {
    if (typeof n !== "number" || !isFinite(n) || n < 0) return "";
    if (n === 0) return "0";
    function trim1(v) {
        var s = v.toFixed(1);
        return s.charAt(s.length - 1) === "0" ? s.substring(0, s.length - 2) : s;
    }
    if (n >= 1e6) return trim1(n / 1e6) + "M";
    if (n >= 1e3) return trim1(n / 1e3) + "k";
    return String(Math.round(n));
}

// Context window from ollama /api/ps (the loaded runner's real
// context). Exact name match, then colon-less base; 0 when unknown.
function ollamaWindowFromPs(psJson, model) {
    var root = null;
    try { root = JSON.parse(psJson); } catch (e) { return 0; }
    var models = root && Array.isArray(root.models) ? root.models : [];
    var wanted = String(model || "").trim();
    if (!wanted) return 0;
    var base = wanted.split(":")[0];
    var exact = null;
    var loose = null;
    for (var i = 0; i < models.length; i++) {
        var m = models[i];
        if (!m) continue;
        var name = (typeof m.name === "string" && m.name)
                || (typeof m.model === "string" && m.model) || "";
        if (name === wanted) { exact = m; break; }
        if (!loose && base && name.split(":")[0] === base) loose = m;
    }
    var hit = exact || loose;
    return (hit && typeof hit.context_length === "number"
            && hit.context_length > 0) ? hit.context_length : 0;
}
