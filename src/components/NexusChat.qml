import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Item {
    id: chat

    property var service: null
    property var panel: null

    // History drawer visibility; the panel-bar menu button toggles it.
    property bool historyOpen: false

    state: "chat"
    states: [
        State { name: "chat" },
        State { name: "settings" }
    ]

    // Save on leave
    onStateChanged: if (state !== "settings") chat.forceActiveFocus();

    // Called by NexusPanel when the panel finishes sliding in.
    function focusInput() {
        if (state === "chat" && composer.focusInput)
            composer.focusInput();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // Chat box: same matugen hue as the panel, just more
        // opaque — reads darker/more solid without graying out.
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainer, 0.9)
            clip: true

            MessageList {
                id: messageList
                anchors.fill: parent
                anchors.margins: 6
                service: chat.service
            }

            // Centered plugin logo for the empty conversation.
            HexSphereLogo {
                anchors.centerIn: parent
                radius: 66
                // Same opacity-driven visible pattern as the chip
                // below: the empty-state fade-out must get to play.
                opacity: (chat.service ? chat.service.messageCount === 0 : true) ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 250 } }
            }

            // Status chips, bottom-left of the chat box just above the
            // composer gap: MCP toolset count and the native web tools
            // indicator. Both only show on an empty conversation (they
            // fade away once the chat starts).
            Row {
                id: statusChips
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: 10
                anchors.bottomMargin: 8
                spacing: 8

                // Active-toolset chip: counts MCP servers currently
                // contributing tools; only shows when that's > 0.
                Rectangle {
                    id: toolsetChip
                    readonly property int count: chat.service
                        ? chat.service.activeToolsetCount() : 0
                    // Freezes at the last non-zero count so the label
                    // doesn't flip to "0 Active Toolsets" mid fade-out.
                    readonly property int displayCount: count > 0 ? count : lastNonZero
                    property int lastNonZero: 0
                    onCountChanged: if (count > 0) lastNonZero = count
                    readonly property bool chatEmpty: chat.service
                        ? chat.service.messageCount === 0 : true
                    readonly property bool shown: count > 0 && chatEmpty
                    width: chipRow.implicitWidth + 20
                    height: 28
                    radius: 8
                    // visible derives from opacity (never from `shown`):
                    // flipping visible directly would hide the item before
                    // the fade-out animation could play.
                    opacity: shown ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: 220 } }
                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.75)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.outlineVariant, 0.7)

                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "construction"
                            size: 14
                            color: Theme.primary
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: toolsetChip.displayCount === 1
                                ? "1 Active Toolset"
                                : toolsetChip.displayCount + " Active Toolsets"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                        }
                    }
                }

                // Web search chip: independent of the MCP count — shows
                // while the native tools master switch is on (and at
                // least one native tool is enabled).
                Rectangle {
                    id: webSearchChip
                    readonly property bool nativeOn: chat.service
                        ? chat.service.webToolsEnabled
                          && (chat.service.webSearchEnabled
                              || chat.service.webFetchEnabled)
                        : false
                    readonly property bool chatEmpty: chat.service
                        ? chat.service.messageCount === 0 : true
                    readonly property bool shown: nativeOn && chatEmpty
                    width: webChipRow.implicitWidth + 20
                    height: 28
                    radius: 8
                    opacity: shown ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: 220 } }
                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.75)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.outlineVariant, 0.7)

                    Row {
                        id: webChipRow
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "language"
                            size: 14
                            color: Theme.primary
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Web Search Enabled"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                        }
                    }
                }
            }

            // History drawer
            Rectangle {
                id: historyScrim
                anchors.fill: parent
                radius: Theme.cornerRadius
                visible: chat.service && chat.service.historyEnabled
                opacity: chat.historyOpen ? 1 : 0
                color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.55)
                Behavior on opacity { NumberAnimation { duration: 200 } }
                MouseArea {
                    anchors.fill: parent
                    enabled: chat.historyOpen
                    onClicked: chat.historyOpen = false
                }
            }

            Rectangle {
                id: historyDrawer
                visible: chat.service && chat.service.historyEnabled
                         && (chat.historyOpen
                             || historyDrawer.x > -historyDrawer.width)
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.min(314, parent.width * 0.78)
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                border.width: 1
                border.color: Theme.withAlpha(Theme.outlineVariant, 0.7)
                x: chat.historyOpen ? 0 : -width - 12
                Behavior on x {
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }

                Column {
                    id: drawerCol
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 8

                    Text {
                        text: "Chats"
                        color: Theme.surfaceText
                        font.pixelSize: 14
                        font.bold: true
                        leftPadding: 4
                    }

                    Rectangle {
                        id: newChatRow
                        width: parent.width
                        height: 40
                        radius: 8
                        color: newChatHover.hovered
                            ? Theme.withAlpha(Theme.primary, 0.14)
                            : Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "add"
                                size: 18
                                color: Theme.primary
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "New chat"
                                color: Theme.surfaceText
                                font.pixelSize: 13
                            }
                        }

                        HoverHandler {
                            id: newChatHover
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: {
                                chat.historyOpen = false;
                                if (chat.service) chat.service.newChat();
                            }
                        }
                    }

                    Flickable {
                        id: chatListScroll
                        width: parent.width
                        height: parent.height - drawerCol.spacing * 2
                                - 20 /* header */ - newChatRow.height
                        contentWidth: width
                        contentHeight: chatListCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: chatListCol
                            width: chatListScroll.width
                            spacing: 4

                            Repeater {
                                model: chat.service ? chat.service.chats : []

                                delegate: Rectangle {
                                    id: chatRow
                                    required property var modelData
                                    readonly property bool isActive:
                                        chat.service && modelData
                                        && modelData.id === chat.service.activeChatId
                                    width: parent.width
                                    height: 40
                                    radius: 8
                                    color: isActive
                                        ? Theme.withAlpha(Theme.primary, 0.18)
                                        : (rowHover.hovered
                                           ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.7)
                                           : "transparent")
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 12
                                        anchors.right: rowDelete.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (chat.service && chatRow.modelData)
                                            ? chat.service.chatDisplayTitle(chatRow.modelData)
                                            : ""
                                        color: chatRow.isActive
                                            ? Theme.primary : Theme.surfaceText
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                    }

                                    DankActionButton {
                                        id: rowDelete
                                        anchors.right: parent.right
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconName: "delete"
                                        iconSize: 16
                                        iconColor: Theme.surfaceVariantText
                                        opacity: rowHover.hovered ? 1 : 0
                                        Behavior on opacity {
                                            NumberAnimation { duration: 150 }
                                        }
                                        onClicked: if (chat.service)
                                            chat.service.deleteChat(chatRow.modelData.id)
                                    }

                                    HoverHandler {
                                        id: rowHover
                                        cursorShape: Qt.PointingHandCursor
                                    }

                                    TapHandler {
                                        onTapped: {
                                            if (!chatRow.modelData) return;
                                            chat.historyOpen = false;
                                            if (chat.service)
                                                chat.service.openChat(chatRow.modelData.id);
                                        }
                                    }
                                }
                            }

                            Text {
                                visible: !chat.service
                                         || chat.service.chats.length === 0
                                text: "No saved chats yet"
                                color: Theme.surfaceVariantText
                                font.pixelSize: 12
                                anchors.horizontalCenter: parent.horizontalCenter
                                topPadding: 12
                            }
                        }

                        ScrollBar.vertical: DankScrollbar {}
                    }
                }
            }
        }

        ChatComposer {
            id: composer
            Layout.fillWidth: true
            service: chat.service
            placeholder: chat.service ? chat.service.placeholder : "Ask anything…"
            onSubmitted: (text, images) => {
                // While a user message is being edited the composer
                // submit performs the edit (drops everything after
                // that message, regenerates); otherwise a normal send.
                if (chat.service && chat.service.editingMessageId.length > 0)
                    chat.service.editUserMessage(chat.service.editingMessageId, text);
                else
                    chat.service.sendMessage(text, images);
            }
            onEscapePressed: {
                if (chat.state === "settings")
                    chat.state = "chat";
                else if (chat.service && chat.service.editingMessageId.length > 0)
                    chat.service.cancelEditUserMessage();
                else if (chat.panel)
                    chat.panel.hide();
            }
            onNewChatRequested: {
                if (chat.service) {
                    chat.service.newChat();
                    chat.state = "chat";
                }
            }

            Connections {
                target: chat.service
                // Edit requested from a message bubble: the composer
                // receives the message text and takes focus.
                function onEditRequested(text) {
                    composer.setText(text);
                    composer.focusInput();
                }
            }
        }

        // Bottom bar: provider chip, model chip, MCP toggle, then
        // optional-params popup bottom-left; context meter pinned to
        // the far right as an overlay. The RowLayout is anchored
        // inside a wrapper so the meter never participates in the
        // row's minimum width — in a narrow panel the row may
        // overflow (pre-existing), but the meter stays visible at
        // the right edge.
        Item {
            id: bottomBarWrap
            Layout.fillWidth: true
            implicitHeight: bottomBar.implicitHeight

            RowLayout {
                id: bottomBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                ModelSelector {
                    service: chat.service
                }

            // Image attach chip: opens the file picker (clipboard paste
            // in the composer is the other ingest path). Same chip
            // shape and hover treatment as the MCP toggle.
            Rectangle {
                id: attachChip
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 34
                implicitHeight: 34
                radius: 8
                color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
                    opacity: attachHover.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 250 } }
                }

                DankIcon {
                    anchors.centerIn: parent
                    name: "attach_file"
                    size: 18
                    color: attachHover.hovered
                           ? Theme.primary : Theme.surfaceVariantText
                    Behavior on color { ColorAnimation { duration: 250 } }
                }

                HoverHandler {
                    id: attachHover
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: attachTip.hovering = hovered
                }

                TapHandler {
                    onTapped: {
                        attachTip.close();
                        composer.attachFromFile();
                    }
                }
            }

            // MCP tools master switch: construction icon, primary when
            // tools are on. Same chip shape and hover treatment as the
            // model selector's zones (overlay fade + pointing cursor).
            Rectangle {
                id: mcpChip
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 34
                implicitHeight: 34
                radius: 8
                color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                readonly property bool on: chat.service
                    ? chat.service.mcpToolsEnabled : false

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
                    opacity: mcpHover.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 250 } }
                }

                DankIcon {
                    anchors.centerIn: parent
                    name: "construction"
                    size: 18
                    filled: mcpChip.on
                    color: mcpChip.on || mcpHover.hovered
                           ? Theme.primary : Theme.surfaceVariantText
                    Behavior on color { ColorAnimation { duration: 250 } }
                }

                HoverHandler {
                    id: mcpHover
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: mcpTip.hovering = hovered
                }

                TapHandler {
                    onTapped: {
                        mcpTip.close();
                        if (chat.service)
                            chat.service.setMcpToolsEnabled(
                                !chat.service.mcpToolsEnabled);
                    }
                }
            }

            // Native web tools switch (web_search / webfetch): language
            // icon, primary when on. Same chip recipe as the MCP toggle.
            Rectangle {
                id: webChip
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 34
                implicitHeight: 34
                radius: 8
                color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                readonly property bool on: chat.service
                    ? chat.service.webToolsEnabled : false

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
                    opacity: webHover.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 250 } }
                }

                DankIcon {
                    anchors.centerIn: parent
                    name: "language"
                    size: 18
                    filled: webChip.on
                    color: webChip.on || webHover.hovered
                           ? Theme.primary : Theme.surfaceVariantText
                    Behavior on color { ColorAnimation { duration: 250 } }
                }

                HoverHandler {
                    id: webHover
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: webTip.hovering = hovered
                }

                TapHandler {
                    onTapped: {
                        webTip.close();
                        if (chat.service)
                            chat.service.setWebToolsEnabled(
                                !chat.service.webToolsEnabled);
                    }
                }
            }

                Item { Layout.fillWidth: true }
            }

            // Context usage meter: ring fills with conversation
            // progress; hover opens an opaque token-count pill that
            // overlays the chips to its left (constant layout
            // footprint — narrow panels never re-flow). Pinned to the
            // bar's right edge OUTSIDE the RowLayout so its width is
            // never part of the row's minimum; z keeps it above.
            ContextMeter {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                service: chat.service
                z: 2
            }
        }
    }

    // Hover tooltips for the composer-bar chips: comic-bubble popups
    // that open above their anchor after a 1s dwell and close when
    // the pointer leaves (or the chip is pressed).
    BubbleTip {
        id: attachTip
        parent: attachChip
        tipText: "Attachments"
    }

    BubbleTip {
        id: mcpTip
        parent: mcpChip
        tipText: "MCP Toolsets"
    }

    BubbleTip {
        id: webTip
        parent: webChip
        tipText: "Enable Web Search"
    }

    // Settings view: fills the panel, on top of the chat, opened from
    // the panel bar's tune button (state: "settings"). Fades in/out on
    // state changes; visible tracks opacity so the view drops out of
    // interaction/rendering once the fade-out lands.
    NexusSettings {
        id: settingsView
        anchors.fill: parent
        opacity: chat.state === "settings" ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }
        service: chat.service
        onDismissRequested: chat.state = "chat"
    }
}
