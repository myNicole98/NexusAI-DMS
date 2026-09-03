.pragma library

// Brand icon resolution: returns a bare file stem; BrandIcon resolves
// it against resources/icons/<theme>/<stem>.svg, falling back to
// resources/icons/models/<stem>.svg (nothing when absent).

// Fixed model-icon bindings for brand providers: every model shows
// this brand, no regex consulted. Deliberately distinct from
// providerIcon — Google's models use the Gemini spark while the
// provider row shows the G logo.
var PROVIDER_MODEL_ICON = {
    openai: "openai",
    google: "gemini",
    claude: "claude",
    groq: "groq",
    deepseek: "deepseek",
    moonshot: "kimi",
    zai: "zai"
};

// Provider type → logo file stem, only where it differs from the
// type (Anthropic's logo file is anthropic).
var PROVIDER_FILE = { claude: "anthropic" };

function providerIcon(type) {
    var t = String(type || "");
    if (!t) return "";
    return PROVIDER_FILE[t] || t;
}

// Regex rules over the model id, first match wins. Used for
// multi-brand runtimes (ollama, lmstudio, custom) whose own logo
// says nothing about the individual model. Extend by dropping a
// { pattern: /.../i, icon: "<stem>" } entry plus the svg.
var RULES = [
    { pattern: /glm/i, icon: "zai" },
    { pattern: /qwen/i, icon: "qwen" },
    { pattern: /gemini/i, icon: "gemini" },
    { pattern: /gemma/i, icon: "gemma" },
    { pattern: /claude/i, icon: "claude" },
    { pattern: /deepseek/i, icon: "deepseek" },
    { pattern: /kimi|moonshot/i, icon: "kimi" },
    { pattern: /mistral|magistral|devstral|codestral|ministral|pixtral/i, icon: "mistral" },
    { pattern: /gpt|chatgpt/i, icon: "openai" }
];

function iconForModel(modelId, providerType) {
    var type = String(providerType || "");
    // Fixed brand: always the bound stem, no regex.
    if (PROVIDER_MODEL_ICON[type]) return PROVIDER_MODEL_ICON[type];
    var id = String(modelId || "");
    // Folder-driven rules: every resources/icons/models/<stem>.svg auto-
    // binds /<stem>/i (longest first). Dropping a file into the
    // folder is enough to theme its models.
    for (var a = 0; a < AUTO_RULES.length; a++)
        if (AUTO_RULES[a].pattern.test(id)) return AUTO_RULES[a].icon;
    for (var i = 0; i < RULES.length; i++)
        if (RULES[i].pattern.test(id)) return RULES[i].icon;
    // No rule matched: the runtime's own logo.
    return type;
}

// Auto rules built from the models folder at startup (longest stem
// first, "generic" excluded — it is the no-icon fallback).
var AUTO_RULES = [];

function setAutoIcons(stems) {
    var list = [];
    for (var i = 0; i < stems.length; i++) {
        var s = String(stems[i] || "").trim();
        if (!s || s === "generic") continue;
        list.push(s);
    }
    list.sort(function (a, b) { return b.length - a.length; });
    AUTO_RULES = [];
    for (i = 0; i < list.length; i++)
        AUTO_RULES.push({ pattern: new RegExp(list[i], "i"), icon: list[i] });
}
