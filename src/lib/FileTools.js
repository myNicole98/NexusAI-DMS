.pragma library

// Native file tools (`read_file`, `write_file`, `edit_file`): validation,
// path resolution, exact-text editing, diffing and result formatting.
//
// Pure JS — every decision is unit-tested; NativeToolsService.qml is
// transport (argv processes, approval hold). Never log with nested
// parens — the test harness strips console.* naively.

// A read is whole-file, so refuse anything large before touching it.
var MAX_FILE_BYTES = 4 * 1024 * 1024;
var MAX_READ_LINES = 400;
var MAX_READ_CHARS = 24000;
var MAX_LIMIT = 5000;
// The edit result echoes its hunk, never the whole replaced block.
var MAX_HUNK_LINES = 40;
var MAX_HUNK_CHARS = 6000;

var READ = "read_file";
var WRITE = "write_file";
var EDIT = "edit_file";

function isNativeTool(name) {
    return name === READ || name === WRITE || name === EDIT;
}

function toolDefs(enabledNames) {
    var all = [
        {
            type: "function",
            function: {
                name: READ,
                description: "Read a text file with line numbers. Use it " +
                    "before editing so the old text you send matches " +
                    "exactly. Long files page: the result says which offset " +
                    "to continue from. Prefer absolute paths.",
                parameters: {
                    type: "object",
                    properties: {
                        path: { type: "string",
                                description: "File path (~ and absolute " +
                                    "paths; relative resolves to home)" },
                        offset: { type: "integer",
                                  description: "1-based first line (default 1)" },
                        limit: { type: "integer",
                                 description: "Max lines to return (default " +
                                     MAX_READ_LINES + ")" }
                    },
                    required: ["path"]
                }
            }
        },
        {
            type: "function",
            function: {
                name: WRITE,
                description: "Create or overwrite a text file with the given " +
                    "content. Parent directories are not created. For small " +
                    "changes to an existing file use edit_file instead.",
                parameters: {
                    type: "object",
                    properties: {
                        path: { type: "string", description: "File path" },
                        content: { type: "string",
                                   description: "Full file content (empty " +
                                       "string truncates the file)" }
                    },
                    required: ["path", "content"]
                }
            }
        },
        {
            type: "function",
            function: {
                name: EDIT,
                description: "Replace exact text in a file. Send only the " +
                    "piece that changes: old_string must match the file " +
                    "byte for byte and must be unique unless replace_all is " +
                    "true. Cheaper than rewriting the whole file.",
                parameters: {
                    type: "object",
                    properties: {
                        path: { type: "string", description: "File path" },
                        old_string: { type: "string",
                                      description: "Exact text to replace" },
                        new_string: { type: "string",
                                      description: "Replacement text (empty " +
                                          "string deletes it)" },
                        replace_all: { type: "boolean",
                                       description: "Replace every " +
                                           "occurrence (default false)" }
                    },
                    required: ["path", "old_string", "new_string"]
                }
            }
        }
    ];
    if (!enabledNames) return all;
    return all.filter(function (d) {
        return enabledNames.indexOf(d.function.name) >= 0;
    });
}

// ── Arguments ─────────────────────────────────────────────────────

function _path(args) {
    var p = typeof args.path === "string" ? args.path.trim() : "";
    return p;
}

function _int(value, fallback, min, max) {
    var n = value;
    if (typeof n === "string" && n.trim() !== "" && isFinite(parseInt(n, 10)))
        n = parseInt(n, 10);
    if (typeof n !== "number" || !isFinite(n)) return fallback;
    n = Math.floor(n);
    if (n < min) return min;
    if (n > max) return max;
    return n;
}

function validateArgs(name, args) {
    args = args || {};
    var path = _path(args);
    if (!path) return { ok: false, error: "Missing required argument: path" };

    if (name === READ) {
        return { ok: true, args: {
            path: path,
            offset: _int(args.offset, 1, 1, 1000000),
            limit: _int(args.limit, MAX_READ_LINES, 1, MAX_LIMIT)
        } };
    }
    if (name === WRITE) {
        if (typeof args.content !== "string")
            return { ok: false, error: "Missing required argument: content" };
        return { ok: true, args: { path: path, content: args.content } };
    }
    if (name === EDIT) {
        if (typeof args.old_string !== "string" || args.old_string.length === 0)
            return { ok: false, error: "Missing required argument: old_string" };
        if (typeof args.new_string !== "string")
            return { ok: false, error: "Missing required argument: new_string" };
        if (args.old_string === args.new_string)
            return { ok: false, error: "No-op edit: old_string and " +
                                       "new_string are identical" };
        return { ok: true, args: {
            path: path,
            oldString: args.old_string,
            newString: args.new_string,
            replaceAll: args.replace_all === true
        } };
    }
    return { ok: false, error: "Unknown file tool: " + String(name) };
}

// ── Paths ─────────────────────────────────────────────────────────

// Lexical only: ~ expansion, relative against home, . and .. collapse.
function resolvePath(raw, home) {
    var s = String(raw || "").trim();
    if (s === "~") s = String(home || "");
    else if (s.indexOf("~/") === 0) s = String(home || "") + s.substring(1);
    if (s.charAt(0) !== "/") {
        var base = String(home || "");
        s = base ? base + "/" + s : s;
    }
    var parts = s.split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var seg = parts[i];
        if (seg === "" || seg === ".") continue;
        if (seg === "..") {
            if (out.length > 0) out.pop();
            continue;
        }
        out.push(seg);
    }
    return "/" + out.join("/");
}

// ── Content guards ────────────────────────────────────────────────

function looksBinary(text) {
    return String(text || "").indexOf("\u0000") >= 0;
}

// U+FFFD after decoding means the bytes were not valid UTF-8; writing the
// string back would mangle every non-ASCII byte.
function isLossyText(text) {
    return String(text || "").indexOf("\uFFFD") >= 0;
}

function countLines(text) {
    var s = String(text || "");
    if (s.length === 0) return 0;
    var n = 1;
    for (var i = 0; i < s.length; i++)
        if (s.charAt(i) === "\n") n++;
    if (s.charAt(s.length - 1) === "\n") n--;
    return n;
}

// ── Editing ───────────────────────────────────────────────────────

// Exact substring replacement. No regex (so no escaping traps) and no
// looping over the replaced text (an occurrence is found with indexOf on
// the untouched remainder).
function applyEdit(content, oldStr, newStr, replaceAll) {
    var text = String(content || "");
    var old = String(oldStr === undefined || oldStr === null ? "" : oldStr);
    var repl = String(newStr === undefined || newStr === null ? "" : newStr);
    if (old.length === 0)
        return { ok: false, error: "old_string is empty" };

    var first = text.indexOf(old);
    if (first < 0) return { ok: false, error: "old_string not found" };

    var count = 0;
    var idx = first;
    while (idx >= 0) {
        count++;
        idx = text.indexOf(old, idx + old.length);
    }
    if (count > 1 && replaceAll !== true) {
        return { ok: false, error: "old_string appears " + count
                 + " times — add surrounding context or set replace_all" };
    }

    var out;
    if (replaceAll === true) {
        out = "";
        var pos = 0;
        while (true) {
            var hit = text.indexOf(old, pos);
            if (hit < 0) { out += text.substring(pos); break; }
            out += text.substring(pos, hit) + repl;
            pos = hit + old.length;
        }
    } else {
        out = text.substring(0, first) + repl
            + text.substring(first + old.length);
    }
    return { ok: true, content: out, count: replaceAll === true ? count : 1 };
}

// ── Diff (for the approval card) ──────────────────────────────────

function _lines(text) {
    var s = String(text === undefined || text === null ? "" : text);
    if (s.length === 0) return [];
    var arr = s.split("\n");
    if (arr.length > 0 && arr[arr.length - 1] === "") arr.pop();
    return arr;
}

// Line diff for review: trim the common prefix/suffix, then show the
// changed middle as "-" lines followed by "+" lines, with `context`
// unchanged lines around it. Not an LCS — edits are replacements, so a
// delete-then-insert block is exactly what the user reads.
function unifiedDiff(oldText, newText, context) {
    var ctx = typeof context === "number" ? context : 3;
    var a = _lines(oldText);
    var b = _lines(newText);
    var pre = 0;
    while (pre < a.length && pre < b.length && a[pre] === b[pre]) pre++;
    var suf = 0;
    while (suf < a.length - pre && suf < b.length - pre
           && a[a.length - 1 - suf] === b[b.length - 1 - suf]) suf++;

    // Identical files: nothing to review.
    if (pre === a.length && pre === b.length)
        return { rows: [], removed: 0, added: 0 };

    var rows = [];
    var start = Math.max(0, pre - ctx);
    for (var i = start; i < pre; i++) rows.push({ t: " ", text: a[i] });
    for (var d = pre; d < a.length - suf; d++) rows.push({ t: "-", text: a[d] });
    for (var n = pre; n < b.length - suf; n++) rows.push({ t: "+", text: b[n] });
    var tailFrom = a.length - suf;
    var tailTo = Math.min(a.length, tailFrom + ctx);
    for (var t = tailFrom; t < tailTo; t++) rows.push({ t: " ", text: a[t] });

    return { rows: rows, removed: a.length - suf - pre,
             added: b.length - suf - pre };
}

// ── Results ───────────────────────────────────────────────────────

// Numbered lines from `offset`, bounded by lines AND characters. The
// resume offset is non-zero when anything was left out.
function formatRead(content, offset, limit) {
    var text = String(content || "");
    var all = _lines(text);
    var total = all.length;
    var start = Math.max(1, typeof offset === "number" ? offset : 1);
    var maxLines = typeof limit === "number" && limit > 0 ? limit : MAX_READ_LINES;

    var out = "";
    var rows = 0;
    var last = start - 1;
    for (var ln = start; ln <= total && rows < maxLines; ln++) {
        var line = ln + ": " + all[ln - 1];
        if (out.length + line.length + 1 > MAX_READ_CHARS) break;
        out += (out.length > 0 ? "\n" : "") + line;
        rows++;
        last = ln;
    }
    var resume = last < total ? last + 1 : 0;
    if (resume > 0)
        out += (out.length > 0 ? "\n" : "")
            + "[\u2026 truncated at line " + last + " of " + total
            + " \u2014 call read_file with offset=" + resume + " to continue]";
    return { text: out, rows: rows, totalLines: total, nextOffset: resume };
}

function formatWriteResult(path, content) {
    var lines = countLines(content);
    var bytes = String(content || "").length;
    return "Wrote " + lines + " line" + (lines === 1 ? "" : "s")
        + " (" + humanSize(bytes) + ") to " + path;
}

// Header + the capped hunk, so the model sees what landed without paying
// for the whole replaced block again.
function formatEditResult(path, count, oldLines, newLines, diff) {
    var head = "Applied " + count + " replacement" + (count === 1 ? "" : "s")
        + " in " + path + " (" + oldLines + " lines \u2192 " + newLines
        + " lines).";
    var rows = (diff && diff.rows) ? diff.rows : [];
    var shown = [];
    var budget = 0;
    for (var i = 0; i < rows.length; i++) {
        if (shown.length >= MAX_HUNK_LINES) break;
        var line = rows[i].t + " " + rows[i].text;
        if (budget + line.length > MAX_HUNK_CHARS) break;
        shown.push(line);
        budget += line.length + 1;
    }
    var body = "--- " + path + "\n+++ " + path + "\n";
    if (shown.length < rows.length)
        body += "\u2026 (" + (rows.length - shown.length)
              + " more diff lines)\n";
    body += shown.join("\n");
    return head + "\n\n" + body;
}

function humanSize(bytes) {
    var n = Math.max(0, Math.round(Number(bytes) || 0));
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / (1024 * 1024)).toFixed(1) + " MB";
}
