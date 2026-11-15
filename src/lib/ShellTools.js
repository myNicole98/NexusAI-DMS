.pragma library

// Native shell tool (`run_command`): argument validation, execution argv
// and result formatting.
//
// The permission model is deliberately binary: a command either runs
// because YOLO mode is on, or the user approves it — one card, one
// decision, no persisted grants and no folder scoping. That keeps the
// policy honest (the user sees every command before it runs) and leaves
// no fuzzy heuristics to get wrong.
//
// NativeToolsService.qml is the transport. Never log with nested
// parens — the test harness strips console.* naively.

var DEFAULT_TIMEOUT = 30;
var MIN_TIMEOUT = 5;
var MAX_TIMEOUT = 120;
// Hard collector cap: hitting it kills the command (see killed "cap").
var MAX_OUTPUT_BYTES = 256 * 1024;
// Model-visible output: head + tail with a marker between them.
var MAX_MODEL_CHARS = 24000;
var MODEL_HEAD_CHARS = 16000;

function isNativeTool(name) {
    return name === "run_command";
}

function toolDefs(enabledNames) {
    var all = [{
        type: "function",
        function: {
            name: "run_command",
            description: "Run a shell command on the user's machine. The " +
                "user sees every command and decides whether it runs, " +
                "unless they enabled YOLO mode. Pass cwd to work in a " +
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

// The single permission decision. "auto" only in YOLO mode; everything
// else is a one-shot approval for the card. `kind` is always "command"
// so the service and the card have one shape to render.
function analyze(command, cwd, policy) {
    var yolo = policy && policy.yolo === true;
    if (yolo) return { verdict: "auto", kind: null, offendingPaths: [],
                       folder: "" };
    return { verdict: "command", kind: "command", offendingPaths: [],
             folder: "" };
}

// argv only — the command is its own element, never concatenated into a
// shell string here. `timeout` is the primary killer; the service's job
// timer is the backstop. `exec 2>&1;` merges stderr into the one stream
// the collector reads (the command is already a script, so the constant
// prefix adds no injection surface).
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
