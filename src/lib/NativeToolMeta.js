.pragma library

// Display identity for the native tools: the friendly name and glyph the
// chat shows instead of the raw wire name. MCP tools have no entry —
// they keep their raw name and the generic tool glyph.
//
// Pure JS so the mapping is unit-tested; the icons are Material Symbols
// names used by DankIcon.

var TOOLS = {
    "web_search": { label: "Web Search", icon: "travel_explore" },
    "webfetch": { label: "Web Fetch", icon: "download" },
    "take_screenshot": { label: "Screenshot", icon: "photo_camera" },
    "run_command": { label: "Shell", icon: "terminal" }
};

var FALLBACK_ICON = "handyman";

function isNative(name) {
    return Object.prototype.hasOwnProperty.call(TOOLS, String(name || ""));
}

// Friendly label, or the raw name for MCP tools.
function label(name) {
    var key = String(name || "");
    var meta = TOOLS[key];
    return meta ? meta.label : key;
}

// Glyph name for DankIcon.
function icon(name) {
    var key = String(name || "");
    var meta = TOOLS[key];
    return meta ? meta.icon : FALLBACK_ICON;
}
