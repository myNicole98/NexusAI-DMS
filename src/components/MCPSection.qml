import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets

  // MCP servers settings: one collapsible row per instance with a
  // name/URL/token editor, Connect action, and per-tool checkboxes.
  // Tokens persist in the keyring when available, else memory-only.
Item {
    id: root

    property var service: null
    // Which instance is expanded — only one at a time.
    property string expandedId: ""

    // Armed creation replay state for the tools-checkbox click
    // animation (mirrors ProvidersSection's MiniToggle pattern).
    property string animKey: ""
    property bool animFrom: false

    implicitHeight: body.implicitHeight

    // Compact switch (enable/disable server). Plain Rectangle +
    // MouseArea so the press is consumed here and never also toggles
    // the row's expand/collapse TapHandler.
    component MiniToggle : Rectangle {
        id: mini

        property bool checked: true
        signal toggled()

        width: 34
        height: 20
        radius: 10
        color: mini.shown ? Theme.primary
                          : Theme.withAlpha(Theme.outlineVariant, 0.5)
        Behavior on color { ColorAnimation { duration: 220 } }

        Rectangle {
            x: mini.shown ? mini.width - width - 2 : 2
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            radius: 8
            color: mini.shown ? Theme.surfaceContainerHighest
                              : Theme.surfaceVariantText
            Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }
        }

        property bool shown: checked

        function armFrom(state) {
            shown = state;
            armTimer.restart();
        }

        Timer {
            id: armTimer
            interval: 50
            onTriggered: mini.shown = Qt.binding(function () { return mini.checked; })
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: mini.toggled()
        }
    }

    // Small neutral icon button (no accent): used for row actions
    // (destructive delete).
    component NeutralIconButton : Rectangle {
        id: nib

        property string iconName: ""
        property int buttonHeight: 20
        property int iconSize: 14
        signal clicked()

        width: buttonHeight + 10
        height: buttonHeight
        radius: 6
        color: nibHover.hovered ? Theme.withAlpha(Theme.surfaceContainerHighest, 0.9)
                                : Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
        Behavior on color { ColorAnimation { duration: 200 } }

        DankIcon {
            anchors.centerIn: parent
            name: nib.iconName
            size: nib.iconSize
            color: Theme.surfaceVariantText
        }

        HoverHandler { id: nibHover; cursorShape: Qt.PointingHandCursor }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: nib.clicked()
        }
    }

    // Tool cell: checkbox + name + description (one per column).
    component ToolCheckRow : Rectangle {
        id: toolRow

        property string label: ""
        property string description: ""
        property bool checked: false
        property string serverId: ""
        // Armed creation replay state for the checkbox animation.
        property bool shownChecked: checked
        property real checkScale: 1.0
        signal toggled()

        function armFrom(state) {
            shownChecked = state;
            armTimer.restart();
        }

        Timer {
            id: armTimer
            interval: 50
            onTriggered: {
                toolRow.shownChecked = Qt.binding(function () { return toolRow.checked; });
                checkBounce.restart();
            }
        }

        height: 56
        radius: 8
        color: toolRow.checked
            ? Theme.withAlpha(Theme.primary, 0.14)
            : Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
            opacity: toolHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        HoverHandler { id: toolHover; cursorShape: Qt.PointingHandCursor }

        SequentialAnimation {
            id: checkBounce
            NumberAnimation {
                target: toolRow; property: "checkScale"
                to: 1.15; duration: 140; easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                target: toolRow; property: "checkScale"
                to: 1.0; duration: 240; easing.type: Easing.InOutQuad
            }
        }

        Item {
            id: checkBox
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            height: 20
            scale: toolRow.checkScale

            DankIcon {
                anchors.fill: parent
                name: "check_box_outline_blank"
                size: 20
                visible: opacity > 0.01
                opacity: toolRow.shownChecked ? 0 : 1
                color: toolRow.shownChecked ? Theme.primary : Theme.surfaceVariantText
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }
            }

            DankIcon {
                anchors.fill: parent
                name: "check_box"
                size: 20
                visible: opacity > 0.01
                opacity: toolRow.shownChecked ? 1 : 0
                color: Theme.primary
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }
            }
        }

        ColumnLayout {
            anchors.left: checkBox.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: toolRow.label
                color: Theme.surfaceText
                font.pixelSize: 13
                font.family: Theme.monoFontFamily
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: toolRow.description.length > 0
                text: toolRow.description
                color: Theme.surfaceVariantText
                font.pixelSize: 11
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        TapHandler {
            id: tapPoint
            onTapped: {
                checkBounce.restart();
                toolRow.toggled();
            }
        }
    }

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 10

        // ── Section header ────────────────────────────────────────
        RowLayout {
            id: headerRow
            Layout.fillWidth: true

            Text {
                text: "MCP"
                color: Theme.primary
                font.pixelSize: 13
                font.bold: true
            }

            Item { Layout.fillWidth: true }

            DankButton {
                text: "Add MCP Server"
                iconName: "add"
                buttonHeight: 36
                onClicked: if (root.service) root.expandedId = root.service.addMcpServer()
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !root.service || root.service.mcpServers.length === 0
            text: "No MCP servers yet — add one to expose its tools to the chat."
            color: Theme.surfaceVariantText
            font.pixelSize: 12
        }

        // ── Instance list ─────────────────────────────────────────
        // Array model: the service's reassignment pattern rebuilds the
        // rows on every write. State-change animations replay on the
        // fresh row via the animKey/animFrom handoff.
        Repeater {
            model: root.service ? root.service.mcpServers : []

            delegate: ColumnLayout {
                id: block

                required property var modelData

                readonly property string sid: modelData && modelData.id ? String(modelData.id) : ""
                readonly property bool expanded: root.expandedId === sid
                readonly property string keyStatus:
                    root.service && sid.length > 0 ? root.service.mcpKeyStatus(sid) : "none"
                readonly property string keyMessageText:
                    root.service && root.service.mcpKeyMessages && sid.length > 0
                    ? (root.service.mcpKeyMessages[sid] ? String(root.service.mcpKeyMessages[sid]) : "")
                    : ""
                readonly property bool connected:
                    root.service && root.service.mcpConnected && sid.length > 0
                    && root.service.mcpConnected[sid] === true
                readonly property string connectionErrorText:
                    root.service && root.service.mcpConnectionErrors && sid.length > 0
                    ? (root.service.mcpConnectionErrors[sid] ? String(root.service.mcpConnectionErrors[sid]) : "")
                    : ""
                readonly property bool connecting:
                    root.service && root.service._mcpConnectingId === sid
                readonly property var serviceForRow:
                    root.service ? root.service._mcpServiceFor(sid) : null
                readonly property string toolsCountText: {
                    var disc = (modelData && modelData.discovered) || [];
                    var en = (modelData && modelData.enabledTools) || [];
                    var shown = 0;
                    for (var t = 0; t < disc.length; t++) {
                        var tn = disc[t] && disc[t].name ? String(disc[t].name) : "";
                        if (!tn) continue;
                        if (en.indexOf(tn) >= 0) shown++;
                    }
                    return disc.length > 0 ? shown + " of " + disc.length + " tools enabled" : "";
                }

                Layout.fillWidth: true
                spacing: 4

                // Collapsed row: chevron + name + enable toggle + delete.
                Rectangle {
                    id: serverRow

                    Layout.fillWidth: true
                    implicitHeight: 72
                    radius: 6
                    color: block.expanded
                        ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.3)
                        : Theme.withAlpha(Theme.surfaceContainerHigh, 0.22)
                    Behavior on color { ColorAnimation { duration: 250 } }

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.3)
                        opacity: rowHover.hovered ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 250 } }
                    }

                    readonly property bool off:
                        block.modelData && block.modelData.enabled === false

                    HoverHandler {
                        id: rowHover
                        cursorShape: Qt.PointingHandCursor
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 8

                        DankIcon {
                            name: "expand_more"
                            size: 22
                            color: Theme.surfaceVariantText
                            rotation: block.expanded ? 0 : -90
                            opacity: serverRow.off ? 0.45 : 1
                            Behavior on rotation {
                                RotationAnimation {
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }

                        // MCP icon: a small filled square so the row is
                        // visually anchored (no brand stem to bind).
                        Rectangle {
                            width: 24
                            height: 24
                            radius: 6
                            color: Theme.withAlpha(Theme.primary, 0.18)
                            opacity: serverRow.off ? 0.45 : 1
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                            DankIcon {
                                anchors.centerIn: parent
                                name: "handyman"
                                size: 16
                                color: Theme.primary
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            opacity: serverRow.off ? 0.45 : 1
                            Behavior on opacity { NumberAnimation { duration: 200 } }

                            Text {
                                Layout.fillWidth: true
                                text: block.modelData && block.modelData.name ? String(block.modelData.name) : ""
                                color: Theme.surfaceText
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }

                            Text {
                                Layout.fillWidth: true
                                text: {
                                    if (block.connected)
                                        return "Connected · " + block.toolsCountText;
                                    if (block.connecting)
                                        return "Connecting…";
                                    if (block.connectionErrorText.length > 0)
                                        return "Not connected · " + block.connectionErrorText;
                                    return "Not connected";
                                }
                                color: block.connected ? Theme.primary
                                                      : (block.connectionErrorText.length > 0 ? Theme.error : Theme.surfaceVariantText)
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }

                        MiniToggle {
                            Layout.alignment: Qt.AlignVCenter
                            checked: block.modelData
                                     ? block.modelData.enabled !== false : true
                            onToggled: {
                                if (!root.service || block.sid.length === 0) return;
                                root.animKey = "s:" + block.sid;
                                root.animFrom = block.modelData
                                    ? block.modelData.enabled !== false : true;
                                root.service.setMcpServerEnabled(block.sid, !root.animFrom);
                            }
                            Component.onCompleted: {
                                if (root.animKey === "s:" + block.sid) {
                                    armFrom(root.animFrom);
                                    root.animKey = "";
                                }
                            }
                        }

                        NeutralIconButton {
                            iconName: "delete"
                            Layout.alignment: Qt.AlignVCenter
                            onClicked: {
                                if (root.expandedId === block.sid) root.expandedId = "";
                                if (root.service && block.sid.length > 0)
                                    root.service.removeMcpServer(block.sid);
                            }
                        }
                    }

                    TapHandler {
                        onTapped: root.expandedId = block.expanded ? "" : block.sid
                    }
                }

                // Expanded editor card.
                Rectangle {
                    id: editorCard
                    Layout.fillWidth: true
                    readonly property int fullHeight: cardBody.implicitHeight + 24
                    property real animHeight: block.expanded ? fullHeight : 0
                    Behavior on animHeight {
                        NumberAnimation {
                            duration: 220
                            easing.type: Easing.OutCubic
                        }
                    }
                    Layout.preferredHeight: animHeight
                    visible: animHeight > 0.5
                    clip: true
                    opacity: block.expanded ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    radius: 8
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.35)

                    ColumnLayout {
                        id: cardBody
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 10

                        DankTextField {
                            Layout.fillWidth: true
                            labelText: "Name"
                            text: block.modelData && block.modelData.name ? String(block.modelData.name) : ""
                            onEditingFinished: if (root.service && block.sid.length > 0
                                && text !== (block.modelData && block.modelData.name ? String(block.modelData.name) : ""))
                                root.service.renameMcpServer(block.sid, text)
                        }

                        DankTextField {
                            Layout.fillWidth: true
                            labelText: "MCP server URL"
                            placeholderText: "https://example.test/mcp"
                            text: block.modelData && block.modelData.url ? String(block.modelData.url) : ""
                            onEditingFinished: if (root.service && block.sid.length > 0
                                && text.trim() !== (block.modelData && block.modelData.url ? String(block.modelData.url) : ""))
                                root.service.setMcpServerUrl(block.sid, text)
                        }

                        DankTextField {
                            Layout.fillWidth: true
                            labelText: "Auth token"
                            placeholderText: {
                                if (!root.service || block.sid.length === 0) return "Paste auth token";
                                var inst = block.modelData;
                                var envName = inst ? root.service.mcpEnvVar(String(inst.name || "")) : "";
                                return envName.length > 0 ? envName : "Paste auth token";
                            }
                            text: root.service && root.service.mcpSessionTokens && block.sid.length > 0
                                ? (root.service.mcpSessionTokens[block.sid] || "") : ""
                            echoMode: passwordVisible ? TextInput.Normal : TextInput.Password
                            showPasswordToggle: true
                            onEditingFinished: if (root.service && block.sid.length > 0
                                && text.length > 0
                                && text !== (root.service.mcpSessionTokens && root.service.mcpSessionTokens[block.sid]
                                             ? String(root.service.mcpSessionTokens[block.sid]) : "")) {
                                root.service.setMcpServerToken(block.sid, text);
                                // Token just landed — try to connect now.
                                root.service._connectMcpServer(block.sid);
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: block.keyMessageText.length > 0
                            text: block.keyMessageText
                            color: Theme.error
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: block.keyStatus === "none"
                            text: {
                                if (!root.service || !block.modelData) return "";
                                var inst = block.modelData;
                                var envName = root.service.mcpEnvVar(String(inst.name || ""));
                                return envName.length > 0
                                    ? "No token — set one or export " + envName
                                    : "No token — set one above";
                            }
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: block.keyStatus.indexOf("env:") === 0
                            text: "Using env var " + block.keyStatus.substring(4)
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: !root.service || !root.service.keyringAvailable
                            text: "secret-tool not found — tokens last this session only; use env vars for persistence"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        // Single Connect/Reconnect button (mirrors the
                        // providers' "Refresh models" placement; no
                        // Disconnect — disabling the row disconnects).
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            DankButton {
                                text: {
                                    if (block.connecting) return "Connecting…";
                                    if (block.connected) return "Reconnect";
                                    return "Connect";
                                }
                                iconName: "link"
                                buttonHeight: 36
                                enabled: root.service && !block.connecting
                                         && block.modelData && block.modelData.url
                                         && String(block.modelData.url).length > 0
                                onClicked: if (root.service && block.sid.length > 0) {
                                    root.service._connectMcpServer(block.sid);
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: block.connectionErrorText.length > 0
                            text: block.connectionErrorText
                            color: Theme.error
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Text {
                            text: "Available tools"
                            color: Theme.primary
                            font.pixelSize: 12
                            font.bold: true
                            visible: block.connected
                        }

                        // Bulk-select row. Sits next to the "Available
                        // tools" header so the affordance is obvious
                        // without growing the row height. Disabled when
                        // there are no tools to operate on.
                        RowLayout {
                            Layout.fillWidth: true
                            visible: block.connected
                                     && block.modelData && block.modelData.discovered
                                     && block.modelData.discovered.length > 0
                            spacing: 6

                            Item { Layout.fillWidth: true }

                            DankButton {
                                text: "Select all"
                                iconName: "done_all"
                                buttonHeight: 26
                                backgroundColor: Theme.withAlpha(
                                    Theme.surfaceContainerHighest, 0.5)
                                textColor: Theme.surfaceText
                                onClicked: if (root.service && block.sid.length > 0)
                                    root.service.selectAllMcpTools(block.sid)
                            }

                            DankButton {
                                text: "Deselect all"
                                iconName: "remove_done"
                                buttonHeight: 26
                                backgroundColor: Theme.withAlpha(
                                    Theme.surfaceContainerHighest, 0.5)
                                textColor: Theme.surfaceText
                                onClicked: if (root.service && block.sid.length > 0)
                                    root.service.deselectAllMcpTools(block.sid)
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: !block.connected
                            text: "Connect to the server to list its tools."
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: block.connected
                                     && (!block.modelData || !block.modelData.discovered
                                         || block.modelData.discovered.length === 0)
                            text: "No tools returned by the server."
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            visible: block.connected
                                     && block.modelData && block.modelData.discovered
                                     && block.modelData.discovered.length > 0

                            Repeater {
                                model: {
                                    if (!block.modelData || !block.modelData.discovered) return [];
                                    var disc = block.modelData.discovered;
                                    var en = block.modelData.enabledTools || [];
                                    var out = [];
                                    for (var i = 0; i < disc.length; i++) {
                                        var t = disc[i];
                                        if (!t || !t.name) continue;
                                        var checked = en.indexOf(String(t.name)) >= 0;
                                        out.push({
                                            name: String(t.name),
                                            description: String(t.description || ""),
                                            checked: checked
                                        });
                                    }
                                    return out;
                                }

                                delegate: ToolCheckRow {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    label: modelData && modelData.name ? String(modelData.name) : ""
                                    description: modelData && modelData.description
                                                 ? String(modelData.description) : ""
                                    checked: modelData ? !!modelData.checked : false
                                    serverId: block.sid
                                    onToggled: {
                                        if (!root.service || block.sid.length === 0
                                            || !modelData || !modelData.name) return;
                                        root.animKey = "t:" + block.sid + "/"
                                            + String(modelData.name);
                                        root.animFrom = !!modelData.checked;
                                        root.service.toggleMcpTool(block.sid, String(modelData.name));
                                    }
                                    Component.onCompleted: {
                                        var key = "t:" + block.sid + "/"
                                            + (modelData && modelData.name ? String(modelData.name) : "");
                                        if (root.animKey === key) {
                                            armFrom(root.animFrom);
                                            root.animKey = "";
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}