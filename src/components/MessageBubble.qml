import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
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
    // to the accent (Theme.primary) and the cursor becomes a hand —
    // mirrors the pondering-header pattern above.
    component HoverIcon : Item {
        id: hov
        property string iconName: ""
        property int iconSize: 16
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
        // 16px touch target — the icon paints at iconSize inside.
        implicitWidth: 16
        implicitHeight: 16
    }

    function _highlight(code, lang) {
        return SyntaxHighlight.highlightCode(code, lang, mdColors.syntax);
    }

    // ── Thinking phase tracking ───────────────────────────────────
    // Auto-opens on stream start, auto-closes at first content token
    // (manual re-open sticks). Wall time drives the "Pondered …" label.
    property bool thinkingExpanded: false
    property real _thinkStartMs: 0
    property real _thinkDurationMs: 0

    // ── Interleaved pondering + tool chips ────────────────────────
    // Thinking renders split at each call's thinkingAt with chips in
    // between. Fade/reveal applies to the TAIL only; head segments
    // are frozen.
    property int _thinkSplit: 0
    readonly property string thinkTail:
        thinking.substring(Math.min(_thinkSplit, thinking.length))

    onToolLogArrChanged: {
        var mx = 0;
        for (var i = 0; i < toolLogArr.length; i++) {
            var e = toolLogArr[i];
            if (e && e.thinkingAt > mx) mx = e.thinkingAt;
        }
        if (mx > _thinkSplit) {
            _thinkSplit = mx;
            // Fresh tail — restart the progressive reveal so the
            // post-call thinking streams in like any other round.
            shownThinking = "";
            _thinkFadeTail = "";
        }
    }

    // Segments split at each tool call's thinkingAt; only the trailing
    // one is live. Count-based Repeater keeps delegates stable.
    readonly property var thinkSegments: {
        var segs = [];
        var log = bubble.toolLogArr;
        var prev = 0;
        for (var i = 0; i < log.length; i++) {
            var e = log[i];
            var at = e && e.thinkingAt ? e.thinkingAt : 0;
            if (at > thinking.length) at = thinking.length;
            if (at < prev) at = prev;
            var txt = thinking.substring(prev, at);
            if (txt.length > 0)
                segs.push({ type: "text", text: txt, live: false });
            segs.push({ type: "tool", idx: i });
            prev = at;
        }
        var tail = thinking.substring(prev);
        if (tail.length > 0 || segs.length === 0)
            segs.push({ type: "text", text: tail, live: true });
        return segs;
    }

    // Static markdown for frozen head segments (no fade machinery —
    // those rounds are complete).
    function staticThinkHtml(text) {
        if (!text) return "";
        return Markdown.markdownToHtml(text, mdColors, _highlight);
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
        return text;
    }

    readonly property bool thinkingDone: thinking.length > 0 &&
        (content.length > 0 || !isStreaming)

    function ponderedLabel() {
        if (_thinkDurationMs < 5000) return "Pondered briefly";
        return "Pondered for " + Math.round(_thinkDurationMs / 1000) + " seconds";
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

    // fadeFrom: offset where the newest batch began (-1 = settled).
    // Streaming renders at most shownText (advanced ≤flushChars/tick).
    function flushBatches(contentFrom, thinkFrom) {
        var streaming = msgState === "streaming";
        var renderText = streaming
            ? content.substring(0, shownText.length) : content;
        if (isUser || renderText.length === 0) {
            segments = [];
        } else if (streaming && contentFrom >= 0 && contentFrom < renderText.length) {
            var segs = Markdown.splitCodeSegments(renderText);
            for (var i = 0; i < segs.length; i++) {
                if (segs[i].type !== "text") continue;
                var rel = -1;
                if (i === segs.length - 1 && contentFrom >= 0) {
                    rel = contentFrom - (renderText.length - segs[i].text.length);
                    if (rel < 0) rel = 0;
                    if (rel >= segs[i].text.length) rel = -1;
                }
                if (rel >= 0) {
                    var parts = _fadeSplit(_fadeColor, segs[i].text, rel);
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
        if (shownThinking.length === 0) {
            renderedThinkingHtml = "";
        } else if (streaming && thinkFrom >= 0 && thinkFrom < shownThinking.length) {
            var tp = _fadeSplit(_thinkFadeColor, shownThinking, thinkFrom);
            _thinkFadePrefix = tp.prefix;
            _thinkFadeTail = tp.tail;
            _thinkFadeSuffix = tp.suffix;
            renderedThinkingHtml = tp.html;
        } else {
            renderedThinkingHtml = Markdown.markdownToHtml(
                shownThinking, mdColors, _highlight);
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
                && shownThinking.length >= thinkTail.length) return;
        var prevC = shownText.length;
        var prevT = shownThinking.length;
        // render cap: ≤flushChars new chars enter the layout per tick
        shownText = content.substring(
            0, Math.min(content.length, shownText.length + flushChars));
        shownThinking = thinkTail.substring(
            0, Math.min(thinkTail.length, shownThinking.length + flushChars));
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
        var streaming = msgState === "streaming";
        if (streaming) {
            _thinkStartMs = 0;
            _thinkDurationMs = 0;
            shownText = "";
            shownThinking = "";
            if (content.length === 0) thinkingExpanded = true;
        } else {
            if (_thinkStartMs > 0 && _thinkDurationMs === 0)
                _thinkDurationMs = Date.now() - _thinkStartMs;
            shownText = content;
            shownThinking = thinkTail;
            thinkingExpanded = false;   // done → collapsed "Pondered …"
        }
        fadeTimer.stop();
        flushBatches(-1, -1);
    }
    onContentChanged: {
        if (content.length > 0 && _thinkStartMs > 0 && _thinkDurationMs === 0) {
            _thinkDurationMs = Date.now() - _thinkStartMs;
            thinkingExpanded = false;   // thinking done → hide it
        }
        if (msgState !== "streaming") flushBatches(-1, -1);
    }
    onThinkingChanged: {
        if (thinking.length > 0 && _thinkStartMs === 0) _thinkStartMs = Date.now();
        if (msgState !== "streaming") {
            shownThinking = thinkTail;
            flushBatches(-1, -1);
        }
    }
    onMdColorsChanged: {   // live theme switch → recolor completed bubbles
        shownText = content;
        shownThinking = thinkTail;
        flushBatches(-1, -1);
    }
    Component.onCompleted: {
        if (msgState === "streaming") thinkingExpanded = true;
        else { shownText = content; shownThinking = thinkTail; }
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
        running: bubble.isStreaming && !bubble.isUser
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

        // Thinking box (also hosts tool chips alone when there's no
        // thinking text).
        Loader {
            active: thinking.length > 0 || bubble.toolLogArr.length > 0
            Layout.fillWidth: true
            sourceComponent: thinkingBox
        }


        // Streaming indicator before first content: the tumbling hex
        // sphere (same small config as the footer status row) with a
        // plain status label.
        Row {
            id: promptRow
            visible: isStreaming && content.length === 0 && thinking.length === 0
            spacing: 8

            HexSphereLogo {
                radius: 11
                strokeWidth: 1.5
                subdivisions: 1
                yawRate: 20
                pitchRate: 8
                interactive: false
                anchors.verticalCenter: parent.verticalCenter
                visible: promptRow.visible
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Processing prompt"
                color: Theme.surfaceVariantText
                font.pixelSize: 11
            }
        }

        // Count-based Repeater — delegates are reused across ticks,
        // each reading its segment by index.
        Repeater {
            model: bubble.segments ? bubble.segments.length : 0

            delegate: Loader {
                id: segLoader
                required property int index
                readonly property var seg:
                    (bubble.segments && index < bubble.segments.length)
                    ? bubble.segments[index] : null
                Layout.fillWidth: true
                sourceComponent:
                    seg && seg.type === "code" ? codeSegComp : textSegComp
                onLoaded: item.seg = Qt.binding(
                    function () { return segLoader.seg; })
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
                            width: 120
                            height: 84
                            radius: 6
                            color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.6)
                            clip: true

                            Image {
                                anchors.fill: parent
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                source: bubble.attachmentsArr[index]
                                    ? "data:" + bubble.attachmentsArr[index].mime
                                      + ";base64," + bubble.attachmentsArr[index].data
                                    : ""
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
                    ["wl-copy", "--", bubble.content])
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
                    ["wl-copy", "--", bubble.content])
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
                            ["wl-copy", "--", codeRect.rawCode])
                    }
                }
            }
        }
    }

    Component {
        id: thinkingBox
        ColumnLayout {
            id: thinkPane
            spacing: 4
            // Thinking header chip: hovering tints it with the accent
            // color and crossfades the bulb into an expand arrow; the
            // whole chip is the toggle target. Hidden when the model
            // produced no thinking — the box then hosts only the
            // tool chips below.
            Rectangle {
                id: thinkHeader
                visible: thinking.length > 0
                Layout.fillWidth: false
                implicitWidth: headerRow.implicitWidth + 16
                implicitHeight: headerRow.implicitHeight + 8
                radius: 8
                color: thinkHeaderHover.hovered
                    ? Theme.withAlpha(Theme.primary, 0.14) : "transparent"
                Behavior on color { ColorAnimation { duration: 220 } }

                HoverHandler {
                    id: thinkHeaderHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: bubble.thinkingExpanded =
                        !bubble.thinkingExpanded
                }

                RowLayout {
                    id: headerRow
                    anchors.centerIn: parent
                    spacing: 6

                    Item {
                        width: 16; height: 16
                        DankIcon {
                            anchors.centerIn: parent
                            name: "emoji_objects"
                            size: 16
                            color: Theme.surfaceVariantText
                            opacity: thinkHeaderHover.hovered ? 0 : 1
                            Behavior on opacity {
                                NumberAnimation { duration: 220 }
                            }
                        }
                        DankIcon {
                            anchors.centerIn: parent
                            name: "expand_more"
                            size: 16
                            color: Theme.primary
                            opacity: thinkHeaderHover.hovered ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation { duration: 220 }
                            }
                        }
                    }

                    Text {
                        text: !bubble.thinkingDone ? "Pondering..."
                            : (bubble.thinkingExpanded ? "Hide thinking"
                                                       : bubble.ponderedLabel())
                        color: thinkHeaderHover.hovered
                            ? Theme.primary : Theme.surfaceVariantText
                        font.pixelSize: 11
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }
                }
            }

            // Thinking content: 220px cap + smoothed height; auto-scroll
            // pinned to the bottom while streaming, free after. Column
            // so tool chips render inside the collapsible area.
            Flickable {
                id: thinkFlick
                // Hidden when collapsed — unless there's no thinking
                // text and the box hosts only the tool chips.
                visible: bubble.thinkingExpanded || thinking.length === 0
                Layout.fillWidth: true
                Layout.preferredHeight: smoothH
                readonly property int maxH: 220
                property real smoothH: Math.min(contentHeight, maxH)
                Behavior on smoothH {
                    NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
                }
                contentHeight: thinkContent.implicitHeight
                clip: true

                property bool pinned: true

                function chase() {
                    if (!pinned || !bubble.isStreaming) return;
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
                    thinkChaseAnim.to = target;
                    thinkChaseAnim.restart();
                }

                function unpin() {
                    pinned = false;
                    thinkChaseAnim.stop();
                }

                onContentHeightChanged: chase()

                onDraggingChanged: if (dragging) unpin()
                onFlickingChanged: if (flicking) unpin()
                onContentYChanged: {
                    // the chase only ever increases contentY; any
                    // decrease is the user scrolling up
                    if (contentY < thinkFlick._lastY - 2) unpin();
                    thinkFlick._lastY = contentY;
                    if (atYEnd) pinned = true;
                }
                property real _lastY: 0

                NumberAnimation {
                    id: thinkChaseAnim
                    target: thinkFlick
                    property: "contentY"
                    // Linear conveyor, same rationale as the message
                    // list follow: eased restarts spike per flush.
                    duration: 200
                    easing.type: Easing.Linear
                }

                WheelHandler {
                    onWheel: (event) => {
                        thinkFlick.unpin();
                        event.accepted = false;
                    }
                }

                // Box content: the pondering flow as interleaved
                // segments — thinking text with the tool chips placed
                // at the chronological point each call was issued:
                // [text] [chip] [text] [chip] [live tail]. Everything
                // lives inside the collapsible area, so it expands and
                // collapses together with the box.
                Column {
                    id: thinkContent
                    width: thinkFlick.width
                    spacing: 8

                    // Count-based model: delegates are reused while
                    // the count is stable; each reads its segment by
                    // index (same pattern as the body segments).
                    Repeater {
                        model: bubble.thinkSegments.length

                        delegate: Loader {
                            id: segLoader
                            required property int index
                            readonly property var seg:
                                (bubble.thinkSegments
                                 && index < bubble.thinkSegments.length)
                                ? bubble.thinkSegments[index] : null
                            width: thinkContent.width
                            sourceComponent:
                                seg && seg.type === "tool"
                                ? toolChipComp : thinkTextSegComp
                            onLoaded: {
                                if (seg && seg.type === "tool") {
                                    item.index = Qt.binding(function () {
                                        return segLoader.seg ? segLoader.seg.idx : 0;
                                    });
                                    item.entry = Qt.binding(function () {
                                        var s = segLoader.seg;
                                        return s ? (bubble.toolLogArr[s.idx] || null)
                                                 : null;
                                    });
                                } else {
                                    // Text segment: hand the segment
                                    // record to the TextArea so it can
                                    // switch between the live fade html
                                    // and the static markdown render.
                                    item.seg = Qt.binding(function () {
                                        return segLoader.seg;
                                    });
                                }
                            }
                        }
                    }
                }

                Component {
                    id: thinkTextSegComp
                    TextArea {
                        property var seg: null
                        width: thinkContent.width
                        readOnly: true
                        textFormat: TextEdit.RichText
                        wrapMode: TextEdit.Wrap
                        // The live tail streams through the fade/
                        // reveal machinery; frozen heads render static
                        // markdown (their round is complete).
                        text: seg && seg.live
                            ? bubble.renderedThinkingHtml
                            : bubble.staticThinkHtml(seg ? seg.text : "")
                        color: Theme.surfaceTextMedium
                        font.pixelSize: 12
                        background: null
                        leftPadding: 0
                        rightPadding: 0
                        topPadding: 0
                        bottomPadding: 0
                    }
                }
            }

            // One tool chip + its collapsible detail block. Generic
            // label ("Calling Tool" / "Tool called for N seconds");
            // the actual tool name lives in the detail. index/entry are
            // bound by the instantiating Loader so the chip updates
            // live as the entry mutates.
            Component {
                id: toolChipComp

                ColumnLayout {
                    id: toolEntry
                    property int index: 0
                    property var entry: null
                    readonly property bool expanded: bubble.isToolExpanded(index)
                        readonly property bool hasDetail:
                            entry && entry.detail && entry.detail.length > 0
                        // Sub-second calls collapse to "(less than a
                        // second)" so the chip never shows 0 seconds.
                        readonly property string chipLabel: {
                            var e = toolEntry.entry;
                            if (!e || e.state === "running") return "Calling Tool";
                            var ms = Math.max(0,
                                              (e.endMs || 0) - (e.startMs || 0));
                            if (ms < 1000) return "Tool called (less than a second)";
                            return "Tool called for " + Math.round(ms / 1000) + " seconds";
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
            }
        }
    }
