.pragma library

// Native shell tool (`run_command`): permission policy + execution
// helpers. Pure JS — NativeToolsService.qml is transport only. Every
// decision about whether a command may run lives in `analyze`, so the
// tokenizer, allowlist, path scoping and result formatting are
// unit-tested without touching a shell.
//
// Never log with nested parens — the test harness strips console.*
// naively.

var DEFAULT_TIMEOUT = 30;
var MIN_TIMEOUT = 5;
var MAX_TIMEOUT = 120;
// Hard collector cap: hitting it kills the command (see killed "cap").
var MAX_OUTPUT_BYTES = 256 * 1024;
// Model-visible output: head + tail with a marker between them.
var MAX_MODEL_CHARS = 24000;
var MODEL_HEAD_CHARS = 16000;

// Commands that are read-only on their own. Deliberately small; every
// entry is a promise, and the per-command tables below are what keep
// that promise. `env`, `command`, `exec`, `xargs`, `nice`, `time`,
// `nohup`, `sed`, `awk`, `xxd`, `od`, `hexdump` are excluded on
// purpose: each is a documented bypass (see the design doc).
var BUILTIN_COMMANDS = [
    "pwd", "ls", "cat", "head", "tail", "wc", "grep", "rg", "find",
    "file", "stat", "du", "df", "free", "uname", "whoami", "id", "date",
    "echo", "printf", "which", "whereis", "type", "jq", "sort", "uniq",
    "cut", "tr", "diff", "cmp", "tree", "ps", "pgrep", "lsblk", "lsusb",
    "lscpu", "nproc", "uptime", "hostname", "realpath", "readlink",
    "basename", "dirname", "md5sum", "sha256sum", "git", "systemctl"
];

// Flags that write or execute. A hit demotes the whole command to
// "needs approval" — the word being read-only is not enough.
var WRITE_FLAGS = {
    "find": ["-exec", "-execdir", "-ok", "-okdir", "-delete",
             "-fprint", "-fprint0", "-fprintf", "-fls"],
    "sort": ["-o", "--output", "--compress-program"],
    "tree": ["-o"],
    "git": ["--output"]
};

// Words that are allowed only with a read-only subcommand.
var SUBCOMMANDS = {
    "git": ["status", "log", "diff", "show", "blame", "describe",
            "rev-parse", "ls-files", "shortlog"],
    "systemctl": ["status", "is-active", "is-enabled", "list-units", "show"]
};

// Flags whose value is data, not a path (so the value is not checked
// against the allowed folders). Unknown flags do NOT consume their
// value, so an unrecognized `-foo bar` treats `bar` as a path — the
// safe direction. `grep -f` is intentionally absent: its value is a
// file of patterns, i.e. a real read.
var FLAG_VALUES = {
    "find": ["-name", "-iname", "-path", "-ipath", "-type", "-maxdepth",
             "-mindepth", "-newer", "-size"],
    "head": ["-n", "-c"],
    "tail": ["-n", "-c"],
    "grep": ["-m", "-A", "-B", "-C", "-e", "--include", "--exclude"],
    "rg": ["-m", "-A", "-B", "-C", "-e", "-g", "-t", "--glob", "--type"],
    "du": ["-d", "--max-depth", "-B"],
    "sort": ["-k", "-t"],
    "cut": ["-d", "-f"],
    "stat": ["-c", "--format"],
    "tree": ["-L", "-P", "-I"],
    "diff": ["-U", "--unified"],
    "ls": ["--color", "--time-style", "-I", "-w"]
};

// Words whose first non-flag token is a pattern, not a path.
var PATTERN_WORDS = ["grep", "rg"];

function isNativeTool(name) {
    return name === "run_command";
}

function toolDefs(enabledNames) {
    var all = [{
        type: "function",
        function: {
            name: "run_command",
            description: "Run a shell command on the user's machine. " +
                "Read-only commands (ls, cat, grep, git status, …) may run " +
                "immediately when they stay inside folders the user has " +
                "allowed; anything else asks the user for permission first, " +
                "and a denial comes back as an error. Pass cwd to work in a " +
                "specific directory. Output is stdout+stderr with the exit " +
                "code. No stdin: interactive commands will not work.",
            parameters: {
                type: "object",
                properties: {
                    command: {
                        type: "string",
                        description: "The shell command to run"
                    },
                    cwd: {
                        type: "string",
                        description: "Absolute working directory. Defaults " +
                            "to the user's home directory."
                    },
                    timeout_seconds: {
                        type: "integer",
                        description: "Timeout in seconds (5-120, default 30)"
                    }
                },
                required: ["command"]
            }
        }
    }];
    if (!enabledNames) return all;
    return all.filter(function (d) {
        return enabledNames.indexOf(d.function.name) >= 0;
    });
}

function validateArgs(args) {
    args = args || {};
    var cmd = typeof args.command === "string" ? args.command.trim() : "";
    if (!cmd) return { ok: false, error: "Missing required argument: command" };
    var cwd = "";
    if (typeof args.cwd === "string" && args.cwd.trim() !== "") {
        cwd = args.cwd.trim();
        if (cwd.charAt(0) !== "/")
            return { ok: false, error: "cwd must be an absolute path" };
    }
    var t = DEFAULT_TIMEOUT;
    var raw = args.timeout_seconds;
    if (typeof raw === "string" && raw.trim() !== ""
        && isFinite(parseInt(raw, 10)))
        raw = parseInt(raw, 10);
    if (typeof raw === "number" && isFinite(raw)) t = Math.floor(raw);
    if (t < MIN_TIMEOUT) t = MIN_TIMEOUT;
    if (t > MAX_TIMEOUT) t = MAX_TIMEOUT;
    return { ok: true, args: { command: cmd, cwd: cwd, timeoutSeconds: t } };
}

// ── Tokenizing ────────────────────────────────────────────────────

// Quote-aware split on the command separators (|, ||, &&, ;). Quotes
// survive into the segments so tokenize() can see the grouping; a lone
// `&` is not a separator and stays in the segment (hasForbiddenMeta
// rejects it).
function splitSegments(command) {
    var s = String(command || "");
    var out = [];
    var cur = "";
    var quote = "";
    for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i);
        if (quote) {
            cur += ch;
            if (ch === quote) quote = "";
            continue;
        }
        if (ch === "'" || ch === '"') {
            quote = ch;
            cur += ch;
            continue;
        }
        if (ch === ";") {
            out.push(cur);
            cur = "";
            continue;
        }
        if (ch === "|") {
            if (s.charAt(i + 1) === "|") i++;
            out.push(cur);
            cur = "";
            continue;
        }
        if (ch === "&" && s.charAt(i + 1) === "&") {
            i++;
            out.push(cur);
            cur = "";
            continue;
        }
        cur += ch;
    }
    out.push(cur);
    var cleaned = [];
    for (var j = 0; j < out.length; j++) {
        var t = out[j].trim();
        if (t) cleaned.push(t);
    }
    return cleaned;
}

// Same splitter, keeping the quoted text but dropping the quote marks —
// what the policy checks need to see.
function tokenize(segment) {
    var s = String(segment || "");
    var out = [];
    var cur = "";
    var quote = "";
    var has = false;
    for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i);
        if (quote) {
            if (ch === quote) { quote = ""; continue; }
            cur += ch;
            has = true;
            continue;
        }
        if (ch === "'" || ch === '"') { quote = ch; has = true; continue; }
        if (ch === " " || ch === "\t") {
            if (has) { out.push(cur); cur = ""; has = false; }
            continue;
        }
        cur += ch;
        has = true;
    }
    if (has) out.push(cur);
    return out;
}

// Everything the fast path refuses to reason about. A single `&`
// backgrounds; `&&` is a separator and is removed first. Globs are
// allowed (they only widen a read).
function hasForbiddenMeta(command) {
    var s = String(command || "");
    if (/[$`><(){}\\\n\r]/.test(s)) return true;
    return s.replace(/&&/g, "").indexOf("&") >= 0;
}

// ── Paths ─────────────────────────────────────────────────────────

// " FULL " style cleanups are unnecessary here: callers pass tokens.
function normalizePath(raw, cwd, home) {
    var s = String(raw || "").trim();
    var first = s.charAt(0);
    var last = s.charAt(s.length - 1);
    if (s.length > 1 && (first === "'" || first === '"') && last === first)
        s = s.substring(1, s.length - 1);
    if (s === "~") s = home || "~";
    else if (s.indexOf("~/") === 0) s = (home || "~") + s.substring(1);
    if (s.charAt(0) !== "/") {
        var base = String(cwd || "");
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

// Containment: equal to a root, or under it. "/tmpfoo" is NOT inside
// "/tmp"; "/" contains everything.
function pathAllowed(path, roots) {
    var p = String(path || "");
    if (!Array.isArray(roots)) return false;
    for (var i = 0; i < roots.length; i++) {
        var r = String(roots[i] || "").trim();
        if (!r) continue;
        r = r.replace(/\/+$/, "");
        if (r === "") r = "/";
        if (r === "/") return true;
        if (p === r || p.indexOf(r + "/") === 0) return true;
    }
    return false;
}

// ── Policy ────────────────────────────────────────────────────────

function _commandResult(kind, offending, folder) {
    return { verdict: "command", kind: kind, offendingPaths: offending || [],
             folder: folder || "" };
}

function _autoResult() {
    return { verdict: "auto", kind: null, offendingPaths: [], folder: "" };
}

// Flags that write/execute on an otherwise read-only word.
function writeFlagHit(word, tokens) {
    var flags = WRITE_FLAGS[word] || [];
    for (var i = 1; i < tokens.length; i++) {
        var t = tokens[i];
        for (var f = 0; f < flags.length; f++) {
            if (t === flags[f] || t.indexOf(flags[f] + "=") === 0) return t;
        }
    }
    return "";
}

function firstNonFlag(tokens) {
    for (var i = 1; i < tokens.length; i++)
        if (tokens[i].charAt(0) !== "-") return tokens[i];
    return "";
}

// Path-shaped words in one segment, skipping flags and the values of
// flags that carry data.
function pathCandidates(word, tokens) {
    var out = [];
    var values = FLAG_VALUES[word] || [];
    var patternWord = PATTERN_WORDS.indexOf(word) >= 0;
    var sawNonFlag = false;
    for (var i = 1; i < tokens.length; i++) {
        var t = tokens[i];
        if (t.charAt(0) === "-") {
            if (values.indexOf(t) >= 0 && i + 1 < tokens.length) i++;
            continue;
        }
        if (patternWord && !sawNonFlag) { sawNonFlag = true; continue; }
        sawNonFlag = true;
        if (/^-?\d+$/.test(t)) continue;
        out.push(t);
    }
    return out;
}

// The single decision point. policy: {yolo, allowedCommands,
// allowedDirs, home}.
function analyze(command, cwd, policy) {
    policy = policy || {};
    if (policy.yolo === true) return _autoResult();

    var home = String(policy.home || "");
    var dirs = Array.isArray(policy.allowedDirs) ? policy.allowedDirs : [];
    var userWords = Array.isArray(policy.allowedCommands)
        ? policy.allowedCommands : [];

    var cmd = String(command || "").trim();
    if (!cmd) return _commandResult("command");
    if (hasForbiddenMeta(cmd)) return _commandResult("command");

    var segs = splitSegments(cmd);
    if (segs.length === 0) return _commandResult("command");

    // The working directory is read too: `ls` with a hostile cwd reads
    // that directory with no path arguments at all.
    var cwdPath = normalizePath(cwd || home || "/", "", home);
    if (!pathAllowed(cwdPath, dirs))
        return _commandResult("cwd", [cwdPath], cwdPath);

    var offending = [];
    for (var i = 0; i < segs.length; i++) {
        var tokens = tokenize(segs[i]);
        if (tokens.length === 0) continue;
        var word = tokens[0];
        // A user-added word is a full grant: no grammar, no path scope.
        if (userWords.indexOf(word) >= 0) continue;
        if (BUILTIN_COMMANDS.indexOf(word) < 0)
            return _commandResult("command");
        if (writeFlagHit(word, tokens)) return _commandResult("command");
        if (SUBCOMMANDS[word]) {
            var sub = firstNonFlag(tokens);
            if (!sub || SUBCOMMANDS[word].indexOf(sub) < 0)
                return _commandResult("command");
        }
        var cands = pathCandidates(word, tokens);
        for (var c = 0; c < cands.length; c++) {
            var p = normalizePath(cands[c], cwdPath, home);
            if (!pathAllowed(p, dirs) && offending.indexOf(p) < 0)
                offending.push(p);
        }
    }

    if (offending.length > 0)
        // The grant offered is the path that was denied, not its parent:
        // a root that is a directory allows its tree, a root that is a
        // file only matches that file. Deterministic, no stat needed.
        return _commandResult("path", offending, offending[0]);
    return _autoResult();
}

// ── Execution helpers ─────────────────────────────────────────────

// argv only — the command is its own element, never concatenated into
// a shell string here. `timeout` is the primary killer; the service's
// job timer is the backstop. `exec 2>&1;` merges stderr into the one
// stream the collector reads (the command is already a script, so the
// constant prefix adds no injection surface).
function buildRunArgs(command, cwd, timeoutSeconds) {
    var t = timeoutSeconds > 0 ? Math.floor(timeoutSeconds) : DEFAULT_TIMEOUT;
    return {
        cmd: ["timeout", "-k", "2s", String(t) + "s", "sh", "-c",
              "exec 2>&1; " + String(command || "")],
        cwd: String(cwd || "")
    };
}

// Model-visible result. A non-zero exit is data, not an error.
function formatResult(res) {
    res = res || {};
    var cmd = String(res.command || "");
    var output = String(res.output || "");
    var killed = String(res.killed || "");
    var ms = typeof res.ms === "number" ? Math.max(0, Math.round(res.ms)) : 0;
    var code = typeof res.exitCode === "number" ? res.exitCode : -1;

    var header = "$ " + cmd + "\n";
    header += "[exit " + code + " \u00b7 " + ms + " ms";
    if (killed === "timeout") header += " \u00b7 timed out";
    header += "]\n";
    if (killed === "cap")
        header += "Output hit the 256 KB cap \u2014 the command was stopped "
                + "before it finished.\n";
    if (killed === "timeout")
        header += "The command timed out and was stopped.\n";

    if (!output) return header + "(no output)";
    if (output.length > MAX_MODEL_CHARS) {
        var tailLen = MAX_MODEL_CHARS - MODEL_HEAD_CHARS;
        var head = output.substring(0, MODEL_HEAD_CHARS);
        var tail = output.substring(output.length - tailLen);
        output = head
            + "\n\u2026 [truncated " + (output.length - MAX_MODEL_CHARS)
            + " of " + output.length + " characters] \u2026\n"
            + tail;
    }
    return header + output;
}

// A single-word command prefix, or "" when the input isn't one.
function cleanCommandWord(word) {
    var w = String(word || "").trim();
    if (!w || /\s/.test(w)) return "";
    if (w.charAt(0) === "-") return "";
    return w;
}
