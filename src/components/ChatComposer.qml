import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modals.FileBrowser
import "../lib/Providers.js" as Providers

    // Composer: transparent input, send/stop right; input grows to a
    // cap then scrolls. Attachments stage above the input (clipboard
    // or file picker) and pass Providers.sanitizeImages.
Item {
    id: composer

    signal submitted(string text, var images)
    signal escapePressed()
    signal newChatRequested()

    property var service: null
    property string placeholder: "Ask anything…"
    readonly property bool busy: service ? service.isStreaming : false

    // Staged image attachments ([{mime, data}]), capped by
    // sanitizeImages (4). attachHint surfaces a rejection reason
    // briefly, then auto-clears.
    readonly property int maxImages: 4
    property var attachments: []
    property string attachHint: ""

    // Input grows with content up to ~10 lines, then scrolls internally.
    readonly property int maxInputHeight: 220

    implicitHeight: divider.height + 12
        + (thumbStrip.visible ? thumbStrip.height + 8 : 0)
        + Math.max(48, Math.min(input.implicitHeight, maxInputHeight))

    function send() {
        var text = input.text.trim();
        if (busy) return;
        if (!text && composer.attachments.length === 0) return;
        submitted(text, composer.attachments);
        input.clear();
        composer.attachments = [];
        attachHint = "";
    }

    function showAttachHint(msg) {
        attachHint = String(msg || "");
        hintTimer.restart();
    }

    // Single ingest gate: sanitize (mime whitelist, base64 shape, size,
    // cap) then stage. Reports a transient hint when the new image was
    // rejected.
    function addAttachment(mime, data) {
        var before = composer.attachments.length;
        var clean = Providers.sanitizeImages(
            composer.attachments.concat([{ mime: mime, data: data }]),
            composer.maxImages);
        composer.attachments = clean;
        showAttachHint(clean.length > before
            ? "" : "Image dropped — unsupported type, over 10 MB, or limit of "
                   + composer.maxImages + " reached");
    }

    function removeAttachment(idx) {
        var arr = composer.attachments.slice();
        if (idx < 0 || idx >= arr.length) return;
        arr.splice(idx, 1);
        composer.attachments = arr;
        if (arr.length === 0) attachHint = "";
    }

    // Clipboard ingest: ask wl-paste for the offered types; on an
    // image, re-read that type as base64. Without an image the key
    // press falls through to a normal text paste.
    function pasteFromClipboard() {
        clipProc.phase = 1;
        clipProc.command = ["wl-paste", "--list-types"];
        clipProc.running = true;
    }

    function pickImageMime(typesText) {
        var types = String(typesText).split("\n").map(
            function (t) { return t.trim(); });
        var prefs = ["image/png", "image/jpeg", "image/webp", "image/gif"];
        for (var i = 0; i < prefs.length; i++)
            if (types.indexOf(prefs[i]) >= 0) return prefs[i];
        return "";
    }

    // Magic-byte sniffing over the base64 head: PNG \x89PNG, JPEG
    // \xFF\xD8\xFF, WEBP RIFF, GIF8. "" for anything else.
    function sniffImageMime(b64) {
        if (b64.indexOf("iVBOR") === 0) return "image/png";
        if (b64.indexOf("/9j/") === 0) return "image/jpeg";
        if (b64.indexOf("UklGR") === 0) return "image/webp";
        if (b64.indexOf("R0lGOD") === 0) return "image/gif";
        return "";
    }

    // File picker: DMS's native FileBrowser modal — Qt's FileDialog
    // (GTK3 helper) aborts the whole shell process here.
    function attachFromFile() {
        imageBrowserLoader.active = true;
        if (imageBrowserLoader.item)
            imageBrowserLoader.item.open();
    }

    function ingestFilePath(path) {
        if (!path || path.length === 0) return;
        var p = String(path).replace(/'/g, "'\\''");
        fileProc.command = ["sh", "-c", "base64 -w0 '" + p + "'"];
        fileProc.running = true;
    }

    // Discard an in-progress edit: leave edit mode and clear the
    // draft, returning the composer to normal new-message state.
    function discardEdit() {
        if (service) service.cancelEditUserMessage();
        input.clear();
        focusInput();
    }

    function focusInput() {
        input.forceActiveFocus();
        input.cursorPosition = input.text.length;
    }

    // Modifier flags required for Enter to send.
    readonly property int sendModifiers: {
        var m = service ? service.sendModifier : "none";
        if (m === "shift") return Qt.ShiftModifier;
        if (m === "ctrl") return Qt.ControlModifier;
        if (m === "alt") return Qt.AltModifier;
        return Qt.NoModifier;
    }

    // Enter fires a send only for the configured chord; every other
    // chord falls through (accepted = false) and inserts a newline.
    // KeypadModifier is masked so numpad Enter matches Key_Enter.
    function handleReturnKey(event) {
        var mods = event.modifiers & ~Qt.KeypadModifier;
        if (mods === composer.sendModifiers) composer.send();
        else event.accepted = false;
    }

    // Load a draft into the input (used by message editing: the text
    // of the edited user message lands here; submitting performs the
    // edit — see NexusChat's onSubmitted routing).
    function setText(t) {
        input.text = String(t || "");
        input.cursorPosition = input.text.length;
    }

    Rectangle {
        id: divider
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Theme.primary }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    // Staged attachment thumbnails + rejection hint. Zero-height while
    // empty so the input row sits right under the divider.
    Row {
        id: thumbStrip
        visible: composer.attachments.length > 0 || composer.attachHint.length > 0
        anchors.top: divider.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.leftMargin: 4
        anchors.right: parent.right
        anchors.rightMargin: 4
        spacing: 8

        Repeater {
            model: composer.attachments.length

            delegate: Item {
                id: thumb
                required property int index
                width: 92
                height: 68

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.6)
                    clip: true

                    Image {
                        anchors.fill: parent
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        source: composer.attachments[thumb.index]
                            ? "data:" + composer.attachments[thumb.index].mime
                              + ";base64," + composer.attachments[thumb.index].data
                            : ""
                    }
                }

                // Remove badge: overlaps the top-right corner.
                Item {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.rightMargin: -6
                    anchors.topMargin: -6
                    width: 20
                    height: 20

                    Rectangle {
                        anchors.fill: parent
                        radius: 10
                        color: thumbRemoveHover.hovered
                            ? Theme.withAlpha(Theme.primary, 0.25)
                            : Theme.surfaceContainerHigh
                        border.width: 1
                        border.color: Theme.outlineVariant
                    }
                    DankIcon {
                        anchors.centerIn: parent
                        name: "close"
                        size: 12
                        color: thumbRemoveHover.hovered
                            ? Theme.primary : Theme.surfaceText
                    }
                    HoverHandler {
                        id: thumbRemoveHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: composer.removeAttachment(thumb.index)
                    }
                }
            }
        }

        Text {
            visible: composer.attachHint.length > 0
            text: composer.attachHint
            color: Theme.error
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    RowLayout {
        anchors.top: thumbStrip.visible ? thumbStrip.bottom : divider.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        anchors.bottomMargin: 4
        spacing: 8

        Flickable {
            id: inputScroll
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            Layout.maximumHeight: composer.maxInputHeight
            Layout.preferredHeight: Math.min(input.implicitHeight, composer.maxInputHeight)
            contentHeight: input.contentHeight
            clip: true
            interactive: contentHeight > height
            flickableDirection: Flickable.VerticalFlick

            ScrollBar.vertical: DankScrollbar { _scrollBarActive: true }

            TextEdit {
                id: input
                width: inputScroll.width
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                color: Theme.surfaceText
                font.pixelSize: 14

                // keep the cursor visible while typing past the cap
                onCursorRectangleChanged: {
                    var y = cursorRectangle.y - inputScroll.contentY;
                    if (y < 0)
                        inputScroll.contentY += y;
                    else if (y + cursorRectangle.height > inputScroll.height)
                        inputScroll.contentY += y + cursorRectangle.height - inputScroll.height;
                }

                Keys.onEscapePressed: (event) => {
                    event.accepted = true;
                    composer.escapePressed();
                }
                Keys.onPressed: (event) => {
                    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
                        event.accepted = true;
                        composer.newChatRequested();
                        return;
                    }
                    // Ctrl+V: an image on the clipboard is staged as an
                    // attachment; plain text falls through to the
                    // normal paste inside pasteFromClipboard's flow.
                    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) {
                        event.accepted = true;
                        composer.pasteFromClipboard();
                        return;
                    }
                    // Up in an empty input = edit the last user message
                    // (Slack/Discord convention). Non-empty inputs keep
                    // normal cursor navigation.
                    if (event.key === Qt.Key_Up && input.text.length === 0
                            && !busy && service && service.messageCount > 0) {
                        event.accepted = true;
                        service.beginEditLastUserMessage();
                    }
                }
                Keys.onReturnPressed: (event) => handleReturnKey(event)
                Keys.onEnterPressed: (event) => handleReturnKey(event)
            }

            // Placeholder: sits exactly where typing starts, non-
            // interactive so clicks land on the input. Shown only for a
            // brand-new chat (no messages yet); re-rolled on clear.
            Text {
                anchors.left: parent.left
                anchors.top: parent.top
                width: input.width
                text: composer.placeholder
                color: Theme.surfaceVariantText
                opacity: 0.5
                font.pixelSize: 14
                visible: input.text.length === 0
                         && (!composer.service || composer.service.messageCount === 0)
            }
        }

        // Discard affordance while a message edit is in progress:
        // drops the draft and leaves edit mode.
        DankButton {
            iconName: "close"
            text: ""
            buttonHeight: 36
            Layout.alignment: Qt.AlignVCenter
            visible: !busy && service && service.editingMessageId.length > 0
            onClicked: composer.discardEdit()
        }

        // Split send button: left half = send/stop/confirm-edit, right
        // half = chord picker. Hover/press brightens only that half.
        Rectangle {
            id: splitSend
            height: 36
            radius: Theme.cornerRadius
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: sendZone.width + arrowZone.width
            color: Theme.buttonBg
            readonly property bool sendHover: sendArea.containsMouse
            readonly property bool sendPressed: sendArea.pressed
            readonly property bool arrowHover: arrowArea.containsMouse
            readonly property bool arrowPressed: arrowArea.pressed
            // Split line as a gradient position (0..1).
            readonly property real splitPos:
                sendZone.width / Math.max(1, width)

            // Rest shading: gradient hard-stops at the split line so
            // the tint rounds cleanly into the corners.
            Rectangle {
                anchors.fill: parent
                radius: splitSend.radius
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop {
                        position: splitSend.splitPos
                        color: "transparent"
                    }
                    GradientStop {
                        position: Math.min(1, splitSend.splitPos + 0.001)
                        color: Theme.withAlpha(Theme.buttonText, 0.10)
                    }
                    GradientStop {
                        position: 1
                        color: Theme.withAlpha(Theme.buttonText, 0.10)
                    }
                }
            }

            // Disabled veil on the send half only (picker stays lit).
            Rectangle {
                anchors.fill: parent
                radius: splitSend.radius
                opacity: sendArea.enabled ? 0 : 0.55
                Behavior on opacity { NumberAnimation { duration: 180 } }
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Theme.surfaceContainer }
                    GradientStop {
                        position: splitSend.splitPos
                        color: Theme.surfaceContainer
                    }
                    GradientStop {
                        position: Math.min(1, splitSend.splitPos + 0.001)
                        color: "transparent"
                    }
                    GradientStop { position: 1; color: "transparent" }
                }
            }

            // White hover/press wash (buttonText tints misbehave on
            // some buttonBg modes); hard-stops at the split line.
            Rectangle {
                anchors.fill: parent
                radius: splitSend.radius
                opacity: splitSend.sendHover || splitSend.sendPressed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 180 } }
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0
                        color: splitSend.sendPressed
                            ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.12)
                    }
                    GradientStop {
                        position: splitSend.splitPos
                        color: splitSend.sendPressed
                            ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.12)
                    }
                    GradientStop {
                        position: Math.min(1, splitSend.splitPos + 0.001)
                        color: "transparent"
                    }
                    GradientStop { position: 1; color: "transparent" }
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: splitSend.radius
                opacity: splitSend.arrowHover || splitSend.arrowPressed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 180 } }
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop {
                        position: splitSend.splitPos
                        color: "transparent"
                    }
                    GradientStop {
                        position: Math.min(1, splitSend.splitPos + 0.001)
                        color: splitSend.arrowPressed
                            ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.12)
                    }
                    GradientStop {
                        position: 1
                        color: splitSend.arrowPressed
                            ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.12)
                    }
                }
            }

            // Left half: send / stop streaming / confirm edit. Dimmed
            // when there is nothing to do (empty input, idle).
            Item {
                id: sendZone
                anchors.left: parent.left
                width: 64
                height: parent.height

                DankIcon {
                    anchors.centerIn: parent
                    name: busy ? "stop_circle"
                        : (service && service.editingMessageId.length > 0
                           ? "check" : "send")
                    size: 18
                    color: Theme.buttonText
                    opacity: sendArea.enabled ? 1 : 0.4
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }

                MouseArea {
                    id: sendArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: busy || input.text.trim().length > 0
                             || composer.attachments.length > 0
                    cursorShape: enabled ? Qt.PointingHandCursor
                                         : Qt.ArrowCursor
                    onClicked: {
                        if (busy) service.cancelStream();
                        else composer.send();
                    }
                }
            }

            // Right half: send-chord picker (always active).
            Item {
                id: arrowZone
                anchors.right: parent.right
                width: 30
                height: parent.height

                DankIcon {
                    anchors.centerIn: parent
                    name: "arrow_drop_down"
                    size: 18
                    color: Theme.buttonText
                }

                MouseArea {
                    id: arrowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: modPopup.visible ? modPopup.close()
                                                : modPopup.open()
                }
            }
        }

        // Send-chord picker: opens above the composer, right-aligned
        // to the split button.
        Popup {
            id: modPopup
            parent: arrowZone
            x: parent.width - width
            y: -height - 8
            width: 168
            height: modCol.implicitHeight + 12
            padding: 6

            background: Rectangle {
                radius: 8
                color: Theme.surfaceContainerHigh
                border.width: 1
                border.color: Theme.outlineVariant
            }

            contentItem: ColumnLayout {
                id: modCol
                spacing: 2

                Repeater {
                    model: [
                        { key: "none", label: "Return only", icon: "keyboard_return" },
                        { key: "shift", label: "Shift", icon: "shift" },
                        { key: "ctrl", label: "Ctrl", icon: "keyboard" },
                        { key: "alt", label: "Alt", icon: "buttons_alt" }
                    ]

                    delegate: Item {
                        id: modRow
                        required property var modelData
                        readonly property bool active: composer.service
                            && composer.service.sendModifier === modRow.modelData.key
                        readonly property bool hovered: modHover.hovered
                        width: modCol.width
                        height: 32

                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: modRow.hovered
                                ? Theme.withAlpha(Theme.primary, 0.14) : "transparent"
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 8

                            DankIcon {
                                name: modRow.modelData.icon
                                size: 16
                                color: modRow.active || modRow.hovered
                                    ? Theme.primary : Theme.surfaceVariantText
                                Behavior on color { ColorAnimation { duration: 150 } }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: modRow.modelData.label
                                color: modRow.active || modRow.hovered
                                    ? Theme.primary : Theme.surfaceText
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }

                            DankIcon {
                                visible: modRow.active
                                name: "check"
                                size: 16
                                color: Theme.primary
                            }
                        }

                        HoverHandler {
                            id: modHover
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: {
                                if (composer.service)
                                    composer.service.setSendModifier(modRow.modelData.key);
                                modPopup.close();
                            }
                        }
                    }
                }
            }
        }

        // ── Attachment ingest (clipboard) ──────────────────────────
        Process {
            id: clipProc
            property int phase: 0        // 0 idle | 1 types | 2 data
            property string _mime: ""
            command: ["true"]

            stdout: StdioCollector {
                id: clipOut
                onStreamFinished: {
                    if (clipProc.phase === 1) {
                        var pick = composer.pickImageMime(clipOut.text);
                        if (pick.length === 0) {
                            clipProc.phase = 0;
                            input.paste();
                            return;
                        }
                        clipProc._mime = pick;
                        clipProc.phase = 2;
                        clipProc.command = ["sh", "-c",
                            "wl-paste -t '" + pick + "' | base64 -w0"];
                        clipProc.running = true;
                    } else if (clipProc.phase === 2) {
                        var b64 = clipOut.text.replace(/\s+/g, "");
                        clipProc.phase = 0;
                        if (b64.length > 0)
                            composer.addAttachment(clipProc._mime, b64);
                    }
                }
            }
        }

        // Picked file bytes → base64; the mime is sniffed from the
        // magic bytes rather than trusting the extension.
        Process {
            id: fileProc
            command: ["true"]

            stdout: StdioCollector {
                id: fileOut
                onStreamFinished: {
                    var b64 = fileOut.text.replace(/\s+/g, "");
                    var mime = composer.sniffImageMime(b64);
                    if (mime.length > 0)
                        composer.addAttachment(mime, b64);
                    else
                        composer.showAttachHint("Unsupported image type");
                }
            }
        }

        // Native DMS file browser, lazily created on first use and
        // dropped again when it closes (same pattern as Notepad).
        LazyLoader {
            id: imageBrowserLoader
            active: false

            FileBrowserSurfaceModal {
                browserTitle: "Attach image"
                browserIcon: "attach_file"
                browserType: "nexus_attach"
                fileExtensions: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif"]
                allowStacking: true

                onFileSelected: (path) => {
                    close();
                    var p = String(path).replace(/^file:\/\//, "");
                    try { p = decodeURIComponent(p); }
                    catch (e) { /* literal % in the name — keep raw */ }
                    composer.ingestFilePath(p);
                }
                onDialogClosed: imageBrowserLoader.active = false
            }
        }

        Timer {
            id: hintTimer
            interval: 4000
            onTriggered: composer.attachHint = ""
        }
    }
}
