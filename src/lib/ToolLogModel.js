.pragma library

// Tool-call log bookkeeping for assistant message rows: one entry per
// call, running → ok | error. `draft` entries are the live "writing…"
// state of a call whose arguments are still streaming (openai/anthropic
// fragment them; gemini/ollama deliver calls complete, so they never
// draft). A dispatched call UPGRADES its own draft entry in place —
// never pushes a second row — which is what keeps a round with parallel
// different-name calls from showing a breathing "Writing…" ghost next
// to the real "Tool called" chip. Pure array logic so the upgrade rules
// stay node-tested; the QML service owns the ListModel row, the flow
// chips, and the flush ordering.

// The nearest undispatched draft for `name`, scanning back through the
// whole log. Dispatch is SERIAL (each call stamps its result before the
// next call phase arrives), so finished rows sit between a later call
// and its own ghost — the scan must not stop at them. The nearest match
// always belongs to the current round; a ghost from an earlier round is
// only ever adopted when this round has no draft for the name, which is
// strictly better than leaving that ghost breathing beside a duplicate.
function findDraft(log, name) {
    for (var i = log.length - 1; i >= 0; i--) {
        var e = log[i];
        if (e && e.draft === true && e.state === "running" && e.name === name)
            return i;
    }
    return -1;
}

// Phase "draft": merge into the open draft when the name continues
// (StreamingService only re-emits on a name/chars change), else open a
// new entry. Returns { chip, entry }: chip is the index of a NEW entry
// the flow must record a chip for, -1 when merged in place.
function applyDraft(log, name, chars, nowMs, thinkingAt) {
    var last = log.length > 0 ? log[log.length - 1] : null;
    if (last && last.draft === true && last.name === name) {
        last.chars = chars;
        return { chip: -1, entry: null };
    }
    var entry = { name: name, state: "running", draft: true, chars: chars,
                  detail: "", startMs: nowMs, endMs: 0,
                  thinkingAt: thinkingAt };
    log.push(entry);
    return { chip: log.length - 1, entry: entry };
}

// Phase "call": upgrade the draft the user watched being written, if it
// exists; otherwise (no-draft formats, or a name the stream never
// reported) add a fresh running entry. Returns { chip, entry } with
// chip = -1 when a draft was upgraded in place.
function applyCall(log, name, nowMs, thinkingAt) {
    var idx = findDraft(log, name);
    if (idx >= 0) {
        var d = log[idx];
        d.draft = false;
        d.chars = 0;
        d.startMs = nowMs;
        return { chip: -1, entry: d };
    }
    var entry = { name: name, state: "running", detail: "",
                  startMs: nowMs, endMs: 0, thinkingAt: thinkingAt };
    log.push(entry);
    return { chip: log.length - 1, entry: entry };
}

// Pretty-print JSON details for the UI log (the raw envelope stays
// JSON-parseable where it is valid); cap the stored text.
function formatDetail(text) {
    var t = String(text || "");
    try {
        var pj = JSON.parse(t);
        if (pj !== undefined && pj !== null)
            t = JSON.stringify(pj, null, 2);
    } catch (e) { /* not JSON — shown as-is */ }
    return t.length > 20000 ? t.substring(0, 20000) + "…" : t;
}

// Phase "result"/"error": stamp the most recent running entry with this
// name finished. Adds an entry when none is open (a result that raced
// past its dispatch). Clears any draft flag so the chip can never
// render a completed call as still "Writing…".
function applyResult(log, name, isError, detail, nowMs) {
    var idx = -1;
    for (var i = log.length - 1; i >= 0; i--)
        if (log[i] && log[i].state === "running" && log[i].name === name) {
            idx = i;
            break;
        }
    var entry = idx >= 0 ? JSON.parse(JSON.stringify(log[idx]))
                         : { name: name, state: "running", detail: "",
                             startMs: nowMs, endMs: 0 };
    entry.state = isError ? "error" : "ok";
    entry.draft = false;
    entry.endMs = nowMs;
    entry.detail = formatDetail(detail);
    if (idx >= 0) log[idx] = entry;
    else log.push(entry);
    return { entry: entry };
}

// Turn-ending cleanup: remove every undispatched draft (the provider
// dropped the call, or the stream died mid-argument). Returns
// { log, remap, changed } where remap[oldIndex] = newIndex, or -1 for
// dropped entries — feed `remap` to remapFlow so `{t:"c", i}` chips
// keep pointing at the right entry instead of shifting onto each other.
function dropDrafts(log) {
    var next = [];
    var remap = [];
    var changed = false;
    for (var i = 0; i < log.length; i++) {
        if (log[i] && log[i].draft === true) {
            changed = true;
            remap.push(-1);
            continue;
        }
        remap.push(next.length);
        next.push(log[i]);
    }
    return { log: next, remap: remap, changed: changed };
}

// Rewrite flow entries against a dropDrafts remap: chips whose entry was
// removed go away, chips past them shift down; k/x entries untouched.
function remapFlow(flow, remap) {
    var out = [];
    for (var i = 0; i < flow.length; i++) {
        var e = flow[i];
        if (!e) continue;
        if (e.t === "c") {
            var ni = remap[e.i];
            if (ni === undefined || ni < 0) continue;
            out.push({ t: "c", i: ni });
        } else out.push(e);
    }
    return out;
}
