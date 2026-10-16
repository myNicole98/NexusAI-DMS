import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import qs.Common
import qs.Widgets
import "../lib/Markdown.js" as Markdown
import "../lib/SyntaxHighlight.js" as SyntaxHighlight
import "../lib/ModelIcons.js" as ModelIcons

Rectangle {
    id: bubble

    property var service: null
    // The owning ListView (wired by MessageList's delegate): used for
    // viewport-relative sizing and tall-code-block copy registration.
    property var listView: null
    property real viewportHeight: listView ? listView.height : 0

    // NOTE: plain (non-required) properties on purpose — MessageList binds
    // them via the delegate's `model.*` context object, and a delegate that
    // declares required properties loses context-property access (Qt 6).
    property string msgId: ""
    property string role: ""         // "user" | "assistant" | "system"
    property string content: ""
    property string thinking: ""
    property string modelUsed: ""    // logical model id (what the API got)
    // Provider the message was sent through — model renames are
    // stored per provider instance, so resolving the display label
    // needs both ids.
    property string modelProviderId: ""
    // JSON string of [{mime, data}] image attachments (user messages).
    property string attachments: "[]"
    // toolLog is a JSON string (QML ListModel does not persist JS
    // object arrays in roles). The bubble parses it on the fly via
    // the toolLogArr computed property below.
    property string toolLog: "[]"
    property string msgState: ""     // streaming | done | error | cancelled
    property string stats: ""
    property real msgTimestamp: 0    // ms epoch, from the model role

    readonly property bool isUser: role === "user"
    readonly property bool isStreaming: msgState === "streaming"
    // Pause the reveal while the panel is hidden.
    readonly property bool _winVisible:
        Window.window ? Window.window.visible : true

    // Display label for the assistant header: the user's custom
    // rename when one exists, else the logical id. Resolves live, so
    // later renames update existing bubbles too.
    readonly property string modelLabel:
        bubble.service
        ? bubble.service.modelLabel(bubble.modelProviderId, bubble.modelUsed)
        : bubble.modelUsed

    // Parsed attachments (safely [] on parse error).
    readonly property var attachmentsArr: {
        try {
            var v = JSON.parse(bubble.attachments || "[]");
            return Array.isArray(v) ? v : [];
        } catch (e) { return []; }
    }

    // theme-driven palette for markdown
    readonly property var mdColors: ({
        codeBg: Theme.surfaceContainerHigh,
        inlineCodeBg: Theme.withAlpha(Theme.surfaceText, 0.10),
        inlineCodeColor: Theme.primary,
        blockquoteBg: Theme.withAlpha(Theme.surfaceContainerHighest, 0.5),
        blockquoteBorder: Theme.outlineVariant,
        blockquoteText: Theme.surfaceVariantText,
        linkColor: Theme.primary,
        headingColor: Theme.surfaceText,
        tableHeaderBg: Theme.withAlpha(Theme.primary, 0.08),
        tableRowAltBg: Theme.withAlpha(Theme.surfaceText, 0.03),
        tableBorderColor: Theme.outlineVariant,
        syntax: ({
            comment: Theme.surfaceVariantText,
            string: Theme.success,
            number: Theme.warning,
            keyword: Theme.secondary,
            "function": Theme.info,
            type: Theme.tertiary
        })
    })

    // Small icon button used in message footers and the code-block
    // sticky bar. Rest color follows surfaceVariantText; hover shifts
    // to the accent (Theme.primary). HoverHandler + cursorShape — the
    // exact recipe of the working bottom-bar chips; the base must be
    // a Rectangle like those chips (plain Item ignored the cursor).
    component HoverIcon : Rectangle {
        id: hov
        color: "transparent"
        property string iconName: ""
        property int iconSize: 18
        property string iconColor: Theme.surfaceVariantText
        signal clicked()
        property bool _hovered: false
        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: parent._hovered = hovered
        }
        TapHandler { onTapped: hov.clicked() }
        DankIcon {
            anchors.centerIn: parent
            name: hov.iconName
            size: hov.iconSize
            color: hov._hovered ? Theme.primary : hov.iconColor
            Behavior on color { ColorAnimation { duration: 180 } }
        }
        // Touch target matches the icon; the glyph paints at
        // iconSize inside.
        implicitWidth: 18
        implicitHeight: 18
    }

    function _highlight(code, lang) {
        return SyntaxHighlight.highlightCode(code, lang, mdColors.syntax);
    }

    // ── Chronological flow (interleaved pondering) ────────────────
    // The flow role records the response structure in production
    // order: k = thinking box, x = text segment ([a,b) offsets into
    // the thinking/content strings), c = tool chip (toolLog index).
    // Each k renders its own collapsible pondering box; a chip
    // directly following a box renders INSIDE it, otherwise inline.
    // Messages without a flow (old chats) synthesize the legacy
    // layout: one box with chips interleaved by thinkingAt, then the
    // whole content.
    property string flow: "[]"

    readonly property var flowArr: {
        try { var v = JSON.parse(bubble.flow || "[]");
              return Array.isArray(v) ? v : []; }
        catch (e) { return []; }
    }

    readonly property var effectiveFlow: {
        if (flowArr.length > 0) return flowArr;
        // User rows render through the dedicated user bubble — no
        // flow entries (would double-render the text).
        if (bubble.isUser) return [];
        var segs = [];
        var log = bubble.toolLogArr;
        var prev = 0;
        for (var i = 0; i < log.length; i++) {
            var e = log[i];
            var at = e && e.thinkingAt ? e.thinkingAt : 0;
            if (at > thinking.length) at = thinking.length;
            if (at < prev) at = prev;
            if (at > prev) segs.push({ t: "k", a: prev, b: at, ms: 0 });
            segs.push({ t: "c", i: i });
            prev = at;
        }
        if (thinking.length > prev)
            segs.push({ t: "k", a: prev, b: thinking.length, ms: 0 });
        if (segs.length === 0 && thinking.length > 0)
            segs.push({ t: "k", a: 0, b: thinking.length, ms: 0 });
        if (content.length > 0)
            segs.push({ t: "x", a: 0, b: content.length });
        return segs;
    }

    // Render model: chips right after a box are absorbed into it, and
    // the LAST entry of an active stream is live — its range extends
    // to the current string lengths (the service persists open
    // entries with a stale b).
    readonly property var flowRender: {
        var src = bubble.effectiveFlow;
        var streaming = bubble.msgState === "streaming";
        var out = [];
        for (var i = 0; i < src.length; i++) {
            var e = src[i];
            if (!e) continue;
            var live = streaming && i === src.length - 1;
            if (e.t === "k") {
                var box = { t: "k", a: e.a,
                            b: live ? bubble.thinking.length : e.b,
                            ms: e.ms || 0, chips: [], live: live,
                            srcIdx: i };
                var j = i + 1;
                var busy = false;
                while (j < src.length && src[j] && src[j].t === "c") {
                    box.chips.push(src[j].i);
                    var te = bubble.toolLogArr[src[j].i];
                    if (te && te.state === "running") busy = true;
                    j++;
                }
                // A box whose tool is still executing is NOT done:
                // stays expanded ("Pondering…") until the call returns.
                box.busy = busy;
                out.push(box);
                i = j - 1;
            } else if (e.t === "x") {
                out.push({ t: "x", a: e.a,
                           b: live ? bubble.content.length : e.b,
                           live: live });
            } else if (e.t === "c") {
                out.push({ t: "c", i: e.i, live: live });
            }
        }
        return out;
    }

    // Settled-render cache: closed boxes/segments re-evaluate their
    // bindings whenever the flow rebuilds; exact-text caching keeps
    // those re-renders free. Cleared on theme change (colors are
    // baked into the html).
    property var _segCache: ({ keys: [], htmls: [] })

    function _cachedSegHtml(text) {
        if (!text) return "";
        var c = _segCache;
        for (var i = 0; i < c.keys.length; i++)
            if (c.keys[i] === text) return c.htmls[i];
        var html = Markdown.markdownToHtml(text, mdColors, _highlight);
        c.keys.push(text);
        c.htmls.push(html);
        if (c.keys.length > 40) { c.keys.shift(); c.htmls.shift(); }
        return html;
    }

    function staticThinkHtml(text) {
        return _cachedSegHtml(text);
    }

    // Closed flow entries render from the final strings.
    function entryThinkHtml(a, b) {
        return _cachedSegHtml(thinking.substring(a, b));
    }

    function entrySegs(a, b) {
        var segs = Markdown.splitCodeSegments(content.substring(a, b));
        for (var i = 0; i < segs.length; i++)
            if (segs[i].type === "text")
                segs[i].html = _cachedSegHtml(segs[i].text);
        return segs;
    }

    // Per-box expansion state (srcIdx → bool). Default: the live box
    // is open, closed boxes collapsed; a manual toggle sticks.
    property var _openBoxes: ({})

    function isBoxOpen(idx, live) {
        if (_openBoxes[idx] === undefined) return live;
        return _openBoxes[idx];
    }

    function toggleBox(idx, live) {
        var m = Object.assign({}, _openBoxes);
        m[idx] = !isBoxOpen(idx, live);
        _openBoxes = m;
    }

    // Per-tool-entry expansion state (index in toolLog → bool).
    // Reassigned on toggle so var-property bindings re-evaluate.
    property var _expandedTools: ({})

    // Parsed toolLog (the role is a JSON string because QML
    // ListModel can't store JS object arrays in roles). Re-evaluates
    // when toolLog changes; safely returns [] on parse error.
    readonly property var toolLogArr: {
        try { var v = JSON.parse(bubble.toolLog || "[]");
              return Array.isArray(v) ? v : []; }
        catch (e) { return []; }
    }

    function isToolExpanded(idx) {
        return !!_expandedTools[idx];
    }

    function toggleToolExpand(idx) {
        var m = Object.assign({}, _expandedTools);
        m[idx] = !m[idx];
        _expandedTools = m;
    }

    // Pretty-print a tool's raw detail: recursively unescape nested
    // JSON strings, re-stringify with 2-space indent; raw text falls
    // through. Never truncated (lives in a collapsible block).
    function formatToolDetail(raw) {
        if (!raw) return "";
        var text = String(raw);
        function unescapeStrings(v) {
            if (typeof v === "string") {
                try {
                    var inner = JSON.parse(v);
                    if (inner && typeof inner === "object")
                        return unescapeStrings(inner);
                } catch (e) { /* not JSON, keep as-is */ }
                return v;
            }
            if (Array.isArray(v)) {
                var out = [];
                for (var i = 0; i < v.length; i++)
                    out.push(unescapeStrings(v[i]));
                return out;
            }
            if (v && typeof v === "object") {
                var r = {};
                for (var k in v)
                    if (Object.prototype.hasOwnProperty.call(v, k))
                        r[k] = unescapeStrings(v[k]);
                return r;
            }
            return v;
        }
        try {
            var parsed = JSON.parse(text);
            var unescaped = unescapeStrings(parsed);
            text = JSON.stringify(unescaped, null, 2);
        } catch (e) { /* not JSON, show as-is */ }
        if (text.length > 300)
            text = text.replace(/([^\n]{300})/g, "$1\n");
        return text;
    }

    function ponderedLabel(entry) {
        var ms = entry ? (entry.ms || 0) : 0;
        if (ms < 5000) return "Pondered briefly";
        return "Pondered for " + Math.round(ms / 1000) + " seconds";
    }

    // ── Segmented body rendering + batch reveal ───────────────────
    // Output flushes in discrete batches, each tinted via
    // Markdown.spliceIntoLastBlock and brightening to full color over
    // fadeMs (span-alpha re-render — the only way Qt rich text allows).
    // Fragments are cached at batch landing; frames just rewrap.
    property string renderedThinkingHtml: ""
    property var segments: []
    property string shownText: ""
    // Cap new chars per flush: giant stall-bursts would throw the
    // ListView's anchor stale (flicker + dead follow).
    readonly property int flushChars: 300
    property string shownThinking: ""

    readonly property int fadeMs: 240

    // fade-span caches for the batches currently brightening: the
    // content body (last text segment) and the thinking body. Empty
    // tail = no active fade for that region.
    property string _fadePrefix: ""
    property string _fadeTail: ""
    property string _fadeSuffix: ""
    property real _fadeStartMs: 0
    property string _thinkFadePrefix: ""
    property string _thinkFadeTail: ""
    property string _thinkFadeSuffix: ""
    property real _thinkFadeStartMs: 0

    function _fadeColor(k) {
        // dim → full, ease-out (surfaceText alpha)
        return Theme.withAlpha(Theme.surfaceText,
                               0.45 + 0.55 * (k * (2 - k)));
    }

    function _thinkFadeColor(k) {
        // thinking text settles at surfaceTextMedium (0.7 alpha);
        // start bright enough to stay readable while scrolling in
        return Theme.withAlpha(Theme.surfaceText,
                               0.3 + 0.4 * (k * (2 - k)));
    }

    // Splits rendered html at the batch start and returns the initial
    // faded html; skips the fade when no safe anchor exists.
    function _fadeSplit(cache, text, batchStart) {
        var ph = "\x01F\x01";   // 3 chars — suffix must cut at ph.length
        var i = batchStart;
        if (i <= 0) i = 0;
        while (i > 0 && !/\s/.test(text[i - 1])) i--;
        var head = Markdown.markdownToHtml(text.substring(0, i),
                                           mdColors, _highlight);
        if (!head) return { prefix: "", tail: "", suffix: "", html: head };
        var tail = Markdown.escapeHtml(text.substring(i));
        var spliced = Markdown.spliceIntoLastBlock(head, ph);
        var cut = spliced.indexOf(ph);
        if (cut < 0) return { prefix: "", tail: "", suffix: "", html: head };
        var parts = {
            prefix: spliced.substring(0, cut),
            tail: tail,
            suffix: spliced.substring(cut + ph.length),
            html: ""
        };
        parts.html = parts.prefix
            + '<span style="color: ' + cache(0) + ';">'
            + tail + "</span>" + parts.suffix;
        return parts;
    }

    // fadeFrom: offset where the newest batch began (-1 = settled),
    // relative to the LIVE flow entry. Streaming renders at most
    // shownText/shownThinking (advanced ≤flushChars/tick).
    function flushBatches(contentFrom, thinkFrom) {
        var streaming = msgState === "streaming";
        var live = (flowRender && flowRender.length > 0)
            ? flowRender[flowRender.length - 1] : null;
        segments = [];
        renderedThinkingHtml = "";
        if (isUser || !live) return;
        if (live.t === "x") {
            var end = streaming
                ? Math.min(shownText.length, content.length) : live.b;
            if (end <= live.a) return;
            var renderText = content.substring(live.a, end);
            if (streaming && contentFrom >= 0
                    && contentFrom - live.a < renderText.length) {
                var rel = contentFrom - live.a;
                if (rel < 0) rel = 0;
                var segs = Markdown.splitCodeSegments(renderText);
                for (var i = 0; i < segs.length; i++) {
                    if (segs[i].type !== "text") continue;
                    var r = -1;
                    if (i === segs.length - 1) {
                        r = rel - (renderText.length - segs[i].text.length);
                        if (r < 0) r = 0;
                        if (r >= segs[i].text.length) r = -1;
                    }
                    if (r >= 0) {
                        var parts = _fadeSplit(_fadeColor, segs[i].text, r);
                        _fadePrefix = parts.prefix;
                        _fadeTail = parts.tail;
                        _fadeSuffix = parts.suffix;
                        segs[i].html = parts.html;
                    } else {
                        segs[i].html = Markdown.markdownToHtml(
                            segs[i].text, mdColors, _highlight);
                    }
                }
                segments = segs;
            } else {
                segments = buildSegments(renderText);
            }
        } else if (live.t === "k") {
            var endT = streaming
                ? Math.min(shownThinking.length, thinking.length) : live.b;
            if (endT <= live.a) return;
            var renderThink = thinking.substring(live.a, endT);
            if (streaming && thinkFrom >= 0
                    && thinkFrom - live.a < renderThink.length) {
                var relT = thinkFrom - live.a;
                if (relT < 0) relT = 0;
                var tp = _fadeSplit(_thinkFadeColor, renderThink, relT);
                _thinkFadePrefix = tp.prefix;
                _thinkFadeTail = tp.tail;
                _thinkFadeSuffix = tp.suffix;
                renderedThinkingHtml = tp.html;
            } else {
                renderedThinkingHtml = Markdown.markdownToHtml(
                    renderThink, mdColors, _highlight);
            }
        }
    }

    function buildSegments(text) {
        var segs = Markdown.splitCodeSegments(text);
        for (var i = 0; i < segs.length; i++)
            if (segs[i].type === "text")
                segs[i].html = Markdown.markdownToHtml(
                    segs[i].text, mdColors, _highlight);
        return segs;
    }

    // Read msgState directly, never the derived isStreaming binding —
    // inside change handlers QML serves stale dependent values.
    function revealTick() {
        if (isUser || msgState !== "streaming") return;
        if (shownText.length >= content.length
                && shownThinking.length >= thinking.length) return;
        var prevC = shownText.length;
        var prevT = shownThinking.length;
        // render cap: ≤flushChars new chars enter the layout per tick
        shownText = content.substring(
            0, Math.min(content.length, shownText.length + flushChars));
        shownThinking = thinking.substring(
            0, Math.min(thinking.length, shownThinking.length + flushChars));
        flushBatches(prevC, prevT);
        _fadeStartMs = Date.now();
        _thinkFadeStartMs = Date.now();
        fadeTimer.start();
    }

    // One brightening frame per active region; stops itself when both
    // fades complete (before the next batch lands).
    function fadeFrame() {
        if (msgState !== "streaming") { fadeTimer.stop(); return; }
        var now = Date.now();
        var active = false;
        if (_fadeTail.length > 0) {
            var k = Math.min(1, (now - _fadeStartMs) / fadeMs);
            var html = _fadePrefix
                + '<span style="color: ' + _fadeColor(k) + ';">'
                + _fadeTail + "</span>" + _fadeSuffix;
            if (k >= 1) {
                html = _fadePrefix + _fadeTail + _fadeSuffix;
                _fadeTail = "";
            } else active = true;
            var segs = segments.slice();
            var last = segs[segs.length - 1];
            var copy = {};
            for (var key in last) copy[key] = last[key];
            copy.html = html;
            segs[segs.length - 1] = copy;
            segments = segs;
        }
        if (_thinkFadeTail.length > 0) {
            var kt = Math.min(1, (now - _thinkFadeStartMs) / fadeMs);
            renderedThinkingHtml = _thinkFadePrefix
                + '<span style="color: ' + _thinkFadeColor(kt) + ';">'
                + _thinkFadeTail + "</span>" + _thinkFadeSuffix;
            if (kt >= 1) {
                renderedThinkingHtml = _thinkFadePrefix + _thinkFadeTail
                    + _thinkFadeSuffix;
                _thinkFadeTail = "";
            } else active = true;
        }
        if (!active) fadeTimer.stop();
    }

    onMsgStateChanged: {
        if (msgState === "streaming") {
            shownText = "";
            shownThinking = "";
        } else {
            shownText = content;
            shownThinking = thinking;
        }
        fadeTimer.stop();
        flushBatches(-1, -1);
    }
    onContentChanged: {
        if (msgState !== "streaming") flushBatches(-1, -1);
    }
    onThinkingChanged: {
        if (msgState !== "streaming") flushBatches(-1, -1);
    }
    onMdColorsChanged: {   // live theme switch → recolor completed bubbles
        _segCache = ({ keys: [], htmls: [] });   // html bakes theme colors
        shownText = content;
        shownThinking = thinking;
        flushBatches(-1, -1);
    }
    Component.onCompleted: {
        flushBatches(-1, -1);
        _maybePlayEntrance();
    }

    // Batch ticker: one reveal per interval. The final render is
    // synchronous via onMsgStateChanged, never the timer. Never for
    // user rows: they are plain text and terminal from creation.
    Timer {
        id: renderTimer
        interval: 20
        repeat: true
        running: bubble.isStreaming && !bubble.isUser && bubble._winVisible
        onTriggered: bubble.revealTick()
    }

    // Brightening frames while a batch fades in.
    Timer {
        id: fadeTimer
        interval: 20
        repeat: true
        running: false
        onTriggered: bubble.fadeFrame()
    }

    // User: hug-width bubble; assistant: bare content on the panel.
    // Root stays full-width/transparent so footers align below.
    readonly property real maxBubbleWidth: parent ? parent.width * 2 / 3 : 300

    width: parent ? parent.width : 300
    // Rectangle defaults to solid white — must stay explicitly
    // transparent; all painted surfaces live in the children.
    color: "transparent"
    implicitHeight: layout.implicitHeight + 20

    // ── Entrance animation (fresh user messages) ──────────────────
    // Fade + slide-up only for freshly appended delegates; recreated
    // ones stay static. Imperative writes are safe here (no opacity
    // binding on root; Translate never disturbs ListView layout).
    transform: Translate { id: entranceShift }

    ParallelAnimation {
        id: entranceAnim
        NumberAnimation {
            target: bubble; property: "opacity"
            from: 0; to: 1
            duration: 300; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: entranceShift; property: "y"
            from: 12; to: 0
            duration: 300; easing.type: Easing.OutCubic
        }
    }

    function _maybePlayEntrance() {
        if (!isUser) return;
        if (!(msgTimestamp > 0) || Date.now() - msgTimestamp > 2000) return;
        bubble.opacity = 0;
        entranceShift.y = 12;
        entranceAnim.start();
    }

    ColumnLayout {
        id: layout
        anchors { left: parent.left; right: parent.right; top: parent.top }
        anchors.margins: 10
        spacing: 6

        // Model label (custom name if renamed) + brand logo keyed off
        // the raw model id.
        Row {
            visible: !bubble.isUser && bubble.modelUsed.length > 0
            spacing: 5

            BrandIcon {
                anchors.verticalCenter: parent.verticalCenter
                size: 13
                stem: ModelIcons.iconForModel(bubble.modelUsed, "")
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: bubble.modelLabel
                color: Theme.surfaceVariantText
                font.pixelSize: 11
            }
        }

        // Chronological flow: pondering boxes, text segments and
        // tool chips in the order the model produced them. Count-based
        // Repeater — delegates are reused across ticks.
        Repeater {
            model: bubble.flowRender ? bubble.flowRender.length : 0

            delegate: Loader {
                id: flowLoader
                required property int index
                readonly property var entry:
                    (bubble.flowRender && index < bubble.flowRender.length)
                    ? bubble.flowRender[index] : null
                readonly property var chipEntry:
                    entry && entry.t === "c"
                        && entry.i < bubble.toolLogArr.length
                    ? bubble.toolLogArr[entry.i] : null
                Layout.fillWidth: true
                sourceComponent:
                    !entry ? textEntryComp
                    : entry.t === "k" ? ponderBoxComp
                    : entry.t === "c" ? toolChipComp
                    : textEntryComp
                onLoaded: {
                    if (entry && entry.t === "c") {
                        flowLoader.item.index = Qt.binding(
                            function () { return flowLoader.entry.i; });
                        flowLoader.item.entry = Qt.binding(
                            function () { return flowLoader.chipEntry; });
                    } else {
                        flowLoader.item.entry = Qt.binding(
                            function () { return flowLoader.entry; });
                    }
                }
            }
        }

        // Streaming indicator before first content: a plain status
        // label breathing toward the accent — same 750 ms cadence as
        // the tool chip's in-flight pulse.
        Text {
            id: promptRow
            visible: isStreaming && bubble.flowRender.length === 0
            text: "Processing prompt"
            font.pixelSize: 11

            // 0 → 1 → 0 while the label shows; lerps the color toward
            // the accent (k = 0.55, matching breatheColor on the chips).
            property real breathe: 0
            SequentialAnimation on breathe {
                running: promptRow.visible
                loops: Animation.Infinite
                NumberAnimation {
                    from: 0; to: 1; duration: 750
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    from: 1; to: 0; duration: 750
                    easing.type: Easing.InOutSine
                }
            }
            color: {
                var k = breathe * 0.55;
                var base = Theme.surfaceVariantText;
                var accent = Theme.primary;
                return Qt.rgba(
                    base.r + (accent.r - base.r) * k,
                    base.g + (accent.g - base.g) * k,
                    base.b + (accent.b - base.b) * k,
                    1);
            }
        }

        // User bubble: right-aligned, fades during edit; attachments
        // render as thumbnails above the text.
        Rectangle {
            id: userBubble
            visible: isUser
            Layout.alignment: Qt.AlignRight
            readonly property bool hasImages: bubble.attachmentsArr.length > 0
            // Hidden no-wrap Text measures the natural line width —
            // the TextArea's own implicitWidth is circular and
            // collapses under Qt's binding loop guard.
            Text {
                id: userTextMeasure
                visible: false
                text: bubble.content
                font.pixelSize: 13
            }
            Layout.preferredWidth: Math.min(
                Math.max(userTextMeasure.implicitWidth,
                         thumbRow.implicitWidth) + 22,
                bubble.maxBubbleWidth)
            Layout.maximumWidth: bubble.maxBubbleWidth
            implicitHeight: userCol.implicitHeight + 20
            radius: 16
            color: Theme.surfaceContainerHighest
            opacity: bubble.service && bubble.msgId.length > 0
                     && bubble.service.editingMessageId === bubble.msgId
                     ? 0.35 : 1
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Column {
                id: userCol
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 10
                spacing: 8

                Row {
                    id: thumbRow
                    visible: userBubble.hasImages
                    spacing: 6

                    Repeater {
                        model: bubble.attachmentsArr.length

                        delegate: Rectangle {
                            required property int index
                            readonly property var entry:
                                bubble.attachmentsArr[index] || null
                            width: 120
                            height: 84
                            radius: 6
                            color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.6)
                            clip: true

                            Image {
                                anchors.fill: parent
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                visible: entry && !entry.stripped
                                         && (entry.data || "").length > 0
                                source: visible
                                    ? "data:" + entry.mime + ";base64," + entry.data
                                    : ""
                            }

                            // Persisted chats strip base64 payloads —
                            // show a placeholder chip instead.
                            DankIcon {
                                anchors.centerIn: parent
                                name: "image"
                                size: 22
                                visible: entry && entry.stripped
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                TextArea {
                    id: userText
                    width: parent.width
                    text: bubble.content
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.Wrap
                    readOnly: true
                    selectByMouse: true
                    persistentSelection: true
                    color: Theme.surfaceText
                    font.pixelSize: 13
                    background: null
                    leftPadding: 0
                    rightPadding: 0
                    topPadding: 0
                    bottomPadding: 0
                }
            }
        }

        // Footer: assistant rows hug left, user rows hug right; the
        // fillers carry the slack width.
        RowLayout {
            Layout.fillWidth: true
            visible: !isStreaming && (bubble.content.length > 0 || stats.length > 0)
            spacing: 8

            Item {
                Layout.fillWidth: true
                visible: isUser
            }

            // User: copy + edit (edit hands the text to the composer).
            HoverIcon {
                visible: isUser && bubble.content.length > 0
                iconName: "content_copy"
                onClicked: Quickshell.execDetached(
                    ["dms", "cl", "copy", bubble.content])
            }
            HoverIcon {
                visible: isUser
                iconName: "edit"
                onClicked: if (bubble.service && bubble.msgId.length > 0)
                    bubble.service.beginEditUserMessage(bubble.msgId)
            }

            // Assistant: regenerate (hidden on error — the Retry
            // button covers that state) + copy.
            HoverIcon {
                visible: !isUser && msgState !== "error"
                iconName: "restart_alt"
                onClicked: if (bubble.service && bubble.msgId.length > 0)
                    bubble.service.regenerateMessage(bubble.msgId)
            }
            HoverIcon {
                visible: !isUser && bubble.content.length > 0
                iconName: "content_copy"
                onClicked: Quickshell.execDetached(
                    ["dms", "cl", "copy", bubble.content])
            }

            Text {
                visible: stats.length > 0
                text: stats
                color: Theme.surfaceVariantText
                font.pixelSize: 11
            }

            Item {
                Layout.fillWidth: true
                visible: !isUser
            }
        }

        // Retry affordance for errors
        DankButton {
            visible: msgState === "error"
            text: "Retry"
            iconName: "refresh"
            buttonHeight: 32
            onClicked: if (bubble.service) bubble.service.retryLast()
        }
    }

    // Markdown text segment (the proven themed rich-text TextArea)
    Component {
        id: textSegComp
        TextArea {
            property var seg: null
            readOnly: true
            textFormat: TextEdit.RichText
            wrapMode: TextEdit.Wrap
            text: seg ? seg.html : ""
            color: bubble.msgState === "error" ? Theme.error : Theme.surfaceText
            background: null
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            onLinkActivated: (link) => {
                if (/^https?:\/\//i.test(link)) Qt.openUrlExternally(link);
            }
        }
    }

    // Code segment: a sticky language bar (language + copy) that is
    // ALWAYS visible — it sticks to the viewport top while a tall
    // block is scrolled, with a touch of contrast so code slides
    // under it legibly — and the code below it.
    Component {
        id: codeSegComp
        Rectangle {
            id: codeRect
            property var seg: null
            readonly property string rawCode: seg ? seg.code : ""
            readonly property bool tall: bubble.viewportHeight > 0
                && height >= bubble.viewportHeight - 40
            readonly property int headerH: 34
            // block top in viewport coords: fully REACTIVE (delegate
            // y + loader y − contentY) — a mapToItem ticker would lag
            // the scroll by a frame and make the bar bounce
            readonly property real _viewY: 10 + parent.y
                + (bubble.parent ? bubble.parent.y : 0)
                - (bubble.listView ? bubble.listView.contentY : 0)
            // the bar sticks to the viewport top while the block is
            // scrolled, clamped inside the block
            readonly property real headerY:
                Math.max(0, Math.min(height - headerH, -_viewY))

            color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.75)
            radius: 8
            implicitHeight: codeCol.implicitHeight + headerH + 10
            clip: true

            ColumnLayout {
                id: codeCol
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 6
                anchors.topMargin: headerH + 8
                spacing: 4

                TextArea {
                    Layout.fillWidth: true
                    readOnly: true
                    textFormat: TextEdit.RichText
                    wrapMode: TextEdit.Wrap
                    // RichText collapses literal newlines; the pre-wrap
                    // block preserves them and still wraps long lines
                    // (same pattern as Markdown.js fenced blocks).
                    text: codeRect.seg
                        ? "<pre style=\"white-space: pre-wrap; margin: 0;\">"
                          + SyntaxHighlight.highlightCode(
                              codeRect.seg.code, codeRect.seg.lang,
                              bubble.mdColors.syntax) + "</pre>"
                        : ""
                    color: Theme.surfaceText
                    font.family: "monospace"
                    font.pixelSize: 12
                    background: null
                    leftPadding: 0
                    rightPadding: 0
                    topPadding: 0
                    bottomPadding: 0
                }
            }

            // Sticky language bar: declared after the code so it sits
            // on top while code slides under it.
            Rectangle {
                id: langBar
                x: 0
                y: codeRect.headerY
                width: parent.width
                height: codeRect.headerH
                radius: 8
                color: Theme.surfaceContainerHigh

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 4

                    Text {
                        visible: codeRect.seg && codeRect.seg.lang.length > 0
                        text: codeRect.seg ? codeRect.seg.lang : ""
                        color: Theme.surfaceVariantText
                        font.pixelSize: 13
                    }
                    Item { Layout.fillWidth: true }
                    HoverIcon {
                        iconName: "content_copy"
                        iconColor: Theme.surfaceVariantText
                        onClicked: Quickshell.execDetached(
                            ["dms", "cl", "copy", codeRect.rawCode])
                    }
                }
            }
        }
    }


    // One pondering box per think entry: collapsible header chip
    // (live = "Pondering…", closed = stamped duration), capped
    // auto-scrolling content, and the tool chips that were issued
    // straight out of this thinking phase.
    Component {
        id: ponderBoxComp
        ColumnLayout {
            id: ponderPane
            property var entry: null
            readonly property bool live: entry ? entry.live : false
            readonly property bool busy: entry ? entry.busy : false
            readonly property int srcIdx: entry && entry.srcIdx !== undefined
                ? entry.srcIdx : -1
            readonly property bool expanded:
                bubble.isBoxOpen(srcIdx, live || busy)
            spacing: 4

            Rectangle {
                id: ponderHeader
                Layout.fillWidth: false
                implicitWidth: pHeaderRow.implicitWidth + 16
                implicitHeight: pHeaderRow.implicitHeight + 8
                radius: 8
                color: pHeaderHover.hovered
                    ? Theme.withAlpha(Theme.primary, 0.14) : "transparent"
                Behavior on color { ColorAnimation { duration: 220 } }

                HoverHandler {
                    id: pHeaderHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: bubble.toggleBox(ponderPane.srcIdx,
                                               ponderPane.live)
                }

                RowLayout {
                    id: pHeaderRow
                    anchors.centerIn: parent
                    spacing: 6

                    Item {
                        width: 16; height: 16
                        DankIcon {
                            anchors.centerIn: parent
                            name: "emoji_objects"
                            size: 16
                            color: Theme.surfaceVariantText
                            opacity: pHeaderHover.hovered ? 0 : 1
                            Behavior on opacity {
                                NumberAnimation { duration: 220 }
                            }
                        }
                        DankIcon {
                            anchors.centerIn: parent
                            name: "expand_more"
                            size: 16
                            color: Theme.primary
                            opacity: pHeaderHover.hovered ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation { duration: 220 }
                            }
                        }
                    }

                    Text {
                        text: ponderPane.live || ponderPane.busy
                            ? "Pondering..."
                            : (ponderPane.expanded
                               ? "Hide thinking"
                               : bubble.ponderedLabel(ponderPane.entry))
                        color: pHeaderHover.hovered
                            ? Theme.primary : Theme.surfaceVariantText
                        font.pixelSize: 11
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }
                }
            }

            // Box content: 220px cap + smoothed height; auto-scroll
            // pinned to the bottom while this box is the live one,
            // free after. Column so merged tool chips render inside
            // the collapsible area.
            Flickable {
                id: pFlick
                visible: ponderPane.expanded
                Layout.fillWidth: true
                Layout.preferredHeight: pSmoothH
                readonly property int maxH: 220
                property real pSmoothH: Math.min(contentHeight, maxH)
                Behavior on pSmoothH {
                    NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
                }
                contentHeight: pContent.implicitHeight
                clip: true

                property bool pinned: true

                function chase() {
                    if (!pinned || !ponderPane.live) return;
                    if (height <= 0) return;
                    // Scroll ONLY on real overflow of the capped box.
                    // While the box is still growing, growth itself
                    // reveals the new text — chasing here would scroll
                    // content that the height animation is about to
                    // reveal (the per-flush nudge).
                    if (contentHeight - maxH < 10) return;
                    var target = contentHeight - maxH;
                    // huge backlog: snap (safe — plain Flickable has no
                    // item-anchor machinery to fight)
                    if (target - contentY > height) {
                        contentY = target;
                        return;
                    }
                    if (Math.abs(contentY - target) < 0.5) return;
                    pChaseAnim.to = target;
                    pChaseAnim.restart();
                }

                function unpin() {
                    pinned = false;
                    pChaseAnim.stop();
                }

                onContentHeightChanged: chase()

                onDraggingChanged: if (dragging) unpin()
                onFlickingChanged: if (flicking) unpin()
                onContentYChanged: {
                    // the chase only ever increases contentY; any
                    // decrease is the user scrolling up
                    if (contentY < pFlick._lastY - 2) unpin();
                    pFlick._lastY = contentY;
                    if (atYEnd) pinned = true;
                }
                property real _lastY: 0

                NumberAnimation {
                    id: pChaseAnim
                    target: pFlick
                    property: "contentY"
                    // Linear conveyor, same rationale as the message
                    // list follow: eased restarts spike per flush.
                    duration: 200
                    easing.type: Easing.Linear
                }

                WheelHandler {
                    onWheel: (event) => {
                        pFlick.unpin();
                        event.accepted = false;
                    }
                }

                Column {
                    id: pContent
                    width: pFlick.width
                    spacing: 8

                    // This box's thinking text: the live box streams
                    // through the fade machinery; closed boxes render
                    // cached static markdown.
                    TextArea {
                        width: pContent.width
                        readOnly: true
                        textFormat: TextEdit.RichText
                        wrapMode: TextEdit.Wrap
                        text: ponderPane.live
                            ? bubble.renderedThinkingHtml
                            : bubble.entryThinkHtml(
                                  ponderPane.entry ? ponderPane.entry.a : 0,
                                  ponderPane.entry ? ponderPane.entry.b : 0)
                        color: Theme.surfaceTextMedium
                        font.pixelSize: 12
                        background: null
                        leftPadding: 0
                        rightPadding: 0
                        topPadding: 0
                        bottomPadding: 0
                    }

                    // Tool chips issued straight out of this thinking
                    // phase — rendered inside the box.
                    Repeater {
                        model: ponderPane.entry
                            ? ponderPane.entry.chips.length : 0

                        delegate: Loader {
                            id: boxChipLoader
                            required property int index
                            readonly property int chipIdx:
                                (ponderPane.entry
                                 && index < ponderPane.entry.chips.length)
                                ? ponderPane.entry.chips[index] : 0
                            readonly property var chipEntry:
                                (chipIdx >= 0
                                 && chipIdx < bubble.toolLogArr.length)
                                ? bubble.toolLogArr[chipIdx] : null
                            width: pContent.width
                            sourceComponent: toolChipComp
                            onLoaded: {
                                boxChipLoader.item.index = Qt.binding(
                                    function () { return boxChipLoader.chipIdx; });
                                boxChipLoader.item.entry = Qt.binding(
                                    function () { return boxChipLoader.chipEntry; });
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: toolChipComp

        ColumnLayout {
            id: toolEntry
            property int index: 0
            property var entry: null
            readonly property bool expanded: bubble.isToolExpanded(index)
                readonly property bool hasDetail:
                    entry && entry.detail && entry.detail.length > 0
                // Sub-second calls collapse to "in less than a
                // second" so the chip never shows 0 seconds.
                readonly property string chipLabel: {
                    var e = toolEntry.entry;
                    var name = e && e.name ? " (" + e.name + ")" : "";
                    if (!e || e.state === "running")
                        return "Calling Tool" + name;
                    var ms = Math.max(0,
                                      (e.endMs || 0) - (e.startMs || 0));
                    if (ms < 1000)
                        return "Tool called in less than a second"
                            + name;
                    return "Tool called for "
                        + Math.round(ms / 1000) + " seconds" + name;
                }

                Layout.fillWidth: true
                spacing: 2

                // Tool chip: generic label (real name is in the
                // detail); hover crossfades the icon to a
                // chevron; accent "breathing" while in flight.
                Rectangle {
                    id: toolChip
                    Layout.fillWidth: false
                    implicitWidth: toolChipRow.implicitWidth + 16
                    implicitHeight: toolChipRow.implicitHeight + 8
                    radius: 8
                    color: chipHover.hovered
                        ? Theme.withAlpha(Theme.primary, 0.14) : "transparent"
                    Behavior on color { ColorAnimation { duration: 220 } }

                    // 0 → 1 → 0, only while the call is in
                    // flight. Lerps text/icon color toward
                    // the accent for the "breathing" effect.
                    property real breathe: 0
                    SequentialAnimation on breathe {
                        running: toolEntry.entry
                            && toolEntry.entry.state === "running"
                        loops: Animation.Infinite
                        NumberAnimation {
                            from: 0; to: 1; duration: 750
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            from: 1; to: 0; duration: 750
                            easing.type: Easing.InOutSine
                        }
                    }

                    function breatheColor(base, accent) {
                        var k = toolChip.breathe * 0.55;
                        return Qt.rgba(
                            base.r + (accent.r - base.r) * k,
                            base.g + (accent.g - base.g) * k,
                            base.b + (accent.b - base.b) * k,
                            1
                        );
                    }

                    // Icon follows the text color and breathes
                    // toward the accent while in flight.
                    function iconColor() {
                        var base = Theme.surfaceVariantText;
                        if (chipHover.hovered) return Theme.primary;
                        if (!toolEntry.entry
                            || toolEntry.entry.state !== "running")
                            return base;
                        return toolChip.breatheColor(base, Theme.primary);
                    }

                    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: if (toolEntry.hasDetail)
                            bubble.toggleToolExpand(toolEntry.index)
                    }

                    RowLayout {
                        id: toolChipRow
                        anchors.centerIn: parent
                        spacing: 6

                        // Left slot: handyman glyph crossfading
                        // to a chevron on hover.
                        Item {
                            width: 16; height: 16
                            DankIcon {
                                anchors.centerIn: parent
                                name: "handyman"
                                size: 14
                                color: toolChip.iconColor()
                                opacity: chipHover.hovered ? 0 : 1
                                Behavior on opacity {
                                    NumberAnimation { duration: 220 }
                                }
                            }
                            DankIcon {
                                anchors.centerIn: parent
                                name: "expand_more"
                                size: 14
                                color: toolChip.iconColor()
                                opacity: chipHover.hovered ? 1 : 0
                                rotation: toolEntry.expanded ? 180 : 0
                                Behavior on opacity {
                                    NumberAnimation { duration: 220 }
                                }
                                Behavior on rotation {
                                    RotationAnimation {
                                        duration: 200
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }
                        }

                        Text {
                            text: toolEntry.chipLabel
                            color: {
                                if (chipHover.hovered) return Theme.primary;
                                return toolChip.breathe
                                    ? toolChip.breatheColor(
                                          Theme.surfaceVariantText,
                                          Theme.primary)
                                    : Theme.surfaceVariantText;
                            }
                            font.pixelSize: 11
                            font.family: Theme.monoFontFamily
                            elide: Text.ElideRight
                        }
                    }
                }

                // Collapsible detail: real tool name + pretty-
                // printed response. Flickable caps the height;
                // body is NoWrap to keep the JSON indent intact.
                ColumnLayout {
                    id: toolDetail
                    visible: toolEntry.expanded && toolEntry.hasDetail
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    spacing: 4

                    Text {
                        Layout.fillWidth: true
                        text: toolEntry.entry ? toolEntry.entry.name : ""
                        color: Theme.surfaceVariantText
                        font.pixelSize: 12
                        font.family: Theme.monoFontFamily
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Flickable {
                        id: toolFlick
                        Layout.fillWidth: true
                        property real smoothH:
                            Math.min(toolDetailBody.contentHeight, 260)
                        Behavior on smoothH {
                            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
                        }
                        Layout.preferredHeight: smoothH
                        contentHeight: toolDetailBody.contentHeight
                        contentWidth: toolDetailBody.contentWidth
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        TextArea {
                            id: toolDetailBody
                            width: Math.max(toolFlick.width,
                                             toolDetailBody.contentWidth)
                            readOnly: true
                            textFormat: TextEdit.PlainText
                            wrapMode: TextEdit.NoWrap
                            text: toolEntry.entry
                                ? bubble.formatToolDetail(toolEntry.entry.detail)
                                : ""
                            color: Theme.surfaceTextMedium
                            font.pixelSize: 12
                            font.family: Theme.monoFontFamily
                            background: null
                            leftPadding: 8
                            rightPadding: 8
                            topPadding: 8
                            bottomPadding: 8
                            selectByMouse: true
                        }
                    }
                }
            }
    }

    // One text flow entry: closed entries render their range from
    // the cached segment split; the live entry renders the segment
    // list the fade machinery maintains (bubble.segments).
    Component {
        id: textEntryComp
        ColumnLayout {
            id: textEntry
            property var entry: null
            readonly property bool live: entry ? entry.live : false
            readonly property var segs: live
                ? bubble.segments
                : bubble.entrySegs(entry ? entry.a : 0,
                                   entry ? entry.b : 0)
            spacing: 0
            Layout.fillWidth: true

            Repeater {
                model: textEntry.segs ? textEntry.segs.length : 0

                delegate: Loader {
                    id: segLoader
                    required property int index
                    readonly property var seg:
                        (textEntry.segs && index < textEntry.segs.length)
                        ? textEntry.segs[index] : null
                    Layout.fillWidth: true
                    sourceComponent:
                        seg && seg.type === "code" ? codeSegComp : textSegComp
                    onLoaded: item.seg = Qt.binding(
                        function () { return segLoader.seg; })
                }
            }
        }
    }
}
