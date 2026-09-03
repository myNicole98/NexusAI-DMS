import QtQuick
import Quickshell.Io
import "../lib/Providers.js" as Providers

// Per-instance API keys in the system keyring via secret-tool. One
// item per provider instance id; secrets never touch argv. The
// in-memory keys map mirrors the keyring for the session; without
// secret-tool, lookups are "" and store/clear are no-ops (env vars
// remain the fallback).
Item {
    id: root

    // secret-tool presence, checked once at startup.
    property bool available: false
    // account id → key, mirrored from keyring lookups + local stores.
    property var keys: ({})

    // --- Lookup queue (one secret-tool run at a time) ---
    property var _lookupQueue: []          // [accountId]
    property string _currentLookupId: ""

    // --- Mutation queue (store + clear jobs, sequential) ---
    property var _mutationQueue: []        // [{op: "store"|"clear", account, secret?}]
    property var _activeMutation: null

    // Fired when a secret-tool store failed; the optimistic in-memory
    // entry has already been rolled back when this fires.
    signal keyStoreFailed(string account)

    Component.onCompleted: availabilityCheck.running = true

    // ── Public API ────────────────────────────────────────────────

    // Queue a keyring lookup for one account id. Idempotent — ids
    // already queued or in flight are skipped. No-op when unavailable.
    function lookupKey(account) {
        if (!available) return;
        var id = String(account || "");
        if (id.length === 0 || _isLookupQueued(id)) return;
        _lookupQueue.push(id);
        _pumpLookup();
    }

    // Store a key for an account. Optimistic map update, rolled back
    // if secret-tool fails. No-op when unavailable.
    function storeKey(account, secret) {
        if (!available) return;
        var id = String(account || "");
        var safe = Providers.sanitizeApiKey(secret);
        if (id.length === 0 || !safe) return;
        _setKey(id, safe);
        _mutationQueue.push({ op: "store", account: id, secret: safe });
        _pumpMutations();
    }

    // Remove an account's key from the keyring; the map entry drops
    // immediately. No-op when unavailable.
    function clearKey(account) {
        if (!available) return;
        var id = String(account || "");
        if (id.length === 0) return;
        _setKey(id, "");
        _mutationQueue.push({ op: "clear", account: id });
        _pumpMutations();
    }

    // ── Internal ──────────────────────────────────────────────────

    // Reassign (new object) so var-property bindings re-evaluate.
    // Passing "" deletes the entry.
    function _setKey(account, key) {
        var m = {};
        for (var k in keys) m[k] = keys[k];
        if (key) m[account] = key;
        else delete m[account];
        keys = m;
    }

    function _isLookupQueued(account) {
        if (lookupProc.running && _currentLookupId === account) return true;
        return _lookupQueue.indexOf(account) >= 0;
    }

    function _pumpLookup() {
        if (lookupProc.running || _lookupQueue.length === 0) return;
        _currentLookupId = _lookupQueue.shift();
        lookupProc.command = ["secret-tool", "lookup",
                              "service", "nexus", "provider", _currentLookupId];
        lookupProc.running = true;
    }

    function _pumpMutations() {
        if (mutationProc.running || _mutationQueue.length === 0) return;
        _activeMutation = _mutationQueue.shift();
        // Only stores open stdin (the secret rides in on it); clears
        // take attributes from argv alone.
        mutationProc.stdinEnabled = (_activeMutation.op === "store");
        mutationProc.command = _activeMutation.op === "store"
            ? ["secret-tool", "store", "--label=Nexus AI — " + _activeMutation.account,
               "service", "nexus", "provider", _activeMutation.account]
            : ["secret-tool", "clear", "service", "nexus", "provider", _activeMutation.account];
        mutationProc.running = true;
    }

    // ── Processes ─────────────────────────────────────────────────

    // libsecret's secret-tool has no --version flag; presence is all
    // we need, so probe via which (exit 0 = available).
    Process {
        id: availabilityCheck
        running: false
        command: ["which", "secret-tool"]
        onExited: exitCode => { root.available = (exitCode === 0); }
    }

    // streamFinished has no params and fires before onExited —
    // attribute via _currentLookupId.
    Process {
        id: lookupProc
        running: false
        stdout: StdioCollector {
            id: lookupOut
            onStreamFinished: {
                var cur = root._currentLookupId;
                if (!cur) return;
                var secret = Providers.sanitizeApiKey(lookupOut.text);
                if (secret.length > 0) root._setKey(cur, secret);
            }
        }
        onExited: {
            root._currentLookupId = "";
            root._pumpLookup();
        }
    }

    Process {
        id: mutationProc
        running: false
        stdinEnabled: false

        onRunningChanged: {
            if (running && root._activeMutation
                    && root._activeMutation.op === "store") {
                mutationProc.write(root._activeMutation.secret);
                mutationProc.stdinEnabled = false;
            }
        }

        onExited: exitCode => {
            var job = root._activeMutation;
            root._activeMutation = null;
            if (job && job.op === "store" && exitCode !== 0) {
                root._setKey(job.account, "");   // roll back optimistic store
                root.keyStoreFailed(job.account);
            }
            root._pumpMutations();
        }
    }
}
