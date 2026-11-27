.pragma library

// Groups an assistant turn's response flow into what the chat renders: one
// activity block per working phase, plus the answer's text segments in
// order. A "working phase" is a run of thinking, tool and narration entries
// with no answer text between them — the moment the model speaks, the run
// ends and the next phase opens its own row.
//
// Pure JS so the grouping and the label vocabulary are unit-tested. Tool
// labels arrive through `labelOf` (NativeToolMeta.label at the call site):
// libs in this repo never import each other.

var THINKING_LABEL = "Thinking…";
var BRIEF_LABEL = "Pondered briefly";

function _str(s) {
    return typeof s === "string" ? s : "";
}

// A c entry becomes a chip item enriched from its tool-log row. Missing or
// malformed rows yield empty identity rather than throwing — a half-written
// draft entry is still a row the user can see.
function _chipItem(entry, toolLog, labelOf, live) {
    var row = (toolLog && entry && typeof entry.i === "number")
        ? toolLog[entry.i] : null;
    var name = row ? _str(row.name) : "";
    var ms = (row && row.startMs && row.endMs)
        ? Math.max(0, row.endMs - row.startMs) : 0;
    var item = {
        t: "c",
        i: entry ? entry.i : -1,
        name: name,
        label: name ? labelOf(name) : "",
        state: row ? _str(row.state) : "",
        draft: !!(row && row.draft === true),
        ms: ms
    };
    if (live) item.live = true;
    return item;
}

// Plain entries (k / n) keep their offsets; the strings they index into are
// the message's own `thinking` / `narration`.
function _stepItem(entry, live) {
    var item = { t: entry.t, a: entry.a, b: entry.b };
    if (entry.t === "k") item.ms = entry.ms || 0;
    if (live) item.live = true;
    return item;
}

function group(flow, toolLog, liveIndex, labelOf) {
    var src = Array.isArray(flow) ? flow : [];
    var label = typeof labelOf === "function" ? labelOf : _str;
    var live = typeof liveIndex === "number" ? liveIndex : -1;
    var out = [];
    var block = null;

    function closeBlock() {
        if (!block) return;
        var calls = 0;
        for (var j = 0; j < block.items.length; j++) {
            if (block.items[j].t === "c" && block.items[j].draft !== true) calls++;
        }
        block.calls = calls;
        out.push(block);
        block = null;
    }

    for (var i = 0; i < src.length; i++) {
        var e = src[i];
        if (!e) continue;
        if (e.t === "x") {
            closeBlock();
            var seg = { t: "x", a: e.a, b: e.b, live: i === live };
            out.push(seg);
            continue;
        }
        if (e.t !== "k" && e.t !== "c" && e.t !== "n") continue;
        if (!block) {
            block = { t: "act", srcIdx: i, items: [], calls: 0, live: false };
        }
        var isLive = i === live;
        if (isLive) block.live = true;
        block.items.push(e.t === "c" ? _chipItem(e, toolLog, label, isLive)
            : _stepItem(e, isLive));
    }
    closeBlock();
    return out;
}

// The model's own status line: the newest narration entry inside the block
// that has actually finished (b > a, and not the line still streaming), so
// the label only advances on whole lines. Collapsed to one line.
function narrationLabel(block, narration) {
    if (!block || !block.items) return "";
    var text = _str(narration);
    var best = null;
    for (var i = 0; i < block.items.length; i++) {
        var it = block.items[i];
        if (it.t !== "n" || it.live === true) continue;
        if (typeof it.a !== "number" || typeof it.b !== "number") continue;
        if (it.b <= it.a) continue;
        best = it;
    }
    if (!best) return "";
    var line = text.substring(best.a, Math.min(best.b, text.length));
    return line.replace(/[\r\n]+/g, " ").trim();
}

// Fallback when the model never narrated: what it is doing, from the steps
// themselves. Tool identity first, then the pondering vocabulary the
// thinking box already uses.
function deriveLabel(block, live) {
    if (!block || !block.items) return "";
    var tool = null;
    var ms = 0, pondered = false;
    for (var i = 0; i < block.items.length; i++) {
        var it = block.items[i];
        if (it.t === "c") {
            if (it.label && (tool === null || it.draft !== true)) tool = it;
        } else if (it.t === "k") {
            pondered = true;
            ms += it.ms || 0;
        }
    }
    if (tool) return tool.label + (live ? "…" : "");
    if (live || !pondered) return live ? THINKING_LABEL : "";
    return ms < 5000 ? BRIEF_LABEL
        : "Pondered for " + Math.round(ms / 1000) + " seconds";
}

// The quiet count on the right of the row. Elapsed time is deliberately not
// here: a collapsed line carries what happened, not how long it took.
function metaLabel(block) {
    if (!block) return "";
    var calls = block.calls || 0;
    if (calls === 0) return "";
    return " · " + calls + (calls === 1 ? " call" : " calls");
}
