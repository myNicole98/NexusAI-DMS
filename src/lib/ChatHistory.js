.pragma library

var FALLBACK_MAX = 40;
var TITLE_MAX = 60;

function normalizeStore(raw) {
    var out = [];
    try {
        var arr = JSON.parse(String(raw == null ? "[]" : raw));
        if (!Array.isArray(arr)) return [];
        for (var i = 0; i < arr.length; i++) {
            var c = arr[i];
            if (!c || typeof c.id !== "string" || c.id.length === 0) continue;
            if (!Array.isArray(c.messages)) continue;
            out.push({
                id: c.id,
                title: typeof c.title === "string" ? c.title : "",
                createdAt: typeof c.createdAt === "number" ? c.createdAt : 0,
                updatedAt: typeof c.updatedAt === "number" ? c.updatedAt : 0,
                messages: c.messages
            });
        }
    } catch (e) { return []; }
    return out;
}

function stripAttachments(raw) {
    var arr;
    try { arr = JSON.parse(String(raw || "[]")); } catch (e) { return "[]"; }
    if (!Array.isArray(arr)) return "[]";
    var out = [];
    for (var i = 0; i < arr.length; i++) {
        var a = arr[i];
        if (!a) continue;
        out.push({ mime: String(a.mime || "image/png"), stripped: true });
    }
    return JSON.stringify(out);
}

function sanitizeForPersist(chat) {
    if (!chat) return null;
    var src = Array.isArray(chat.messages) ? chat.messages : [];
    var msgs = [];
    for (var i = 0; i < src.length; i++) {
        var m = src[i];
        if (!m) continue;
        var row = {
            id: m.id, role: m.role, content: m.content || "",
            thinking: m.thinking || "",
            toolLog: m.toolLog || "[]",
            attachments: m.attachments || "[]",
            usage: m.usage || "",
            modelUsed: m.modelUsed || "",
            modelProviderId: m.modelProviderId || "",
            state: m.state === "streaming" ? "cancelled" : (m.state || "done"),
            stats: m.stats || "",
            timestamp: typeof m.timestamp === "number" ? m.timestamp : 0
        };
        if (m.role === "user") row.attachments = stripAttachments(m.attachments);
        msgs.push(row);
    }
    return {
        id: String(chat.id || ""),
        title: String(chat.title || ""),
        createdAt: chat.createdAt || 0,
        updatedAt: chat.updatedAt || 0,
        messages: msgs
    };
}

function capWithEllipsis(s, max) {
    return s.length > max ? s.substring(0, max - 1) + "…" : s;
}

// Fallback title
function fallbackTitle(text) {
    var s = String(text == null ? "" : text);
    var lines = s.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\s+/g, " ").trim();
        if (line.length > 0) return capWithEllipsis(line, FALLBACK_MAX);
    }
    return "";
}

// Title sanitize
function cleanTitle(raw) {
    var s = String(raw == null ? "" : raw).trim();
    s = s.replace(/^[\u201C\u201D"'`]+/, "")
         .replace(/[\u201C\u201D"'`]+$/, "");
    s = s.replace(/\s+/g, " ").trim();
    s = s.replace(/[.!?…]+$/, "").trim();
    if (!s) return "";
    return capWithEllipsis(s, TITLE_MAX);
}

// Title request
function titlePrompt(userText, assistantText) {
    var u = String(userText == null ? "" : userText).substring(0, 2000).trim();
    var a = String(assistantText == null ? "" : assistantText).substring(0, 1000).trim();
    return "Generate a short title (3-6 words) that summarizes this "
        + "conversation. Reply with the title text only - no quotes, "
        + "no trailing punctuation, no explanation.\n\n"
        + "User: " + u + "\n\nAssistant: " + a;
}
