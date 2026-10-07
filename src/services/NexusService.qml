import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services
import "../lib/Providers.js" as Providers
import "../lib/StreamParser.js" as StreamParser
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/ModelIcons.js" as ModelIcons
import "../lib/PromptPresets.js" as PromptPresets
import "../lib/McpTools.js" as McpTools
import "../lib/WebTools.js" as WebTools
import "../lib/ContextWindows.js" as ContextWindows
import "../lib/ChatHistory.js" as ChatHistory

Item {
    id: root

    property string pluginId: "nexusAI"

    // ── Conversation state ────────────────────────────────────────

    property ListModel messagesModel: ListModel {}
    readonly property int messageCount: messagesModel.count
    property int _idCounter: 0
    property alias isStreaming: streaming.isStreaming

    // ── Chat history (opt-in) ─────────────────────────────────────
    // Store records {id, title, createdAt, updatedAt, messages[]},
    // newest-updated first; persisted as JSON "chats". Messages reuse
    // the exact ListModel role shape so restore = clear + append.
    property bool historyEnabled: false      // persisted
    property var chats: []                   // persisted as JSON "chats"
    property string activeChatId: ""         // persisted; "" = fresh chat
    property int _chatCounter: 0
    // Title-generation capture state (chat id + wire format frozen at
    // fire time — the user may switch chats while the fetch runs).
    property string _titleTargetChatId: ""
    property string _titleTargetFormat: ""
    property string _titleStdin: ""

    // ── Multi-provider state ──────────────────────────────────────
    // Instances are records {id, type, name, baseUrl, checkedModels[],
    // envVar?, discovered[]}; keys live in sessionKeys (keyring-fed,
    // memory only).

    property var providers: []               // persisted as JSON "providers"
    property string activeProviderId: ""     // persisted
    property string activeModel: ""          // persisted
    // Model/provider switches invalidate the meter window (probe and
    // registry lookups are per model).
    onActiveProviderIdChanged: {
        ollamaContextLength = 0;
        _recalcContextWindow();
    }
    onActiveModelChanged: {
        ollamaContextLength = 0;
        _recalcContextWindow();
    }
    property var pinnedModels: []            // persisted as JSON "pinnedModels"; items {providerId, model}
    property var sessionKeys: ({})           // per-instance keys, memory only, never persisted here
    // Per-instance keyring store failures (account → message); absent
    // means no failure. Cleared on the next setInstanceKey attempt.
    property var keyMessages: ({})
    property int _providerCounter: 0

    // ── Multi-MCP-server state ────────────────────────────────────
    // One instance per server {id, name, url, enabled, discovered[],
    // enabledTools[]}; token in the keyring under account "m<id>".
    property var mcpServers: []              // persisted as JSON "mcpServers"
    property int _mcpCounter: 0
    // Per-server session tokens (memory; keyring is the durable store).
    property var mcpSessionTokens: ({})
    // Per-server token store failures.
    property var mcpKeyMessages: ({})
    // Per-server connection errors from the MCPService instances.
    property var mcpConnectionErrors: ({})
    // Per-server connection state (boolean mirror of mcpService.isConnected
    // — QML bindings against per-instance Item properties don't notify
    // reliably from a Repeater's model scope).
    property var mcpConnected: ({})

    readonly property var activeInstance: getProvider(activeProviderId)
    readonly property string activeFormat: Providers.formatOf(activeInstance)
    readonly property bool activeIsOllama: !!activeInstance && activeInstance.type === "ollama"
    readonly property bool keyringAvailable: keyring.available

    // ── Generation settings (shared across all providers) ─────────
    // use* flag off → param omitted from the request.
    property bool useTemperature: false
    property real temperature: 0.7
    property bool useMaxTokens: false
    property int maxTokens: 4096
    property bool useContextWindow: false
    onUseContextWindowChanged: _recalcContextWindow()
    property int numCtx: 8192
    onNumCtxChanged: _recalcContextWindow()
    property string systemPrompt: ""
    property int timeoutSeconds: 300
    property string panelEdge: "right"

    // ── Context meter ─────────────────────────────────────────────
    // Last response's token usage ({input, output}); reset on
    // clearChat.
    property var lastUsage: null
    // Context window in tokens; 0 unknown. Ollama: numCtx setting or
    // /api/ps context_length; others: models.dev snapshot lookup.
    property int contextWindow: 0
    // Slimmed models.dev snapshot: {providerKey: {modelId: window}}.
    property var registryMap: ({})
    property real registryFetchedAt: 0
    // Loaded ollama runner context (/api/ps); 0 unknown.
    property int ollamaContextLength: 0

    // Which chord sends from the composer: "none" (bare Enter) |
    // "shift" | "ctrl" | "alt". Any other chord inserts a newline.
    property string sendModifier: "none"
    // MCP tools master switch (composer bar icon).
    property bool mcpToolsEnabled: true

    // Native web tools master switch (composer bar icon); opt-in.
    property bool webToolsEnabled: false

    // Per-tool switches; gated by the master switch in
    // getChatTools / callTool.
    property bool webSearchEnabled: true
    property bool webFetchEnabled: true

    property bool modelsRefreshing: false

    // Message being edited (memory only); submit regenerates from it.
    property string editingMessageId: ""
    signal editRequested(string text)

    // Random composer placeholder, re-rolled for every new chat.
    property string placeholder: "Ask anything…"
    property var _placeholderLines: []

    // Rotating status phrase shown next to the streaming snake;
    // re-rolled every 2 s while a stream is active, using the same
    // randomization rules as the composer placeholder.
    property string ponderingText: ""
    property var _ponderingLines: []

    // Startup icon-folder scan: each resources/icons/models/<stem>.svg
    // auto-binds a /<stem>/i rule (ModelIcons.setAutoIcons), so
    // dropping a file into the folder themes its models without any
    // code change.
    Component.onCompleted: {
        _loadSettings();
        iconScan.running = true;
        _connectAllEnabledMcpServers();
    }

    Process {
        id: iconScan
        command: {
            // decodeURIComponent: resolvedUrl percent-encodes the
            // space in "Nexus AI", and ls would target a nonexistent
            // directory.
            var dir = decodeURIComponent(
                Qt.resolvedUrl("../../resources/icons/models").toString().replace("file://", ""));
            return ["sh", "-c", "ls -1 '" + dir + "' | grep '\\.svg$' | sed 's/\\.svg$//'"];
        }
        stdout: StdioCollector {
            onStreamFinished: {
                var stems = text.split("\n").map(function (x) { return x.trim(); })
                    .filter(function (x) { return x.length > 0; });
                ModelIcons.setAutoIcons(stems);
                root.modelIconStems = stems;
            }
        }
    }

    // ── Settings persistence ──────────────────────────────────────

    function saveSetting(key, value) {
        PluginService.savePluginData(pluginId, key, value);
    }

    function _loadSettings() {
        temperature = PluginService.loadPluginData(pluginId, "temperature", 0.7);
        maxTokens = PluginService.loadPluginData(pluginId, "maxTokens", 4096);
        numCtx = PluginService.loadPluginData(pluginId, "numCtx", 8192);
        useTemperature = PluginService.loadPluginData(pluginId, "useTemperature", false);
        useMaxTokens = PluginService.loadPluginData(pluginId, "useMaxTokens", false);
        useContextWindow = PluginService.loadPluginData(pluginId, "useContextWindow", false);
        // Context meter: cached slim models.dev snapshot + fetch age.
        try {
            registryMap = JSON.parse(String(PluginService.loadPluginData(
                pluginId, "contextWindows", "{}")));
        } catch (e) { registryMap = {}; }
        registryFetchedAt = Number(PluginService.loadPluginData(
            pluginId, "contextWindowsFetchedAt", 0)) || 0;
        fetchContextRegistry(false);
        // Fresh install (no stored prompt): start on the default
        // Serious personality and persist it.
        var storedPrompt = PluginService.loadPluginData(pluginId, "systemPrompt", "__missing__");
        if (storedPrompt === "__missing__") {
            systemPrompt = PromptPresets.textFor("serious");
            saveSetting("systemPrompt", systemPrompt);
        } else {
            systemPrompt = String(storedPrompt);
        }
        timeoutSeconds = PluginService.loadPluginData(pluginId, "timeoutSeconds", 300);
        panelEdge = String(PluginService.loadPluginData(pluginId, "panelEdge", "right"));
        // Self-heal a stale/foreign stored chord value.
        var storedSendModifier = String(PluginService.loadPluginData(pluginId, "sendModifier", "none"));
        sendModifier = ["none", "shift", "ctrl", "alt"].indexOf(storedSendModifier) >= 0
            ? storedSendModifier : "none";
        mcpToolsEnabled = PluginService.loadPluginData(pluginId, "mcpToolsEnabled", true) === true;
        webToolsEnabled = PluginService.loadPluginData(pluginId, "webToolsEnabled", false) === true;
        webSearchEnabled = PluginService.loadPluginData(pluginId, "webSearchEnabled", true) === true;
        webFetchEnabled = PluginService.loadPluginData(pluginId, "webFetchEnabled", true) === true;
        historyEnabled = PluginService.loadPluginData(pluginId, "historyEnabled", false) === true;
        chats = ChatHistory.normalizeStore(PluginService.loadPluginData(pluginId, "chats", "[]"));
        _chatCounter = 0;
        activeChatId = "";
        var wantedChat = String(PluginService.loadPluginData(pluginId, "activeChatId", ""));
        for (var hc = 0; hc < chats.length; hc++) {
            var hrec = chats[hc];
            var hm = /^c(\d+)$/.exec(hrec ? String(hrec.id) : "");
            if (hm) _chatCounter = Math.max(_chatCounter, parseInt(hm[1], 10));
            if (hrec && hrec.id === wantedChat) activeChatId = wantedChat;
        }
        if (activeChatId !== "") _loadChatIntoModel(activeChatId);
        // Legacy single-server MCP keys → one multi-instance entry.
        var legacyMcpUrl = String(PluginService.loadPluginData(pluginId, "mcpUrl", "")).trim();
        var legacyMcpEnabled = PluginService.loadPluginData(pluginId, "mcpEnabled", false) === true;
        try {
            var praw = PluginService.loadPluginData(pluginId, "providers", "[]");
            var plist = JSON.parse(String(praw));
            if (Array.isArray(plist))
                for (var ni = 0; ni < plist.length; ni++)
                    if (plist[ni] && plist[ni].enabled === undefined)
                        plist[ni].enabled = true;
            providers = Array.isArray(plist) ? plist : [];
        } catch (e) { providers = []; }
        try {
            var mraw = PluginService.loadPluginData(pluginId, "mcpServers", "[]");
            var mlist = JSON.parse(String(mraw));
            if (!Array.isArray(mlist)) mlist = [];
            // Default new fields on older persisted entries; the legacy
            // "empty = all" expansion only applies to records persisted
            // before the toolSelectionV2 marker (see McpTools).
            for (var mi = 0; mi < mlist.length; mi++)
                mlist[mi] = McpTools.normalizeLoadedServer(mlist[mi]);
            // One-shot legacy migration; the old "mcp" keyring token
            // stays put (users re-key per server on first connect).
            if (mlist.length === 0 && legacyMcpUrl.length > 0) {
                mlist.push({ id: "m1", name: "MCP Server", url: legacyMcpUrl,
                             enabled: legacyMcpEnabled, discovered: [],
                             enabledTools: [] });
            }
            mcpServers = mlist;
        } catch (e) { mcpServers = []; }
        activeProviderId = String(PluginService.loadPluginData(pluginId, "activeProviderId", ""));
        activeModel = String(PluginService.loadPluginData(pluginId, "activeModel", "")).trim();
        try {
            var piraw = PluginService.loadPluginData(pluginId, "pinnedModels", "[]");
            var pilist = JSON.parse(String(piraw));
            var valid = [];
            if (Array.isArray(pilist)) {
                for (var pi = 0; pi < pilist.length; pi++) {
                    var rec = pilist[pi];
                    if (rec && rec.providerId && rec.model)
                        valid.push({ providerId: String(rec.providerId), model: String(rec.model) });
                }
            }
            pinnedModels = valid;
        } catch (e) { pinnedModels = []; }
        _providerCounter = 0;
        for (var i = 0; i < providers.length; i++) {
            var m = /^p(\d+)$/.exec(providers[i] ? String(providers[i].id) : "");
            if (m) _providerCounter = Math.max(_providerCounter, parseInt(m[1], 10));
        }
        // Self-heal a stale persisted selection (e.g. id from an older dataset).
        if (activeProviderId && !getProvider(activeProviderId))
            activeProviderId = providers.length > 0 ? providers[0].id : "";
        _mcpCounter = 0;
        var ids = [];
        for (var mi2 = 0; mi2 < mcpServers.length; mi2++) {
            var srv = mcpServers[mi2];
            if (srv && srv.id) ids.push(String(srv.id));
            var m2 = /^m(\d+)$/.exec(srv ? String(srv.id) : "");
            if (m2) _mcpCounter = Math.max(_mcpCounter, parseInt(m2[1], 10));
        }
        _mcpServiceIds = ids;
    }

    // ── Provider instances ────────────────────────────────────────

    function _persistProviders() {
        saveSetting("providers", JSON.stringify(providers));
    }

    // Reassign with CLONED instances: only a new object reference
    // re-evaluates delegate bindings (rows animate instead of
    // rebuilding).
    function _touchProviders() {
        var clones = [];
        for (var i = 0; i < providers.length; i++)
            clones.push(providers[i] ? Object.assign({}, providers[i]) : null);
        providers = clones;
    }

    function getProvider(id) {
        for (var i = 0; i < providers.length; i++)
            if (providers[i] && providers[i].id === id) return providers[i];
        return null;
    }

    function addProvider(type) {
        var reg = Providers.REGISTRY[type] || Providers.REGISTRY.custom;
        _providerCounter++;
        var id = "p" + _providerCounter;
        var name = reg.name;
        var taken = {};
        for (var i = 0; i < providers.length; i++)
            if (providers[i]) taken[providers[i].name] = true;
        if (taken[name]) {
            var n = 2;
            while (taken[name + " " + n]) n++;
            name = name + " " + n;
        }
        providers.push({ id: id, type: String(type), name: name,
                         baseUrl: reg.baseUrl, checkedModels: [],
                         enabled: true });
        _touchProviders();
        _persistProviders();
        // Pick up any keyring entry left by an earlier instance that
        // reused this id.
        keyring.lookupKey(id);
        return id;
    }

    function removeProvider(id) {
        var list = [];
        for (var i = 0; i < providers.length; i++)
            if (providers[i] && providers[i].id !== id) list.push(providers[i]);
        providers = list;
        _touchProviders();
        var keys = {};
        for (var k in sessionKeys) if (k !== id) keys[k] = sessionKeys[k];
        sessionKeys = keys;
        _setKeyMessage(id, "");   // no stale failure text on id reuse
        keyring.clearKey(id);   // no-op when the keyring is unavailable
        if (activeProviderId === id) {
            activeProviderId = list.length > 0 ? list[0].id : "";
            activeModel = "";
            saveSetting("activeProviderId", activeProviderId);
            saveSetting("activeModel", "");
        }
        _persistProviders();
    }

    function renameProvider(id, name) {
        var inst = getProvider(id);
        if (!inst) return;
        var trimmed = String(name || "").trim();
        if (!trimmed) return;
        inst.name = trimmed;
        _touchProviders();
        _persistProviders();
    }

    function setProviderUrl(id, url) {
        var inst = getProvider(id);
        if (!inst) return;
        inst.baseUrl = String(url || "").trim();
        _touchProviders();
        _persistProviders();
    }

    // Enable/disable an instance; disabled providers disappear from
    // the model picker. Disabling the active one hands the selection
    // to the first enabled instance (or clears it).
    function setProviderEnabled(id, enabled) {
        var inst = getProvider(id);
        if (!inst) return;
        inst.enabled = !!enabled;
        if (!inst.enabled && id === activeProviderId) {
            var nextId = "";
            for (var i = 0; i < providers.length; i++)
                if (providers[i] && providers[i].id !== id
                    && providers[i].enabled !== false) {
                    nextId = providers[i].id;
                    break;
                }
            activeProviderId = nextId;
            activeModel = "";
            saveSetting("activeProviderId", activeProviderId);
            saveSetting("activeModel", "");
        }
        _touchProviders();
        _persistProviders();
    }

    // Non-empty key → keyring store (session seeded optimistically —
    // storeKey is async, an unseeded sessionKeys would 401 mid-race);
    // empty → clear both. Without a keyring: session-only.
    function setInstanceKey(id, key) {
        var k = Providers.sanitizeApiKey(key);
        _setKeyMessage(id, "");   // new attempt — clear any prior failure
        if (keyringAvailable) {
            if (k) keyring.storeKey(id, k);
            else keyring.clearKey(id);
        }
        _setSessionKey(id, k);
    }

    function _setSessionKey(id, k) {
        var keys = {};
        for (var kk in sessionKeys) keys[kk] = sessionKeys[kk];
        if (k) keys[id] = k;
        else delete keys[id];
        sessionKeys = keys;
    }

    // Reassignment pattern, mirroring _setModelsError().
    // Empty msg deletes the entry.
    function _setKeyMessage(id, msg) {
        var m = {};
        for (var k in keyMessages) m[k] = keyMessages[k];
        if (msg) m[id] = msg;
        else delete m[id];
        keyMessages = m;
    }

    // Keyring hits land in sessionKeys. Merge, not replace: keys
    // typed before the async probe finished must survive.
    function _syncFromKeyring() {
        var m = {};
        for (var k in sessionKeys) m[k] = sessionKeys[k];
        for (var kk in keyring.keys)
            if (keyring.keys[kk]) m[kk] = keyring.keys[kk];
        sessionKeys = m;
    }

    function _queueAllKeyLookups() {
        for (var i = 0; i < providers.length; i++)
            if (providers[i]) keyring.lookupKey(providers[i].id);
    }

    function _syncFromKeyringMcp() {
        var m = {};
        for (var k in mcpSessionTokens) m[k] = mcpSessionTokens[k];
        for (var kk in keyring.keys)
            if (keyring.keys[kk]) m[kk] = keyring.keys[kk];
        mcpSessionTokens = m;
        // Keyring values may have just landed for an MCP account;
        // push them onto the backing services.
        for (var id in m) _pushMcpServerConfig(id);
    }

    function _queueAllMcpKeyLookups() {
        for (var i = 0; i < mcpServers.length; i++)
            if (mcpServers[i]) keyring.lookupKey(mcpServers[i].id);
    }

    // "keyring" | "session" | "env:<VARNAME>" | "none" — never returns
    // the key itself. A sessionKeys value is "keyring" when the
    // keyring is available (stores and lookups both route through it)
    // and "session" otherwise (memory-only value).
    function keyStatus(id) {
        var inst = getProvider(id);
        if (!inst) return "none";
        if (Providers.sanitizeApiKey(sessionKeys[inst.id] || ""))
            return keyringAvailable ? "keyring" : "session";
        var reg = Providers.REGISTRY[inst.type] || {};
        if (reg.envVar && Providers.sanitizeApiKey(Quickshell.env(reg.envVar)))
            return "env:" + reg.envVar;
        if (inst.type === "custom") {
            var dyn = Providers.customEnvVar(String(inst.name || ""));
            if (Providers.sanitizeApiKey(Quickshell.env(dyn)))
                return "env:" + dyn;
            if (inst.envVar && Providers.sanitizeApiKey(Quickshell.env(inst.envVar)))
                return "env:" + inst.envVar;
            if (Providers.sanitizeApiKey(Quickshell.env("NEXUS_API_KEY")))
                return "env:NEXUS_API_KEY";
        }
        return "none";
    }

    // Remove a manually-added custom model: unregisters it, unchecks
    // and unpins it, drops its display label, and clears the active
    // selection if it was active.
    function removeCustomModel(id, modelName) {
        var inst = getProvider(id);
        if (!inst || !modelName) return;
        var clean = String(modelName);
        var custom = inst.customModels || [];
        var idx = custom.indexOf(clean);
        if (idx >= 0) {
            custom.splice(idx, 1);
            inst.customModels = custom;
        }
        var checked = inst.checkedModels || [];
        var ci = checked.indexOf(clean);
        if (ci >= 0) {
            checked.splice(ci, 1);
            inst.checkedModels = checked;
        }
        var labels = {};
        for (var k in inst.modelLabels || {})
            if (k !== clean) labels[k] = inst.modelLabels[k];
        inst.modelLabels = labels;
        var pins = [];
        for (var p = 0; p < pinnedModels.length; p++) {
            var rec = pinnedModels[p];
            if (rec.providerId === id && rec.model === clean) continue;
            pins.push(rec);
        }
        if (pins.length !== pinnedModels.length) {
            pinnedModels = pins;
            saveSetting("pinnedModels", JSON.stringify(pins));
        }
        if (id === activeProviderId && activeModel === clean) {
            activeModel = "";
            saveSetting("activeModel", "");
        }
        _touchProviders();
        _persistProviders();
    }

    // Manually register a model id the discovery endpoint doesn't
    // list. Stored on the instance (customModels[]) so refreshes
    // can't wipe it, and auto-checked so it's immediately usable.
    function addCustomModel(id, modelName) {
        var inst = getProvider(id);
        if (!inst || !modelName) return;
        var clean = String(modelName).trim();
        if (!clean) return;
        var discovered = inst.discovered || [];
        for (var i = 0; i < discovered.length; i++)
            if (discovered[i] && String(discovered[i].id) === clean) return;
        var custom = inst.customModels || [];
        for (i = 0; i < custom.length; i++)
            if (String(custom[i]) === clean) return;
        custom.push(clean);
        inst.customModels = custom;
        var checked = inst.checkedModels || [];
        if (checked.indexOf(clean) < 0) {
            checked.push(clean);
            inst.checkedModels = checked;
        }
        _touchProviders();
        _persistProviders();
    }

    // Visual-only model rename: display labels live on the instance
    // (modelLabels[logicalId] = display). The logical id is what gets
    // sent to the API, stored in checkedModels/pins/activeModel.
    // Empty label clears the rename.
    function setModelLabel(id, modelId, label) {
        var inst = getProvider(id);
        if (!inst || !modelId) return;
        var labels = {};
        for (var k in inst.modelLabels || {})
            labels[k] = String(inst.modelLabels[k]);
        var clean = String(label || "").trim();
        if (clean) labels[String(modelId)] = clean;
        else delete labels[String(modelId)];
        inst.modelLabels = labels;
        _touchProviders();
        _persistProviders();
    }

    // Display name for a model under a provider: the renamed label
    // when one exists, otherwise the logical id.
    function modelLabel(providerId, modelId) {
        var inst = getProvider(providerId);
        if (inst && inst.modelLabels && inst.modelLabels[modelId])
            return String(inst.modelLabels[modelId]);
        return modelId;
    }

    function toggleModel(id, modelName) {
        var inst = getProvider(id);
        if (!inst || !modelName) return;
        var checked = inst.checkedModels || [];
        var idx = checked.indexOf(modelName);
        if (idx >= 0) {
            checked.splice(idx, 1);
            // Unchecking the active instance's active model must not
            // leave a stale selection behind.
            if (id === activeProviderId && activeModel === modelName) {
                activeModel = "";
                saveSetting("activeModel", "");
            }
        } else {
            checked.push(modelName);
        }
        inst.checkedModels = checked;
        _touchProviders();
        _persistProviders();
    }

    // Checked model ids of the active instance. Resolves via ids (not
    // the var property) so bindings re-evaluate on _touchProviders();
    // returns a copy so ListView models always reset.
    function activeModels() {
        var inst = getProvider(activeProviderId);
        var checked = inst ? (inst.checkedModels || []) : [];
        return checked.slice();
    }

    function setActiveProvider(id) {
        if (activeProviderId === id) return;
        activeProviderId = String(id || "");
        activeModel = "";
        saveSetting("activeProviderId", activeProviderId);
        saveSetting("activeModel", "");
    }

    function setActiveModel(m) {
        activeModel = String(m || "");
        saveSetting("activeModel", activeModel);
    }

    function isPinned(providerId, model) {
        for (var i = 0; i < pinnedModels.length; i++) {
            var p = pinnedModels[i];
            if (p && p.providerId === providerId && p.model === model) return true;
        }
        return false;
    }

    // Reassigns pinnedModels (not in-place) so var-property bindings
    // re-evaluate, mirroring the _touchProviders() pattern.
    function togglePinned(providerId, model) {
        if (!providerId || !model) return;
        var list = [];
        var removed = false;
        for (var i = 0; i < pinnedModels.length; i++) {
            var p = pinnedModels[i];
            if (p && p.providerId === providerId && p.model === model) {
                removed = true;
                continue;
            }
            list.push(p);
        }
        if (!removed) list.push({ providerId: String(providerId), model: String(model) });
        pinnedModels = list;
        saveSetting("pinnedModels", JSON.stringify(pinnedModels));
    }

    // ── MCP server instances ──────────────────────────────────────

    function _persistMcpServers() {
        saveSetting("mcpServers", JSON.stringify(mcpServers));
    }

    // Reassign so var-property bindings re-evaluate (mirrors
    // _touchProviders; same deep-clone rationale). Each write also
    // stamps toolSelectionV2 so the loader trusts an empty
    // enabledTools as an intentional "none enabled" selection.
    function _touchMcpServers() {
        var clones = [];
        for (var i = 0; i < mcpServers.length; i++) {
            if (!mcpServers[i]) { clones.push(null); continue; }
            var clone = Object.assign({}, mcpServers[i]);
            clone.toolSelectionV2 = true;
            clones.push(clone);
        }
        mcpServers = clones;
    }

    function getMcpServer(id) {
        for (var i = 0; i < mcpServers.length; i++)
            if (mcpServers[i] && mcpServers[i].id === id) return mcpServers[i];
        return null;
    }

    function _nextMcpId() {
        _mcpCounter++;
        return "m" + _mcpCounter;
    }

    function _uniqueMcpName(base) {
        var taken = {};
        for (var i = 0; i < mcpServers.length; i++)
            if (mcpServers[i]) taken[mcpServers[i].name] = true;
        if (!taken[base]) return base;
        var n = 2;
        while (taken[base + " " + n]) n++;
        return base + " " + n;
    }

    function addMcpServer() {
        var id = _nextMcpId();
        mcpServers.push({
            id: id,
            name: _uniqueMcpName("MCP Server"),
            url: "",
            enabled: true,
            discovered: [],
            enabledTools: []
        });
        _touchMcpServers();
        _persistMcpServers();
        // Append the new id to the Instantiator model — the
        // Instantiator creates a new MCPService Item, which picks
        // up url/token from mcpServers[id] on next read.
        var ids = _mcpServiceIds.slice();
        ids.push(id);
        _mcpServiceIds = ids;
        // Pull any keyring entry left over from an instance that
        // previously reused this id.
        keyring.lookupKey(id);
        return id;
    }

    function removeMcpServer(id) {
        var list = [];
        for (var i = 0; i < mcpServers.length; i++)
            if (mcpServers[i] && mcpServers[i].id !== id) list.push(mcpServers[i]);
        mcpServers = list;
        _touchMcpServers();
        // Drop session token + keyring entry + any live connection.
        var toks = {};
        for (var k in mcpSessionTokens) if (k !== id) toks[k] = mcpSessionTokens[k];
        mcpSessionTokens = toks;
        _setMcpKeyMessage(id, "");
        keyring.clearKey(id);
        var svc = _mcpServiceFor(id);
        if (svc && svc.isConnected) svc.disconnectFromServer();
        _setMcpConnected(id, false);
        _setMcpConnectionError(id, "");
        // Remove the id from the Instantiator model so the backing
        // MCPService Item is destroyed.
        var ids = [];
        for (var j = 0; j < _mcpServiceIds.length; j++)
            if (_mcpServiceIds[j] !== id) ids.push(_mcpServiceIds[j]);
        _mcpServiceIds = ids;
        _persistMcpServers();
    }

    function setMcpServerUrl(id, url) {
        var inst = getMcpServer(id);
        if (!inst) return;
        var clean = String(url || "").trim();
        if (inst.url === clean) return;
        inst.url = clean;
        // URL changed — drop the previous tool list (the names come
        // from this server's discovery).
        inst.discovered = [];
        inst.enabledTools = [];
        _touchMcpServers();
        _persistMcpServers();
        _pushMcpServerConfig(id);
        // Disconnect the live connection if it pointed at the old URL.
        var svc = _mcpServiceFor(id);
        if (svc && svc.isConnected) svc.disconnectFromServer();
    }

    function renameMcpServer(id, name) {
        var inst = getMcpServer(id);
        if (!inst) return;
        var trimmed = String(name || "").trim();
        if (!trimmed) return;
        inst.name = trimmed;
        _touchMcpServers();
        _persistMcpServers();
        // Token env-var name derives from the server name; push the
        // resolved token onto the backing service so it sees the new
        // env lookup result.
        _pushMcpServerConfig(id);
    }

    function setMcpServerEnabled(id, enabled) {
        var inst = getMcpServer(id);
        if (!inst) return;
        inst.enabled = !!enabled;
        if (!inst.enabled) {
            // Disabling an MCP server should immediately drop its
            // connection so we don't keep spawning mcp-remote processes.
            var svc = _mcpServiceFor(id);
            if (svc && svc.isConnected) svc.disconnectFromServer();
        }
        _touchMcpServers();
        _persistMcpServers();
    }

    // Dynamic env var name for an MCP server, mirroring
    // Providers.customEnvVar: "My Server" -> NEXUS_MCP_MY_SERVER_TOKEN.
    function mcpEnvVar(name) {
        var s = String(name || "").toUpperCase().replace(/[^A-Z0-9]+/g, "_");
        s = s.replace(/^_+|_+$/g, "");
        if (!s) s = "SERVER";
        return "NEXUS_MCP_" + s + "_TOKEN";
    }

    // Token resolution per server: session value → dynamic env var.
    function resolveMcpToken(serverId, name) {
        var inst = getMcpServer(serverId);
        var session = Providers.sanitizeApiKey(
            mcpSessionTokens[serverId] || "");
        if (session) return session;
        var envName = mcpEnvVar(name || (inst ? inst.name : ""));
        return Providers.sanitizeApiKey(Quickshell.env(envName));
    }

    // "keyring" | "session" | "env:<NAME>" | "none" — same vocabulary
    // as keyStatus so the UI text mirrors provider-key statuses.
    function mcpKeyStatus(serverId) {
        if (Providers.sanitizeApiKey(mcpSessionTokens[serverId] || ""))
        return keyringAvailable ? "keyring" : "session";
        var inst = getMcpServer(serverId);
        if (!inst) return "none";
        var envName = mcpEnvVar(inst.name);
        if (Providers.sanitizeApiKey(Quickshell.env(envName)))
        return "env:" + envName;
        return "none";
    }

    // Non-empty token → keyring store (optimistic, like API keys) +
    // session map; empty token → clear both. Resolution order ends
    // up: keyring/session → env var → none.
    function setMcpServerToken(id, token) {
        var k = Providers.sanitizeApiKey(token);
        _setMcpKeyMessage(id, "");
        if (keyringAvailable) {
            if (k) keyring.storeKey(id, k);
            else keyring.clearKey(id);
        }
        _setMcpSessionToken(id, k);
        // Push the resolved token onto the backing service so its
        // next connect uses the latest value (the keyring store is
        // async — this closes the same race fixed in providers).
        _pushMcpServerConfig(id);
    }

    function _setMcpSessionToken(id, k) {
        var toks = {};
        for (var kk in mcpSessionTokens) toks[kk] = mcpSessionTokens[kk];
        if (k) toks[id] = k;
        else delete toks[id];
        mcpSessionTokens = toks;
    }

    function _setMcpKeyMessage(id, msg) {
        var m = {};
        for (var k in mcpKeyMessages) m[k] = mcpKeyMessages[k];
        if (msg) m[id] = msg;
        else delete m[id];
        mcpKeyMessages = m;
    }

    function _setMcpConnected(id, connected) {
        var m = {};
        for (var k in mcpConnected) m[k] = mcpConnected[k];
        if (connected) m[id] = true;
        else delete m[id];
        mcpConnected = m;
    }

    function _setMcpConnectionError(id, msg) {
        var m = {};
        for (var k in mcpConnectionErrors) m[k] = mcpConnectionErrors[k];
        if (msg) m[id] = msg;
        else delete m[id];
        mcpConnectionErrors = m;
    }

    // enabledTools is a complete positive list — empty means "none
    // enabled", NOT "all on" (the dual meaning once let one click
    // turn everything off). Select/deselect-all materialize the list.
    function toggleMcpTool(serverId, toolName) {
        var inst = getMcpServer(serverId);
        if (!inst || !toolName) return;
        var clean = String(toolName);
        var list = (inst.enabledTools || []).slice();
        var idx = list.indexOf(clean);
        if (idx >= 0) list.splice(idx, 1);
        else list.push(clean);
        inst.enabledTools = list;
        _touchMcpServers();
        _persistMcpServers();
    }

    // Enable every discovered tool on a server (replaces the list with
    // the full positive set — see toggleMcpTool).
    function selectAllMcpTools(serverId) {
        var inst = getMcpServer(serverId);
        if (!inst) return;
        var disc = inst.discovered || [];
        var next = [];
        var seen = {};
        for (var i = 0; i < disc.length; i++) {
            var t = disc[i];
            if (!t || !t.name || seen[String(t.name)]) continue;
            seen[String(t.name)] = true;
            next.push(String(t.name));
        }
        inst.enabledTools = next;
        _touchMcpServers();
        _persistMcpServers();
    }

    // Disable every discovered tool on a server (empty positive list).
    function deselectAllMcpTools(serverId) {
        var inst = getMcpServer(serverId);
        if (!inst) return;
        inst.enabledTools = [];
        _touchMcpServers();
        _persistMcpServers();
    }

    // Chat-request tool list: enabled MCP tools (gated by
    // mcpToolsEnabled) + native web tools, OpenAI-shaped.
    function getChatTools() {
        var out = [];
        if (mcpToolsEnabled) {
            for (var i = 0; i < mcpServers.length; i++) {
                var inst = mcpServers[i];
                if (!inst || inst.enabled === false) continue;
                var svc = _mcpServiceFor(inst.id);
                if (!svc || !svc.isConnected) continue;
                var disc = inst.discovered || [];
                var enabled = inst.enabledTools || [];
                for (var t = 0; t < disc.length; t++) {
                    var tool = disc[t];
                    if (!tool || !tool.name) continue;
                    if (enabled.indexOf(String(tool.name)) < 0) continue;
                    out.push({
                        type: "function",
                        function: {
                            name: tool.name,
                            description: tool.description || "",
                            parameters: tool.inputSchema || { type: "object", properties: {} }
                        }
                    });
                }
            }
        }
        if (webToolsEnabled) {
            var enabledNames = [];
            if (webSearchEnabled) enabledNames.push("web_search");
            if (webFetchEnabled) enabledNames.push("webfetch");
            out = out.concat(WebTools.toolDefs(enabledNames));
        }
        return out;
    }

    // Connected MCP toolsets contributing to chat requests (native
    // web tools have their own chip and don't count).
    function activeToolsetCount() {
        var n = 0;
        if (!mcpToolsEnabled) return n;
        for (var i = 0; i < mcpServers.length; i++) {
            var inst = mcpServers[i];
            if (!inst || inst.enabled === false) continue;
            if (!mcpConnected[inst.id]) continue;
            var disc = inst.discovered || [];
            var enabled = inst.enabledTools || [];
            for (var t = 0; t < disc.length; t++) {
                var tool = disc[t];
                if (tool && tool.name
                    && enabled.indexOf(String(tool.name)) >= 0) {
                    n++;
                    break;
                }
            }
        }
        return n;
    }

    // Per-server MCP service lookup. Created lazily on first access;
    // see the Item block at the bottom of this service for the
    // backing Item instances.
    function _mcpServiceFor(id) {
        if (!id) return null;
        var item = mcpServiceInstances[id];
        return item || null;
    }

    // ── Conversation ──────────────────────────────────────────────

    function sendMessage(text, images) {
        editingMessageId = "";
        var cleanImgs = Providers.sanitizeImages(images);
        var trimmed = String(text || "").trim();
        if ((!trimmed && cleanImgs.length === 0) || isStreaming) return;
        if (!activeInstance || !activeModel) {
            messagesModel.append({
                id: _nextId(), role: "system", content:
                    "Add a provider and pick a model in settings.",
                thinking: "", toolLog: "[]", attachments: "[]", usage: "",
                modelUsed: "", modelProviderId: "",
                state: "error", stats: "", timestamp: Date.now()
            });
            return;
        }
        var userMsg = _msg("user", trimmed, "done");
        if (cleanImgs.length > 0)
            userMsg.attachments = JSON.stringify(cleanImgs);
        messagesModel.append(userMsg);
        var assistantId = _nextId();
        messagesModel.append(_msg("assistant", ""));
        messagesModel.setProperty(messagesModel.count - 1, "id", assistantId);
        _request(assistantId);
    }

    function retryLast() {
        if (isStreaming) return;
        // drop trailing assistant messages back to the last user message
        while (messagesModel.count > 0) {
            var last = messagesModel.get(messagesModel.count - 1);
            if (last.role === "assistant") { messagesModel.remove(messagesModel.count - 1); continue; }
            break;
        }
        if (messagesModel.count === 0) return;
        var lastUser = messagesModel.get(messagesModel.count - 1);
        if (lastUser.role !== "user") return;
        var assistantId = _nextId();
        messagesModel.append(_msg("assistant", ""));
        messagesModel.setProperty(messagesModel.count - 1, "id", assistantId);
        _request(assistantId);
    }

    // Re-run the assistant turn for a specific (already-rendered)
    // assistant message. Drops every message after it (including any
    // assistant turns that followed), so the conversation re-fans out
    // from the same user prompt that produced the targeted reply.
    function regenerateMessage(assistantMsgId) {
        if (isStreaming) return;
        var i = _indexOfId(assistantMsgId);
        if (i < 0) return;
        var target = messagesModel.get(i);
        if (!target || target.role !== "assistant") return;
        // Drop everything from the targeted message to the end — same
        // shape as retryLast() but anchored on a specific id, not the
        // most-recent assistant turn.
        while (messagesModel.count > i)
            messagesModel.remove(messagesModel.count - 1);
        if (messagesModel.count === 0) return;
        var lastUser = messagesModel.get(messagesModel.count - 1);
        if (lastUser.role !== "user") return;
        var newAssistantId = _nextId();
        messagesModel.append(_msg("assistant", ""));
        messagesModel.setProperty(messagesModel.count - 1, "id", newAssistantId);
        _request(newAssistantId);
    }

    // Start editing a sent user message: record the id (the owning
    // bubble fades itself) and hand the text to the composer via
    // editRequested. Refused while a stream is live.
    function beginEditUserMessage(msgId) {
        if (isStreaming) return;
        var i = _indexOfId(msgId);
        if (i < 0) return;
        var m = messagesModel.get(i);
        if (!m || m.role !== "user") return;
        editingMessageId = msgId;
        editRequested(m.content);
    }

    // Up-arrow affordance: edit the most recent user message (the
    // composer calls this only while its input is empty). No-op when
    // the conversation has no user turns or a stream is live.
    function beginEditLastUserMessage() {
        if (isStreaming) return;
        for (var i = messagesModel.count - 1; i >= 0; i--) {
            var m = messagesModel.get(i);
            if (m && m.role === "user") {
                beginEditUserMessage(m.id);
                return;
            }
        }
    }

    // ── Send-modifier setting ─────────────────────────────────────

    function setSendModifier(m) {
        var v = ["none", "shift", "ctrl", "alt"].indexOf(m) >= 0 ? String(m) : "none";
        if (sendModifier === v) return;
        sendModifier = v;
        saveSetting("sendModifier", v);
    }

    // ── MCP tools master switch ───────────────────────────────────

    function setMcpToolsEnabled(enabled) {
        var v = !!enabled;
        if (mcpToolsEnabled === v) return;
        mcpToolsEnabled = v;
        saveSetting("mcpToolsEnabled", v);
    }

    // ── Native web tools master switch ────────────────────────────

    function setWebToolsEnabled(enabled) {
        var v = !!enabled;
        if (webToolsEnabled === v) return;
        webToolsEnabled = v;
        saveSetting("webToolsEnabled", v);
    }

    // ── Native per-tool switches ──────────────────────────────────

    // "web_search" | "webfetch". Unknown names are ignored. These only
    // gate the native tools inside a master-on state — flipping them
    // never touches webToolsEnabled.
    function setNativeToolEnabled(name, enabled) {
        var v = !!enabled;
        if (name === "web_search") {
            if (webSearchEnabled === v) return;
            webSearchEnabled = v;
            saveSetting("webSearchEnabled", v);
        } else if (name === "webfetch") {
            if (webFetchEnabled === v) return;
            webFetchEnabled = v;
            saveSetting("webFetchEnabled", v);
        }
    }

    function nativeToolEnabled(name) {
        if (name === "web_search") return webSearchEnabled;
        if (name === "webfetch") return webFetchEnabled;
        return false;
    }

    // Abandon an in-progress edit; the bubble un-fades and the
    // composer text is left for the user to clear or send.
    function cancelEditUserMessage() {
        editingMessageId = "";
    }

    // Edit a sent user message: drop everything after it, update the
    // text, regenerate. No-op while a stream is live.
    function editUserMessage(userMsgId, newText) {
        editingMessageId = "";
        if (isStreaming) return;
        var trimmed = String(newText || "").trim();
        if (!trimmed) return;
        var i = _indexOfId(userMsgId);
        if (i < 0) return;
        var target = messagesModel.get(i);
        if (!target || target.role !== "user") return;
        // Drop everything after the user message.
        while (messagesModel.count > i + 1)
            messagesModel.remove(messagesModel.count - 1);
        // Update content in place. Keep id (any references in the UI
        // still resolve); the message itself persists.
        _setMsg(userMsgId, { content: trimmed });
        var newAssistantId = _nextId();
        messagesModel.append(_msg("assistant", ""));
        messagesModel.setProperty(messagesModel.count - 1, "id", newAssistantId);
        _request(newAssistantId);
    }

    function cancelStream() {
        streaming.cancel();
    }

    function clearChat() {
        if (isStreaming) streaming.reset();
        editingMessageId = "";
        messagesModel.clear();
        lastUsage = null;
        placeholder = pickPlaceholder();
    }

    // ── Chat history store ────────────────────────────────────────

    function setHistoryEnabled(enabled) {
        var v = !!enabled;
        if (historyEnabled === v) return;
        historyEnabled = v;
        saveSetting("historyEnabled", v);
    }

    function _findChat(id) {
        for (var i = 0; i < chats.length; i++)
            if (chats[i] && chats[i].id === id) return chats[i];
        return null;
    }

    // Reassignment pattern (mirrors _touchProviders): only a fresh
    // array re-evaluates Repeater/delegate bindings over `chats`.
    function _touchChats() {
        var clones = [];
        for (var i = 0; i < chats.length; i++)
            clones.push(chats[i] ? Object.assign({}, chats[i]) : null);
        chats = clones;
    }

    // Persist with image payloads stripped (ChatHistory).
    function _persistChats() {
        var out = [];
        for (var i = 0; i < chats.length; i++) {
            var s = ChatHistory.sanitizeForPersist(chats[i]);
            if (s) out.push(s);
        }
        saveSetting("chats", JSON.stringify(out));
    }

    function _rowsFromModel() {
        var out = [];
        for (var i = 0; i < messagesModel.count; i++) {
            var m = messagesModel.get(i);
            out.push({ id: m.id, role: m.role, content: m.content,
                       thinking: m.thinking, toolLog: m.toolLog,
                       attachments: m.attachments, usage: m.usage,
                       modelUsed: m.modelUsed,
                       modelProviderId: m.modelProviderId,
                       state: m.state, stats: m.stats,
                       timestamp: m.timestamp });
        }
        return out;
    }

    function _loadChatIntoModel(id) {
        var rec = _findChat(id);
        if (!rec) return;
        messagesModel.clear();
        for (var i = 0; i < rec.messages.length; i++) {
            var m = rec.messages[i];
            // Fill every role: ListModel roles are fixed by the first
            // append, so partial records must not shape the model.
            messagesModel.append({
                id: m.id, role: m.role, content: m.content || "",
                thinking: m.thinking || "", toolLog: m.toolLog || "[]",
                attachments: m.attachments || "[]", usage: m.usage || "",
                modelUsed: m.modelUsed || "",
                modelProviderId: m.modelProviderId || "",
                state: m.state || "done", stats: m.stats || "",
                timestamp: m.timestamp || 0
            });
        }
    }

    // Snapshot the live conversation into the store (allocating its id
    // on first save), newest-first, then persist. No-op when history
    // is off or the model holds no user turns (no empty stubs).
    function _saveActiveChat() {
        if (!historyEnabled) return;
        var hasUser = false;
        for (var i = 0; i < messagesModel.count; i++)
            if (messagesModel.get(i).role === "user") { hasUser = true; break; }
        if (!hasUser) return;
        var now = Date.now();
        if (activeChatId === "") {
            _chatCounter++;
            activeChatId = "c" + _chatCounter;
            saveSetting("activeChatId", activeChatId);
        }
        var rec = _findChat(activeChatId);
        if (rec) {
            rec.updatedAt = now;
            rec.messages = _rowsFromModel();
        } else {
            chats.unshift({ id: activeChatId, title: "", createdAt: now,
                            updatedAt: now, messages: _rowsFromModel() });
        }
        chats.sort(function (a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0); });
        _touchChats();
        _persistChats();
    }

    // Fresh editor: the current chat is already auto-saved (or empty
    // and discarded), so just drop the view. Doubles as the clear button
    // when history is off (_saveActiveChat no-ops).
    function newChat() {
        if (isStreaming) streaming.cancel();
        _saveActiveChat();
        editingMessageId = "";
        messagesModel.clear();
        activeChatId = "";
        saveSetting("activeChatId", "");
        lastUsage = null;
        placeholder = pickPlaceholder();
    }

    function openChat(id) {
        if (!historyEnabled) return;
        var clean = String(id || "");
        var rec = _findChat(clean);
        if (!rec) return;
        if (clean === activeChatId) return;
        // Cancel a live stream first: cancel() emits streamCancelled,
        // whose handler stamps the in-flight row "cancelled" and
        // snapshots the outgoing chat before the swap.
        if (isStreaming) { streaming.cancel(); _saveActiveChat(); }
        else _saveActiveChat();
        activeChatId = clean;
        saveSetting("activeChatId", clean);
        _loadChatIntoModel(clean);
        editingMessageId = "";
        lastUsage = null;
        placeholder = pickPlaceholder();
    }

    function deleteChat(id) {
        // Deleting the active chat mid-stream: cancel() first — its
        // synchronous cancelled→save cycle lands on the still-active
        // chat before the removal below, so the stream can't
        // resurrect the chat under a fresh id afterward.
        if (isStreaming && activeChatId === id) streaming.cancel();
        var list = [];
        for (var i = 0; i < chats.length; i++)
            if (chats[i] && chats[i].id !== id) list.push(chats[i]);
        chats = list;
        if (activeChatId === id) {
            activeChatId = "";
            saveSetting("activeChatId", "");
            messagesModel.clear();
            lastUsage = null;
        }
        _persistChats();
    }

    function deleteAllChats() {
        chats = [];
        if (isStreaming) streaming.reset();
        activeChatId = "";
        saveSetting("activeChatId", "");
        editingMessageId = "";
        messagesModel.clear();
        lastUsage = null;
        placeholder = pickPlaceholder();
        _persistChats();
    }

    // UI-facing label: model title once set, else fallback truncation
    // of the first user turn.
    function chatDisplayTitle(chat) {
        if (!chat) return "";
        if (chat.title && chat.title.length > 0) return chat.title;
        return _fallbackTitleFor(chat);
    }

    function _fallbackTitleFor(rec) {
        var msgs = rec && rec.messages ? rec.messages : [];
        for (var i = 0; i < msgs.length; i++) {
            var m = msgs[i];
            if (m && m.role === "user")
                return ChatHistory.fallbackTitle(m.content);
        }
        return "";
    }

    // After any terminal message state: persist the chat and, on the
    // first completed exchange, fire title generation. Entirely gated
    // on the master switch — dead code while history is off.
    function _onTurnFinished() {
        if (!historyEnabled) return;
        _saveActiveChat();
        _maybeGenerateTitle();
    }

    function _maybeGenerateTitle() {
        if (titleFetcher.running) return;
        var rec = _findChat(activeChatId);
        if (!rec || rec.title.length > 0) return;
        var u = "", a = "";
        for (var i = 0; i < messagesModel.count; i++) {
            var m = messagesModel.get(i);
            if (m.role === "user" && u === "") u = m.content;
            else if (m.role === "assistant" && u !== "" && a === "") a = m.content;
        }
        if (u === "" || String(a).trim() === "") return;
        var inst = activeInstance;
        if (!inst || !activeModel) return;
        var req = Providers.buildChatRequest(inst, {
            sessionKey: sessionKeys[inst.id] || "",
            model: activeModel,
            rawMessages: true,
            messages: [{ role: "user",
                         content: ChatHistory.titlePrompt(u, a) }],
            systemPrompt: "",
            temperature: 0.3,
            maxTokens: 30,
            timeoutSeconds: 30,
            stream: false
        });
        if (!req) return;
        _titleTargetChatId = activeChatId;
        _titleTargetFormat = activeFormat;
        _titleStdin = req.body;
        titleFetcher.stdinEnabled = true;
        titleFetcher.command = req.cmd;
        titleFetcher.running = true;
    }

    // One-shot non-streaming curl for the title (modelsFetcher recipe;
    // never StreamingService). onExited runs after onStreamFinished —
    // the cleared _titleTargetChatId makes the second _applyTitle a no-op.
    Process {
        id: titleFetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root._titleStdin) {
                titleFetcher.write(root._titleStdin);
                titleFetcher.stdinEnabled = false;
                root._titleStdin = "";
            }
        }

        stdout: StdioCollector {
            id: titleOut
            onStreamFinished: {
                var parsed = StreamParser.extractHttpStatus(titleOut.text);
                var text = (parsed.status >= 200 && parsed.status < 400)
                    ? StreamParser.extractNonStreamingText(
                          parsed.body, root._titleTargetFormat)
                    : "";
                root._applyTitle(ChatHistory.cleanTitle(text));
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) root._applyTitle("");
        }

        stderr: StdioCollector {
            id: titleErr
            onStreamFinished: {
                if (titleErr.text.length > 0)
                    console.warn("NexusAI title: curl stderr = " + titleErr.text);
            }
        }
    }

    // Land a generated title on its chat by capture-time id (the user
    // may have switched away). Empty/failed results fall back to the
    // truncated first prompt. Titles only — messages never re-persist.
    function _applyTitle(cleaned) {
        var id = _titleTargetChatId;
        _titleTargetChatId = "";
        if (!id) return;
        var rec = _findChat(id);
        if (!rec) return;                       // deleted meanwhile
        if (rec.title.length > 0) return;       // already titled
        rec.title = (cleaned && cleaned.length > 0)
            ? cleaned : _fallbackTitleFor(rec);
        _touchChats();
        _persistChats();
    }

    function pickPlaceholder() {
        var lines = _placeholderLines;
        if (!lines || lines.length === 0) return "Ask anything…";
        return lines[Math.floor(Math.random() * lines.length)];
    }

    function pickPondering() {
        var lines = _ponderingLines;
        if (!lines || lines.length === 0) return "";
        return lines[Math.floor(Math.random() * lines.length)];
    }

    FileView {
        id: placeholdersFile
        path: decodeURIComponent(
                  Qt.resolvedUrl("../../resources/placeholders.txt").toString()
                  .replace(/^file:\/\//, ""))

        onLoaded: {
            try {
                var lines = String(text()).split("\n");
                var cleaned = [];
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line.length > 0) cleaned.push(line);
                }
                root._placeholderLines = cleaned;
            } catch (e) {}
            root.placeholder = root.pickPlaceholder();
        }

        onLoadFailed: (error) => {
            console.warn("NexusAI: placeholders file failed to load (" + error + ")");
        }
    }

    FileView {
        id: ponderingsFile
        path: decodeURIComponent(
                  Qt.resolvedUrl("../../resources/pondering.txt").toString()
                  .replace(/^file:\/\//, ""))

        onLoaded: {
            try {
                var lines = String(text()).split("\n");
                var cleaned = [];
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line.length > 0) cleaned.push(line);
                }
                root._ponderingLines = cleaned;
            } catch (e) {}
            if (root.isStreaming) root.ponderingText = root.pickPondering();
        }

        onLoadFailed: (error) => {
            console.warn("NexusAI: pondering file failed to load (" + error + ")");
        }
    }

    // Pondering phrase rotation: only ticks while a stream is live.
    Timer {
        id: ponderingTicker
        interval: 2000
        repeat: true
        running: root.isStreaming
        onTriggered: root.ponderingText = root.pickPondering()
    }

    function _msg(role, content, state) {
        return {
            id: _nextId(), role: role, content: content, thinking: "",
            // JSON strings — ListModel can't hold JS object arrays.
            toolLog: "[]",
            attachments: "[]",
            usage: "",
            modelUsed: activeModel,
            modelProviderId: activeProviderId,
            state: state || "streaming", stats: "", timestamp: Date.now()
        };
    }    function _nextId() { return "m" + (++_idCounter); }

    function _historyForRequest() {
        var out = [];
        for (var i = 0; i < messagesModel.count; i++) {
            var m = messagesModel.get(i);
            var rec = { role: m.role, content: m.content, state: m.state };
            // Attachments become neutral images for the payload.
            if (m.role === "user" && m.attachments && m.attachments.length > 2) {
                try {
                    var arr = JSON.parse(m.attachments);
                    if (Array.isArray(arr) && arr.length > 0) rec.images = arr;
                } catch (e) {}
            }
            out.push(rec);
        }
        return out;
    }

    function _request(streamId) {
        var inst = activeInstance;
        if (!inst || !activeModel) {
            _setMsg(streamId, { state: "error", content: "No provider selected — add one in settings." });
            return;
        }
        // Raw history — buildApiPayload filters unfinished turns; the
        // same payload messages feed MCP tool rounds.
        var payloadMsgs = Providers.buildApiPayload(inst, {
            systemPrompt: systemPrompt,
            messages: _historyForRequest()
        }).messages;
        streaming.begin(streamId);
        // Seed tool-round memory: without it a relaunch would start
        // with the assistant turn, which Gemini/Z.AI reject (400).
        streaming._conversationMessages = payloadMsgs;
        _launch(streamId, payloadMsgs);
    }

    // Tool rounds relaunch with rawMessages (they bypass the
    // history filter); no begin() — state persists across rounds.
    function _launch(streamId, payloadMsgs) {
        var inst = activeInstance;
        if (!inst || !activeModel) {
            _setMsg(streamId, { state: "error", content: "No provider selected — add one in settings." });
            return;
        }
        var chatTools = getChatTools();
        var toolsLive = chatTools.length > 0;
        var req = Providers.buildChatRequest(inst, {
            sessionKey: sessionKeys[inst.id] || "",
            model: activeModel,
            messages: payloadMsgs,
            rawMessages: true,
            tools: toolsLive ? chatTools : null,
            systemPrompt: systemPrompt,
            temperature: useTemperature ? temperature : null,
            maxTokens: useMaxTokens ? maxTokens : 0,
            numCtx: (activeIsOllama && useContextWindow) ? numCtx : 0,
            timeoutSeconds: timeoutSeconds,
            envLookup: function (name) { return Quickshell.env(name); }
        });
        if (!req) {
            _setMsg(streamId, { state: "error", content: "Could not build the request — check the provider base URL and model." });
            return;
        }
        streaming.format = activeFormat;
        streaming.mcpService = toolsLive ? mcpRouter : null;
        streamWatchdog.start();
        ponderingText = pickPondering();
        streaming.launchCurl(req);
    }

    function _indexOfId(id) {
        for (var i = 0; i < messagesModel.count; i++)
            if (messagesModel.get(i).id === id) return i;
        return -1;
    }

    function _setMsg(id, patch) {
        var i = _indexOfId(id);
        if (i < 0) return;
        for (var k in patch) messagesModel.setProperty(i, k, patch[k]);
    }

    // ── Streaming wiring ──────────────────────────────────────────

    function _appendContent(id, delta) {
        var i = _indexOfId(id);
        if (i < 0) return;
        messagesModel.setProperty(i, "content", messagesModel.get(i).content + delta);
    }

    function _appendThinking(id, delta) {
        var i = _indexOfId(id);
        if (i < 0) return;
        messagesModel.setProperty(i, "thinking", messagesModel.get(i).thinking + delta);
    }

    // Tool call log: one entry per call, running → ok | error.
    // toolLog is a JSON string (ListModel role limitation).
    function _appendToolLog(id, toolName, phase, detail) {
        var i = _indexOfId(id);
        if (i < 0) return;
        var raw = messagesModel.get(i).toolLog;
        var log;
        try { log = raw ? JSON.parse(raw) : []; }
        catch (e) { log = []; }
        if (!Array.isArray(log)) log = [];
        var next = log.slice();
        var name = String(toolName || "");
        if (phase === "call") {
            // thinkingAt interleaves the chip into the pondering flow.
            next.push({ name: name, state: "running", detail: "",
                        startMs: Date.now(), endMs: 0,
                        thinkingAt: messagesModel.get(i).thinking.length });
        } else {
            // finalize: most recent running entry with this name
            var idx = -1;
            for (var t = next.length - 1; t >= 0; t--)
                if (next[t] && next[t].state === "running"
                    && next[t].name === name) { idx = t; break; }
            var entry = idx >= 0 ? JSON.parse(JSON.stringify(next[idx]))
                                 : { name: name, state: "running", detail: "",
                                      startMs: Date.now(), endMs: 0 };
            entry.state = phase === "error" ? "error" : "ok";
            entry.endMs = Date.now();
            var text = String(detail || "");
            entry.detail = text.length > 20000 ? text.substring(0, 20000) + "…" : text;
            if (idx >= 0) next[idx] = entry;
            else next.push(entry);
        }
        messagesModel.setProperty(i, "toolLog", JSON.stringify(next));
    }

    function _stopWatchdog() { streamWatchdog.stop(); }

    // Tool router for MCP + native tools (see AGENTS.md "Native
    // tools"). Declared before the Instantiator so the id exists when
    // MCPService delegates connect in onObjectAdded.
    Item {
        id: mcpRouter
        signal toolCallCompleted(var callId, string result)
        signal toolCallFailed(var callId, string error)
        // Connected for routing purposes when any MCP server is up OR
        // the native web tools are enabled (master on + at least one
        // per-tool on) — native execution needs no connection.
        property bool isConnected: {
            if (root.webToolsEnabled
                && (root.webSearchEnabled || root.webFetchEnabled)) return true;
            var n = 0;
            for (var k in root.mcpServiceInstances) {
                var svc = root.mcpServiceInstances[k];
                if (svc && svc.isConnected) n++;
            }
            return n > 0;
        }
        // Native tool call ids come from a negative counter so they can
        // never collide with MCPService's positive request ids.
        property int _nativeCallCounter: 0
        function getTools() {
            return root.getChatTools();
        }
        function callTool(name, args) {
            if (WebTools.isNativeTool(name)) {
                // Defense in depth: a disabled native tool never
                // reaches the model's tool list, but a stale or
                // replayed call must not execute either.
                if (!root.nativeToolEnabled(name)) return -1;
                _nativeCallCounter++;
                var nativeId = -_nativeCallCounter;
                nativeTools.execute(nativeId, name, args);
                return nativeId;
            }
            for (var i = 0; i < root.mcpServers.length; i++) {
                var inst = root.mcpServers[i];
                if (!inst || inst.enabled === false) continue;
                var svc = root._mcpServiceFor(inst.id);
                if (!svc || !svc.isConnected) continue;
                var found = false;
                var disc = inst.discovered || [];
                for (var t = 0; t < disc.length; t++) {
                    if (disc[t] && disc[t].name === name) { found = true; break; }
                }
                if (!found) continue;
                return svc.callTool(name, args);
            }
            return -1;
        }
    }

    // One MCPService per configured server. The Instantiator model is
    // the stable id list — a mcpServers-driven model would tear down
    // live connections on every array reassignment. Config changes
    // flow through _pushMcpServerConfig.
    Instantiator {
        id: mcpInstantiator
        model: root._mcpServiceIds
        delegate: MCPService {
            id: mcpSvc
            property string serverId: modelData ? String(modelData) : ""
            // Defaults: empty until onObjectAdded pushes values in.
            mcpUrl: ""
            mcpToken: ""
            onMcpConnectionStateChanged: root._onMcpConnectionStateChanged(serverId)
            onMcpToolsUpdated: root._onMcpToolsUpdated(serverId)
            // toolCallCompleted / toolCallFailed are wired at the JS
            // level in onObjectAdded (signal-to-signal connect) — the
            // inline parameterized handlers here did not deliver.
        }
        onObjectAdded: (idx, obj) => {
            var sid = String(obj.serverId || "");
            if (!sid) return;
            var map = {};
            for (var k in root.mcpServiceInstances) map[k] = root.mcpServiceInstances[k];
            map[sid] = obj;
            root.mcpServiceInstances = map;
            root._pushMcpServerConfig(sid);
            // Direct delivery into streaming (signal-to-signal
            // connects are unreliable inside Instantiator delegates).
            obj.onToolResult = function(callId, result) {
                console.warn("NEXUS_MCP_RESULT: completed id=", callId,
                             "from=", sid, "len=", (result || "").length);
                streaming._onToolCallCompleted(callId, result);
            };
            obj.onToolFailure = function(callId, err) {
                console.warn("NEXUS_MCP_RESULT: failed id=", callId,
                             "from=", sid, "err=", err);
                streaming._onToolCallFailed(callId, err);
            };
            console.warn("NEXUS_MCP_WIRE: callbacks set for id=", sid);
        }
        onObjectRemoved: (idx, obj) => {
            var sid = String(obj.serverId || "");
            if (!sid) return;
            var map = {};
            for (var k in root.mcpServiceInstances)
                if (k !== sid) map[k] = root.mcpServiceInstances[k];
            root.mcpServiceInstances = map;
        }
    }

    // Push url/token changes to a server's backing service without
    // re-creating it.
    function _pushMcpServerConfig(serverId) {
        var svc = _mcpServiceFor(serverId);
        if (!svc) return;
        var inst = getMcpServer(serverId);
        if (!inst) return;
        svc.mcpUrl = String(inst.url || "");
        svc.mcpToken = resolveMcpToken(serverId, String(inst.name || ""));
    }

    NativeToolsService {
        id: nativeTools
        // Callback assignment (not declarative bindings): mirrors how
        // MCPService delegates get wired in onObjectAdded.
        Component.onCompleted: {
            onResult = function (callId, text) {
                streaming._onToolCallCompleted(callId, text);
            };
            onError = function (callId, err) {
                streaming._onToolCallFailed(callId, err);
            };
        }
    }

    StreamingService {
        id: streaming
        timeoutSeconds: root.timeoutSeconds

        onStreamContentUpdated: (streamId, delta) => root._appendContent(streamId, delta)
        onStreamThinkingUpdated: (streamId, delta) => root._appendThinking(streamId, delta)
        onStreamToolRoundReady: (streamId, messages) => root._launch(streamId, messages)
        onToolActivity: (streamId, toolName, phase, detail) =>
            root._appendToolLog(streamId, toolName, phase, detail)

        onStreamFinalized: (streamId, stats, usage) => {
            root._stopWatchdog();
            root._setMsg(streamId, {
                state: "done", stats: stats,
                usage: usage ? JSON.stringify(usage) : ""
            });
            if (usage) root.lastUsage = usage;
            root._afterResponseProbe();
            root._onTurnFinished();
        }

        onStreamError: (streamId, message) => {
            root._stopWatchdog();
            root._setMsg(streamId, { state: "error", content: message, stats: "" });
            root._onTurnFinished();
        }

        onStreamCancelled: (streamId, stats) => {
            root._stopWatchdog();
            root._setMsg(streamId, { state: "cancelled", stats: stats });
            root._onTurnFinished();
        }
    }

    // Static router → streaming wiring (bindings to the reassignable
    // mcpService property miss signals); id guards absorb strays.
    Connections {
        target: mcpRouter
        function onToolCallCompleted(callId, result) {
            console.warn("NEXUS_MCP_RESULT: completed id=", callId,
                         "len=", (result || "").length);
            streaming._onToolCallCompleted(callId, result);
        }
        function onToolCallFailed(callId, error) {
            console.warn("NEXUS_MCP_RESULT: failed id=", callId, "err=", error);
            streaming._onToolCallFailed(callId, error);
        }
    }

    KeyringService {
        id: keyring
        // Keyring readiness lands after settings load (async probe) —
        // queue lookups for every known instance (providers + MCP
        // servers), then attempt the first MCP connect.
        onAvailableChanged: if (keyring.available) {
            root._queueAllKeyLookups()
            root._queueAllMcpKeyLookups()
            root._connectAllEnabledMcpServers()
        }
        // Stores, clears and lookup results all land here; mirroring
        // keeps sessionKeys (what resolveInstanceKey reads) in step.
        onKeysChanged: {
            root._syncFromKeyring()
            root._syncFromKeyringMcp()
            // Newly-landed MCP tokens can trigger the first connect.
            root._connectAllEnabledMcpServers()
        }
        // A rejected store already rolled back the keyring mirror —
        // drop the session-side entry too (keyStatus falls back to
        // env/none) and surface the failure under the key field.
        onKeyStoreFailed: (account) => {
            if (root.getMcpServer(account)) {
                root._setMcpSessionToken(account, "");
                var inst = root.getMcpServer(account);
                root._setMcpKeyMessage(account,
                    "Keyring rejected the token for " +
                    (inst && inst.name ? String(inst.name) : String(account)));
                return;
            }
            var pinst = root.getProvider(account);
            var name = pinst && pinst.name ? String(pinst.name) : String(account);
            root._setSessionKey(account, "");
            root._setKeyMessage(account, "Keyring rejected the key for " + name);
        }
    }

    Timer {
        id: streamWatchdog
        interval: (root.timeoutSeconds + 30) * 1000
        repeat: false
        onTriggered: {
            if (!streaming.isStreaming) return;
            var id = streaming.activeStreamId;
            var i = root._indexOfId(id);
            if (i < 0 || messagesModel.get(i).state !== "streaming") return;
            root._setMsg(id, {
                state: "error",
                content: "Request watchdog fired — the provider never responded. Check that curl is installed and the provider is reachable."
            });
            streaming.reset();
        }
    }

    // ── Model discovery ───────────────────────────────────────────

    property string _modelsStdin: ""
    // Instance the running fetch belongs to.
    property string _modelsTargetId: ""
    // Fetch target kept across the result handlers (unlike
    // _modelsTargetId, which onStreamFinished clears first) so onExited
    // can attribute a curl exit failure to the right instance.
    property string _modelsFetchId: ""
    // Per-instance discovery errors; "" / absent means success.
    property var modelsErrors: ({})

    // ── MCP (Model Context Protocol) ──────────────────────────────
    // One backing instance per server; reconnect after keyring
    // updates so new tokens connect without a settings visit.
    property var mcpServiceInstances: ({})
    property var _mcpServiceIds: []          // stable id list for Instantiator model
    property string _mcpConnectingId: ""

    function _connectMcpServer(id) {
        var inst = getMcpServer(id);
        if (!inst) return;
        if (inst.enabled === false) return;
        var svc = _mcpServiceFor(id);
        if (!svc) {
            // Instantiator delegate hasn't been added yet (or the
            // service map hasn't caught up). Surface the gate so the
            // user understands why nothing seems to happen.
            _setMcpConnectionError(id, "Service not ready — try again in a moment.");
            return;
        }
        // The backing service gets url/token via _pushMcpServerConfig;
        // we only gate on user-facing conditions here.
        if (!inst.url) {
            _setMcpConnectionError(id, "Set a URL to connect.");
            return;
        }
        if (!resolveMcpToken(id, inst.name)) {
            _setMcpConnectionError(id, "Set an auth token to connect.");
            return;
        }
        if (svc.isConnected || svc.connecting) return;
        _setMcpConnectionError(id, "");
        _mcpConnectingId = id;
        svc.connectToServer();
    }

    function _disconnectMcpServer(id) {
        var svc = _mcpServiceFor(id);
        if (svc && svc.isConnected) svc.disconnectFromServer();
    }

    function _connectAllEnabledMcpServers() {
        for (var i = 0; i < mcpServers.length; i++) {
            var inst = mcpServers[i];
            if (inst && inst.enabled !== false) _connectMcpServer(inst.id);
        }
    }

    function _onMcpConnectionStateChanged(serverId) {
        var svc = _mcpServiceFor(serverId);
        if (!svc) return;
        _setMcpConnected(serverId, !!svc.isConnected);
        if (svc.isConnected) {
            _setMcpConnectionError(serverId, "");
            // Pull the latest tool list from the service onto the
            // persisted instance through the shared merge: previously
            // disabled tools stay off; genuinely new tools default on.
            var inst = getMcpServer(serverId);
            if (inst) {
                var merged = McpTools.mergeToolSelection(
                    inst.discovered, inst.enabledTools, svc.tools || []);
                inst.discovered = merged.discovered;
                inst.enabledTools = merged.enabledTools;
                _touchMcpServers();
                _persistMcpServers();
            }
        } else {
            _setMcpConnectionError(serverId, svc.connectionError || "");
            if (_mcpConnectingId === serverId) _mcpConnectingId = "";
        }
    }

    function _onMcpToolsUpdated(serverId) {
        // Live tool-list changes (notifications/tools/list_changed) —
        // mirror them onto the instance through the shared merge (same
        // rule as connect: off-toggles persist, new tools default on).
        var svc = _mcpServiceFor(serverId);
        var inst = getMcpServer(serverId);
        if (!svc || !inst) return;
        var merged = McpTools.mergeToolSelection(
            inst.discovered, inst.enabledTools, svc.tools || []);
        inst.discovered = merged.discovered;
        inst.enabledTools = merged.enabledTools;
        _touchMcpServers();
        _persistMcpServers();
    }
    // Stems scanned from resources/icons/models — notifies so icon bindings
    // re-resolve after the startup scan lands.
    property var modelIconStems: []

    function _setModelsError(id, msg) {
        var m = {};
        for (var k in modelsErrors) m[k] = modelsErrors[k];
        if (msg) m[id] = msg;
        else delete m[id];
        modelsErrors = m;
    }

    function refreshModels(instanceId) {
        if (modelsRefreshing) return;   // one fetch at a time — no result/instance mixups
        var inst = getProvider(instanceId);
        if (!inst) return;              // unknown/missing id → no-op
        var req = Providers.buildModelsRequest(
            inst,
            Providers.resolveInstanceKey(inst, sessionKeys[inst.id] || "",
                                         function (name) { return Quickshell.env(name); }));
        if (!req) {
            _setModelsError(inst.id, "Invalid base URL — fix it in the provider settings.");
            return;
        }
        _modelsTargetId = inst.id;
        _modelsFetchId = inst.id;
        _setModelsError(inst.id, "");
        console.warn("NexusAI models: fetching for " + inst.name + " from " + inst.baseUrl);
        modelsRefreshing = true;
        _modelsStdin = req.body;
        modelsFetcher.stdinEnabled = true;   // re-arm for every fetch
        modelsFetcher.command = req.cmd;
        modelsFetcher.running = true;
    }

    Process {
        id: modelsFetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root._modelsStdin) {
                modelsFetcher.write(root._modelsStdin);
                modelsFetcher.stdinEnabled = false;
                root._modelsStdin = "";
            }
        }

        // onStreamFinished has no params — declaring (text) would
        // shadow the collector's text with undefined.
        stdout: StdioCollector {
            id: modelsOut
            onStreamFinished: {
                root.modelsRefreshing = false;
                var text = modelsOut.text;
                var parsed = StreamParser.extractHttpStatus(text);
                console.warn("NexusAI models: finished status=" + parsed.status
                    + " bodyLen=" + (parsed.body ? parsed.body.length : 0));
                var targetId = root._modelsTargetId;
                root._modelsTargetId = "";
                if (!targetId) return;
                root._handleInstanceModelsResult(targetId, parsed);
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.modelsRefreshing = false;
            console.warn("NexusAI models: exited code=" + exitCode);
            if (exitCode !== 0 && root._modelsFetchId.length > 0) {
                var id = root._modelsFetchId;
                root._modelsFetchId = "";
                if ((root.modelsErrors[id] || "").length === 0) {
                    var hint = ErrorHints.curlExitHint(exitCode);
                    root._setModelsError(id, "Connection failed (curl exit " + exitCode + ")" +
                        (hint ? "\n" + hint : ""));
                }
            }
        }

        // Same no-parameter rule: read the collector's text by id.
        stderr: StdioCollector {
            id: modelsErr
            onStreamFinished: {
                if (modelsErr.text.length > 0)
                    console.warn("NexusAI models: curl stderr = " + modelsErr.text);
            }
        }
    }

    // ── Context meter data ────────────────────────────────────────

    function _recalcContextWindow() {
        var inst = activeInstance;
        if (!inst || !activeModel) { contextWindow = 0; return; }
        if (activeIsOllama) {
            contextWindow = (useContextWindow && numCtx > 0)
                ? numCtx : ollamaContextLength;
            return;
        }
        contextWindow = ContextWindows.lookup(registryMap, inst.type,
                                              activeModel);
    }

    // Static window for the active provider from the cached
    // models.dev snapshot. Fetches in the background when the cache
    // is empty or older than a week; failures are silent (meter
    // degrades to tokens-only until the next attempt).
    function fetchContextRegistry(force) {
        if (registryFetcher.running) return;
        var week = 7 * 24 * 3600 * 1000;
        if (!force && registryFetchedAt > 0 && Date.now() - registryFetchedAt < week)
            return;
        var req = Providers.buildRegistryRequest(60);
        _registryStdin = req.body;
        registryFetcher.stdinEnabled = true;   // re-arm for every fetch
        registryFetcher.command = req.cmd;
        registryFetcher.running = true;
        console.warn("NexusAI ctx: fetching models.dev snapshot");
    }

    // Post-response probe: ollama's loaded runner reports its REAL
    // context via /api/ps — the dynamic half of the meter's window
    // (server default when the num_ctx setting is off). Other
    // providers only recalc (registry may have just loaded).
    function _afterResponseProbe() {
        if (!activeIsOllama || !activeInstance || psFetcher.running) {
            _recalcContextWindow();
            return;
        }
        var req = Providers.buildOllamaPsRequest(activeInstance, 15);
        if (!req) { _recalcContextWindow(); return; }
        _psTargetModel = activeModel;
        _psStdin = req.body;
        psFetcher.stdinEnabled = true;
        psFetcher.command = req.cmd;
        psFetcher.running = true;
    }

    property string _psStdin: ""
    property string _psTargetModel: ""

    Process {
        id: psFetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root._psStdin) {
                psFetcher.write(root._psStdin);
                psFetcher.stdinEnabled = false;
                root._psStdin = "";
            }
        }

        stdout: StdioCollector {
            id: psOut
            onStreamFinished: {
                var parsed = StreamParser.extractHttpStatus(psOut.text);
                var target = root._psTargetModel;
                root._psTargetModel = "";
                if (!target) return;
                if (parsed.status >= 200 && parsed.status < 400) {
                    root.ollamaContextLength =
                        ContextWindows.ollamaWindowFromPs(parsed.body, target);
                }
                root._recalcContextWindow();
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                console.warn("NexusAI ctx: ps probe curl exit " + exitCode);
        }

        stderr: StdioCollector {
            id: psErr
            onStreamFinished: {
                if (psErr.text.length > 0)
                    console.warn("NexusAI ctx: ps stderr = " + psErr.text);
            }
        }
    }

    property string _registryStdin: ""

    Process {
        id: registryFetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root._registryStdin) {
                registryFetcher.write(root._registryStdin);
                registryFetcher.stdinEnabled = false;
                root._registryStdin = "";
            }
        }

        stdout: StdioCollector {
            id: regOut
            onStreamFinished: {
                var parsed = StreamParser.extractHttpStatus(regOut.text);
                if (parsed.status < 200 || parsed.status >= 400) {
                    console.warn("NexusAI ctx: registry HTTP " + parsed.status);
                    return;
                }
                var slim = ContextWindows.slim(parsed.body);
                var n = Object.keys(slim).length;
                if (n === 0) {
                    console.warn("NexusAI ctx: registry snapshot unusable");
                    return;
                }
                root.registryMap = slim;
                root.registryFetchedAt = Date.now();
                root.saveSetting("contextWindows", JSON.stringify(slim));
                root.saveSetting("contextWindowsFetchedAt", root.registryFetchedAt);
                console.warn("NexusAI ctx: snapshot cached (" + n + " providers)");
                root._recalcContextWindow();
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                console.warn("NexusAI ctx: registry curl exit " + exitCode);
        }

        stderr: StdioCollector {
            id: regErr
            onStreamFinished: {
                if (regErr.text.length > 0)
                    console.warn("NexusAI ctx: registry stderr = " + regErr.text);
            }
        }
    }

    function _handleInstanceModelsResult(targetId, parsed) {
        var inst = getProvider(targetId);
        if (!inst) return;
        if (parsed.status >= 200 && parsed.status < 400) {
            var list = Providers.parseModelList(parsed.body, Providers.formatOf(inst));
            inst.discovered = list;
            // Prune ghost state for models the provider retired —
            // only on a non-empty list, so a transient empty
            // response can't wipe selections.
            if (list.length > 0) {
                var pinIds = [];
                for (var pp = 0; pp < pinnedModels.length; pp++) {
                    var prec = pinnedModels[pp];
                    if (prec && prec.providerId === targetId)
                        pinIds.push(String(prec.model));
                }
                var pruned = Providers.pruneStaleModels(inst, list, pinIds);
                if (pruned.removed.length > 0) {
                    inst.checkedModels = pruned.checkedModels;
                    inst.modelLabels = pruned.labels;
                    var pins = [];
                    for (var pq = 0; pq < pinnedModels.length; pq++) {
                        var p = pinnedModels[pq];
                        if (p && p.providerId === targetId
                            && pruned.removed.indexOf(String(p.model)) >= 0) continue;
                        pins.push(p);
                    }
                    if (pins.length !== pinnedModels.length) {
                        pinnedModels = pins;
                        saveSetting("pinnedModels", JSON.stringify(pins));
                    }
                    if (targetId === activeProviderId
                        && pruned.removed.indexOf(activeModel) >= 0) {
                        activeModel = "";
                        saveSetting("activeModel", "");
                    }
                }
            }
            _touchProviders();
            _persistProviders();
            _setModelsError(targetId, list.length > 0 ? "" : "Provider returned an empty model list.");
        } else if (parsed.status > 0) {
            var msg = "HTTP " + parsed.status;
            var hint = ErrorHints.httpErrorHint(parsed.status);
            if (hint) msg += " — " + hint;
            _setModelsError(targetId, msg);
        }
        // status === 0 (no HTTP status parsed): leave modelsError empty —
        // onStreamFinished fires before onExited, so the specific
        // curl-exit hint (7 refused, 6 DNS, 28 timeout) is attributed
        // by onExited, which only fills in when the error is still empty.
    }
}
