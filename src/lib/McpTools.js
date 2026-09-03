.pragma library

// MCP tool-selection bookkeeping shared by connect + tools/list_changed.
// enabledTools is ALWAYS the complete positive list of enabled names —
// an empty list means "none enabled", never "all on". Since off-toggles
// are absent from the list, reconnects treat the PREVIOUS discovered set
// as "known" and only default-enable genuinely new tools.

// Merge an incoming tool list: previously enabled stay on, genuinely
// new tools default on. Returns {discovered, enabledTools}.
function mergeToolSelection(previousDiscovered, enabledTools, incomingTools) {
    var prev = Array.isArray(previousDiscovered) ? previousDiscovered : [];
    var en = Array.isArray(enabledTools) ? enabledTools : [];
    var incoming = Array.isArray(incomingTools) ? incomingTools : [];

    var known = {};
    for (var i = 0; i < prev.length; i++)
        if (prev[i] && prev[i].name !== undefined && prev[i].name !== null)
            known[String(prev[i].name)] = true;

    var discovered = [];
    var seen = {};
    var nextEnabled = [];
    var enabledSet = {};
    for (var e = 0; e < en.length; e++)
        enabledSet[String(en[e])] = true;

    for (var t = 0; t < incoming.length; t++) {
        var tool = incoming[t];
        if (!tool || tool.name === undefined || tool.name === null) continue;
        var name = String(tool.name);
        if (seen[name]) continue;
        seen[name] = true;
        discovered.push({
            name: name,
            description: tool.description ? String(tool.description) : "",
            inputSchema: tool.inputSchema || { type: "object", properties: {} }
        });
        // Enabled iff the user kept it on, or it was never known before.
        if (enabledSet[name] || !known[name]) nextEnabled.push(name);
    }

    return { discovered: discovered, enabledTools: nextEnabled };
}

// Normalize a persisted server record; legacy records (no v2 marker)
// expand an empty enabledTools to "all on" — v2+ keep it as "none".
function normalizeLoadedServer(rec) {
    if (!rec) return rec;
    if (rec.enabled === undefined) rec.enabled = true;
    if (!rec.url) rec.url = "";
    if (!rec.name) rec.name = "MCP Server";
    if (!Array.isArray(rec.discovered)) rec.discovered = [];
    if (!Array.isArray(rec.enabledTools)) rec.enabledTools = [];
    if (rec.toolSelectionV2 !== true
        && rec.enabledTools.length === 0 && rec.discovered.length > 0) {
        var all = [];
        for (var i = 0; i < rec.discovered.length; i++)
            if (rec.discovered[i] && rec.discovered[i].name)
                all.push(String(rec.discovered[i].name));
        rec.enabledTools = all;
    }
    return rec;
}
