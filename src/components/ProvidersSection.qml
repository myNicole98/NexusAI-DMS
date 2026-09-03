import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import "../lib/Providers.js" as Providers
import "../lib/ModelIcons.js" as ModelIcons
import "../lib/FuzzyMatch.js" as FuzzyMatch

// Provider settings: one collapsible row per instance with an editor
// card (name, base URL, key, models grid). Keys persist in the
// keyring when secret-tool is available, else memory-only.
Item {
    id: root

    property var service: null
    // Which instance is expanded — only one at a time.
    property string expandedId: ""
    // Expanded-card grid state, hoisted so it survives the delegate
    // rebuilds every service write triggers.
    property string modelFilterText: ""
    property real modelGridY: 0
    property bool _gridRebuilding: false
    function markGridRebuild() {
        _gridRebuilding = true;
        gridSettleTimer.restart();
    }
    Timer {
        id: gridSettleTimer
        interval: 0
        onTriggered: {
            root._gridRebuilding = false;
            modelFlick.contentY = Math.min(root.modelGridY,
                Math.max(0, modelFlick.contentHeight - modelFlick.height));
        }
    }
    // One-shot animation handoff: a click arms a key so the delegate
    // recreated by the service write can replay the state change (it
    // is born at the new value; replaying from the old one is the
    // only way a rebuilt row can animate).
    property string animKey: ""
    property bool animFrom: false

    implicitHeight: body.implicitHeight

    // Add-provider row: brand icon + registry display name + subtle
    // wire-format tag.
    component AddRow : Rectangle {
        id: addRow

        property string title: ""
        property string tag: ""
        property string iconStem: ""
        signal chosen()

        width: parent ? parent.width : 280
        height: 48
        radius: 6
        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.22)

        // Hover state layer (model-selector chip pattern): fixed tint,
        // opacity fade. MouseArea instead of HoverHandler — the
        // reliable hover source inside a Popup.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.45)
            opacity: addHover.containsMouse ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        MouseArea {
            id: addHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: addRow.chosen()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 10
            spacing: 10

            BrandIcon {
                Layout.alignment: Qt.AlignVCenter
                size: 20
                stem: addRow.iconStem
            }

            Text {
                Layout.fillWidth: true
                text: addRow.title
                color: Theme.surfaceText
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            Text {
                text: addRow.tag
                color: Theme.surfaceVariantText
                font.pixelSize: 11
            }
        }
    }

    // Compact switch (enable/disable provider). Plain Rectangle +
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

        // Armed creation replay: the click that toggles this provider
        // rebuilds the row, so the fresh toggle starts from the
        // pre-click state and rebinds 50ms later — the knob slide and
        // color fade play on the new row.
        property bool shown: checked

        function armFrom(state) {
            shown = state;
            armTimer.restart();
        }

        Timer {
            id: armTimer
            interval: 50
            onTriggered: mini.shown = Qt.binding(function() { return mini.checked; })
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: mini.toggled()
        }
    }

    // Small neutral icon button (no accent): used for destructive and
    // additive row actions.
    component NeutralIconButton : Rectangle {
        id: nib

        property string iconName: ""
        property int buttonHeight: 20
        property int iconSize: 14
        // Accent mode: primary fill + strong icon (e.g. the custom
        // model "+" once the field has text).
        property bool accent: false
        signal clicked()

        width: buttonHeight + 10
        height: buttonHeight
        radius: 6
        color: nib.accent ? (nibHover.hovered ? Theme.primary
                                              : Theme.withAlpha(Theme.primary, 0.85))
                          : (nibHover.hovered ? Theme.withAlpha(Theme.surfaceContainerHighest, 0.9)
                                              : Theme.withAlpha(Theme.surfaceContainerHighest, 0.5))
        Behavior on color { ColorAnimation { duration: 200 } }

        DankIcon {
            anchors.centerIn: parent
            name: nib.iconName
            size: nib.iconSize
            color: nib.accent ? Theme.surfaceText : Theme.surfaceVariantText
        }

        HoverHandler { id: nibHover; cursorShape: Qt.PointingHandCursor }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: nib.clicked()
        }
    }

    // Model cell: checkbox icon + brand icon + display label, with a
    // pencil to rename the model visually (the logical id stays
    // untouched — display labels live on the provider instance).
    component ModelCheckRow : Rectangle {
        id: modelRow

        property string label: ""
        property string iconStem: ""
        property bool checked: false
        property string providerId: ""
        property string displayLabel: label
        property bool editing: false
        property bool removable: false
        signal removed()
        // 1.0 at rest; entrance replay bounces it.
        property real checkScale: 1.0
        // Armed creation replay state (see MiniToggle.shown).
        property bool shownChecked: checked
        signal toggled()
        signal renamed(string text)

        function armFrom(state) {
            shownChecked = state;
            armTimer.restart();
        }

        function commitRename() {
            if (!editing) return;
            editing = false;
            renamed(editInput.text);
        }

        Timer {
            id: armTimer
            interval: 50
            onTriggered: {
                modelRow.shownChecked = Qt.binding(function() { return modelRow.checked; });
                checkBounce.restart();
            }
        }

        height: 56
        radius: 8
        color: modelRow.checked
            ? Theme.withAlpha(Theme.primary, 0.14)
            : Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)

        // Hover state layer, same as the chip: tint + opacity fade.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
            opacity: modelHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        HoverHandler { id: modelHover; cursorShape: Qt.PointingHandCursor }

        SequentialAnimation {
            id: checkBounce
            NumberAnimation {
                target: modelRow; property: "checkScale"
                to: 1.15; duration: 140; easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                target: modelRow; property: "checkScale"
                to: 1.0; duration: 240; easing.type: Easing.InOutQuad
            }
        }

        // Checkbox: crossfades between the empty and checked boxes so
        // the tick itself animates (the icon swap alone is instant).
        Item {
            id: checkBox
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            height: 20
            scale: modelRow.checkScale

            DankIcon {
                anchors.fill: parent
                name: "check_box_outline_blank"
                size: 20
                visible: opacity > 0.01
                opacity: modelRow.shownChecked ? 0 : 1
                color: modelRow.shownChecked ? Theme.primary : Theme.surfaceVariantText
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }
            }

            DankIcon {
                anchors.fill: parent
                name: "check_box"
                size: 20
                visible: opacity > 0.01
                opacity: modelRow.shownChecked ? 1 : 0
                color: Theme.primary
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }
            }
        }

        BrandIcon {
            size: 22
            anchors.left: checkBox.right
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            stem: modelRow.iconStem
        }

        Text {
            id: labelText
            visible: !modelRow.editing
            anchors.left: parent.left
            anchors.leftMargin: 72
            anchors.right: modelRow.removable ? removeZone.left : editZone.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: modelRow.displayLabel
            color: Theme.surfaceText
            font.pixelSize: 13
            elide: Text.ElideRight
        }

        // Remove: custom models only.
        Item {
            id: removeZone
            visible: modelRow.removable
            anchors.right: editZone.left
            anchors.verticalCenter: parent.verticalCenter
            width: 26
            height: parent.height

            DankIcon {
                anchors.centerIn: parent
                name: "close"
                size: 14
                color: removeZoneHover.hovered ? Theme.error : Theme.surfaceVariantText
                Behavior on color { ColorAnimation { duration: 200 } }
            }

            HoverHandler {
                id: removeZoneHover
                cursorShape: Qt.PointingHandCursor
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: modelRow.removed()
            }
        }

        // Inline rename editor: Enter commits, Escape cancels, focus
        // loss commits. Typing the logical id clears the rename.
        TextInput {
            id: editInput
            visible: modelRow.editing
            anchors.left: parent.left
            anchors.leftMargin: 72
            anchors.right: editZone.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.surfaceText
            font.pixelSize: 13
            clip: true
            selectByMouse: true
            onAccepted: modelRow.commitRename()
            onActiveFocusChanged: if (!activeFocus) modelRow.commitRename()
            Keys.onEscapePressed: modelRow.editing = false
        }

        // Pencil: opens the inline rename editor.
        Item {
            id: editZone
            width: 26
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height

            DankIcon {
                anchors.centerIn: parent
                name: "edit"
                size: 14
                color: editZoneHover.hovered ? Theme.primary
                                             : Theme.surfaceVariantText
                Behavior on color { ColorAnimation { duration: 200 } }
            }

            HoverHandler {
                id: editZoneHover
                cursorShape: Qt.PointingHandCursor
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (modelRow.editing) return;
                    modelRow.editing = true;
                    editInput.text = modelRow.displayLabel;
                    editInput.forceActiveFocus();
                    editInput.cursorPosition = editInput.text.length;
                }
            }
        }

        TapHandler {
            id: tapPoint
            onTapped: {
                // Taps over the action zones rename/remove, not toggle.
                var exclude = 32 + (modelRow.removable ? 26 : 0);
                if (tapPoint.point.position.x > modelRow.width - exclude) return;
                checkBounce.restart();
                modelRow.toggled();
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
                text: "Providers"
                color: Theme.primary
                font.pixelSize: 13
                font.bold: true
            }

            Item { Layout.fillWidth: true }

            DankButton {
                text: "Add provider"
                iconName: "add"
                buttonHeight: 36
                onClicked: addPicker.visible ? addPicker.close() : addPicker.open()
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !root.service || root.service.providers.length === 0
            text: "No providers yet — add one to start."
            color: Theme.surfaceVariantText
            font.pixelSize: 12
        }

        // ── Instance list ─────────────────────────────────────────
        // Array model: the service's reassignment pattern rebuilds the
        // rows on every write. State-change animations replay on the
        // fresh row via the animKey/animFrom handoff (see MiniToggle
        // and ModelCheckRow armFrom).
        Repeater {
            model: root.service ? root.service.providers : []

            delegate: ColumnLayout {
                id: block

                required property var modelData

                readonly property string pid: modelData && modelData.id ? String(modelData.id) : ""
                readonly property var reg:
                    modelData && Providers.REGISTRY[modelData.type] ? Providers.REGISTRY[modelData.type] : null
                readonly property bool needsKey: reg ? !!reg.needsKey : false
                readonly property string keyStatus:
                    root.service && pid.length > 0 ? root.service.keyStatus(pid) : "none"
                readonly property bool missingKey: keyStatus === "none" && needsKey
                readonly property bool expanded: root.expandedId === pid
                readonly property string envVarName:
                    reg && reg.envVar ? String(reg.envVar)
                    : (modelData && modelData.type === "custom" && modelData.name
                       ? Providers.customEnvVar(String(modelData.name)) : "")
                readonly property string keyStatusLine:
                    keyStatus === "keyring" ? "Stored in system keyring"
                    : keyStatus === "session" ? "Key set for this session"
                    : keyStatus.indexOf("env:") === 0 ? "Using env var " + keyStatus.substring(4)
                    : missingKey ? "No key — set one or export " + (envVarName.length > 0 ? envVarName : "an env var")
                    : "No key required"
                readonly property string modelsErrorText: {
                    if (!root.service || !root.service.modelsErrors || pid.length === 0) return "";
                    var m = root.service.modelsErrors[pid];
                    return m ? String(m) : "";
                }
                readonly property string keyMessageText:
                    root.service && root.service.keyMessages && pid.length > 0
                    ? (root.service.keyMessages[pid] ? String(root.service.keyMessages[pid]) : "")
                    : ""
                // Provider brand logo (providerIcon resolves the type,
                // e.g. google → the Gemini spark in icons/models/).
                // Provider logo stem — BrandIcon resolves the theme
                // folder (icons/dark|light), e.g. claude → anthropic.
                readonly property string iconStem:
                    modelData && modelData.type
                    ? ModelIcons.providerIcon(String(modelData.type)) : ""

                Layout.fillWidth: true
                spacing: 4

                // Collapsed row: chevron + brand icon + name, a
                // right-side enable toggle, (+ missing-key dot).
                // Disabled providers dim their identity.
                Rectangle {
                    id: providerRow

                    Layout.fillWidth: true
                    implicitHeight: 72
                    radius: 6
                    // Expanded tint swaps the base (restart-free: it
                    // only changes on the expand click).
                    color: block.expanded
                        ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.3)
                        : Theme.withAlpha(Theme.surfaceContainerHigh, 0.22)
                    Behavior on color { ColorAnimation { duration: 250 } }

                    // Hover state layer (model-selector chip pattern):
                    // fixed tint, opacity fade.
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

                        // Chevron: right when collapsed, rotates down
                        // when expanded (matches the card opening
                        // below the row).
                        DankIcon {
                            name: "expand_more"
                            size: 22
                            color: Theme.surfaceVariantText
                            rotation: block.expanded ? 0 : -90
                            opacity: providerRow.off ? 0.45 : 1
                            Behavior on rotation {
                                RotationAnimation {
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }

                        // Brand icon (theme folders via BrandIcon);
                        // hidden when no file exists for this type.
                        BrandIcon {
                            size: 24
                            stem: block.iconStem
                            Layout.alignment: Qt.AlignVCenter
                            opacity: providerRow.off ? 0.45 : 1
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: block.modelData && block.modelData.name ? String(block.modelData.name) : ""
                            color: Theme.surfaceText
                            font.pixelSize: 13
                            elide: Text.ElideRight
                            opacity: providerRow.off ? 0.45 : 1
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }

                        MiniToggle {
                            Layout.alignment: Qt.AlignVCenter
                            checked: block.modelData
                                     ? block.modelData.enabled !== false : true
                            onToggled: {
                                if (!root.service || block.pid.length === 0) return;
                                root.animKey = "p:" + block.pid;
                                root.animFrom = block.modelData
                                    ? block.modelData.enabled !== false : true;
                                root.service.setProviderEnabled(block.pid, !root.animFrom);
                            }
                            Component.onCompleted: {
                                if (root.animKey === "p:" + block.pid) {
                                    armFrom(root.animFrom);
                                    root.animKey = "";
                                }
                            }
                        }

                        NeutralIconButton {
                            iconName: "delete"
                            Layout.alignment: Qt.AlignVCenter
                            onClicked: {
                                if (root.expandedId === block.pid) root.expandedId = "";
                                if (root.service && block.pid.length > 0)
                                    root.service.removeProvider(block.pid);
                            }
                        }

                        Rectangle {
                            visible: block.missingKey
                            width: 8
                            height: 8
                            radius: 4
                            color: Theme.error
                        }
                    }

                    TapHandler {
                        onTapped: root.expandedId = block.expanded ? "" : block.pid
                    }
                }

                // Expanded editor card. The height/opacity animate so
                // the card slides open instead of popping in; content
                // clips during the transition.
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

                          // Persist on editingFinished, not per keystroke:
                          // every service write resets this Repeater and
                          // would kill the focused field.
                        DankTextField {
                            Layout.fillWidth: true
                            labelText: "Name"
                            text: block.modelData && block.modelData.name ? String(block.modelData.name) : ""
                            onEditingFinished: if (root.service && block.pid.length > 0
                                && text !== (block.modelData && block.modelData.name ? String(block.modelData.name) : ""))
                                root.service.renameProvider(block.pid, text)
                        }

                        DankTextField {
                            Layout.fillWidth: true
                            labelText: "Base URL"
                            placeholderText: "https://api.openai.com/v1"
                            text: block.modelData && block.modelData.baseUrl ? String(block.modelData.baseUrl) : ""
                            onEditingFinished: if (root.service && block.pid.length > 0
                                && text.trim() !== (block.modelData && block.modelData.baseUrl ? String(block.modelData.baseUrl) : ""))
                                root.service.setProviderUrl(block.pid, text)
                        }

                        DankTextField {
                            Layout.fillWidth: true
                            labelText: "API key"
                            placeholderText: block.envVarName
                            text: root.service && root.service.sessionKeys && block.pid.length > 0
                                ? (root.service.sessionKeys[block.pid] || "") : ""
                            echoMode: passwordVisible ? TextInput.Normal : TextInput.Password
                            showPasswordToggle: true
                            onEditingFinished: if (root.service && block.pid.length > 0
                                && text.length > 0
                                && text !== (root.service.sessionKeys && root.service.sessionKeys[block.pid] ? String(root.service.sessionKeys[block.pid]) : "")) {
                                root.service.setInstanceKey(block.pid, text);
                                root.service.refreshModels(block.pid);
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
                            visible: block.needsKey && root.service
                                && !root.service.keyringAvailable
                            text: "secret-tool not found — keys last this session only; use env vars for persistence"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            DankButton {
                                text: root.service && root.service.modelsRefreshing
                                    ? "Refreshing…" : "Refresh models"
                                iconName: "refresh"
                                buttonHeight: 36
                                enabled: root.service && !root.service.modelsRefreshing
                                onClicked: if (root.service && block.pid.length > 0)
                                    root.service.refreshModels(block.pid)
                            }

                            Item { Layout.fillWidth: true }
                        }

                        Text {
                            text: "Models"
                            color: Theme.primary
                            font.pixelSize: 12
                            font.bold: true
                        }

                        // Manually register a model id the discovery
                        // endpoint doesn't list; auto-checked so it's
                        // immediately usable.
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            DankTextField {
                                id: customModelField
                                Layout.fillWidth: true
                                placeholderText: "Add custom model"
                            }

                            NeutralIconButton {
                                iconName: "add"
                                buttonHeight: 36
                                iconSize: 18
                                accent: customModelField.text.trim().length > 0
                                onClicked: {
                                    var name = customModelField.text.trim();
                                    if (!root.service || block.pid.length === 0 || !name)
                                        return;
                                    root.service.addCustomModel(block.pid, name);
                                    customModelField.text = "";
                                }
                            }
                        }

                        DankTextField {
                            id: modelFilterField
                            Layout.fillWidth: true
                            placeholderText: "Search models"
                            showClearButton: true
                            text: root.modelFilterText
                            onTextChanged: root.modelFilterText = text
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: block.modelsErrorText.length > 0
                            text: block.modelsErrorText
                            color: Theme.error
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: (!block.modelData || !block.modelData.discovered
                                || block.modelData.discovered.length === 0)
                                && (!block.modelData || !block.modelData.customModels
                                || block.modelData.customModels.length === 0)
                            text: "No models discovered — set URL/key, refresh, or add a custom model id"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Item {
                            Layout.fillWidth: true
                            visible: block.modelData
                                && ((block.modelData.discovered && block.modelData.discovered.length > 0)
                                    || (block.modelData.customModels && block.modelData.customModels.length > 0))
                            Layout.preferredHeight: 352

                            Flickable {
                                id: modelFlick
                                anchors.fill: parent
                                clip: true
                                contentHeight: modelGrid.implicitHeight
                                boundsBehavior: Flickable.StopAtBounds
                                // Remember scroll only outside rebuild
                                // cycles — delegate add/remove clamps
                                // contentY transiently.
                                onContentYChanged: {
                                    if (root._gridRebuilding) return;
                                    root.modelGridY = contentY;
                                }
                                // While the rebuild cycle is live, keep
                                // the view pinned to the stored position
                                // as rows stream back in.
                                onContentHeightChanged: if (root._gridRebuilding)
                                    contentY = Math.min(root.modelGridY,
                                        Math.max(0, contentHeight - modelFlick.height))

                            Grid {
                                id: modelGrid
                                width: parent.width
                                columns: 2
                                columnSpacing: Theme.spacingS
                                rowSpacing: Theme.spacingXS

                            Repeater {
                                onItemAdded: root.markGridRebuild()
                                onItemRemoved: root.markGridRebuild()
                                // Discovered ∪ custom models (deduped).
                                model: {
                                    if (!block.modelData) return [];
                                    var fl = root.modelFilterText.toLowerCase();
                                    var out = [], seen = {};
                                    var disc = block.modelData.discovered || [];
                                    var cus = block.modelData.customModels || [];
                                    for (var i = 0; i < disc.length; i++) {
                                        if (!disc[i] || !disc[i].id || seen[String(disc[i].id)]) continue;
                                        var did = String(disc[i].id);
                                        var disp = root.service
                                            ? root.service.modelLabel(block.pid, did) : did;
                                        if (fl && !FuzzyMatch.matches(fl, did)
                                            && !FuzzyMatch.matches(fl,
                                                String(disp))) continue;
                                        seen[did] = true;
                                        out.push(disc[i]);
                                    }
                                    for (i = 0; i < cus.length; i++) {
                                        var cid = String(cus[i] || "");
                                        if (!cid || seen[cid]) continue;
                                        var cdisp = root.service
                                            ? root.service.modelLabel(block.pid, cid) : cid;
                                        if (fl && !FuzzyMatch.matches(fl, cid)
                                            && !FuzzyMatch.matches(fl,
                                                String(cdisp))) continue;
                                        seen[cid] = true;
                                        out.push({ id: cid, custom: true });
                                    }
                                    return out;
                                }

                                delegate: ModelCheckRow {
                                    required property var modelData

                                    width: (cardBody.width - Theme.spacingS) / 2
                                    label: modelData && modelData.id ? String(modelData.id) : ""
                                    providerId: block.pid
                                    displayLabel: root.service && modelData && modelData.id
                                        ? root.service.modelLabel(block.pid, String(modelData.id))
                                        : (modelData && modelData.id ? String(modelData.id) : "")
                                    iconStem: {
                                        // Unused read — dependency trick (see
                                        // ModelSelector.activeStem): subscribes
                                        // this binding to modelIconStems so it
                                        // re-runs when the icon scan lands.
                                        var _scan = root.service ? root.service.modelIconStems : null;
                                        return modelData && modelData.id && block.modelData
                                            ? ModelIcons.iconForModel(String(modelData.id),
                                                                      String(block.modelData.type || ""))
                                            : "";
                                    }
                                    checked: block.modelData && block.modelData.checkedModels
                                        && modelData && modelData.id
                                        ? block.modelData.checkedModels.indexOf(String(modelData.id)) >= 0
                                        : false
                                    onRenamed: (text) => {
                                        if (!root.service || block.pid.length === 0
                                            || !modelData || !modelData.id) return;
                                        var clean = String(text || "").trim();
                                        if (clean === String(modelData.id)) clean = "";
                                        root.service.setModelLabel(block.pid, String(modelData.id), clean);
                                    }
                                    removable: modelData ? modelData.custom === true : false
                                    onRemoved: {
                                        if (!root.service || block.pid.length === 0
                                            || !modelData || !modelData.id) return;
                                        root.service.removeCustomModel(block.pid, String(modelData.id));
                                    }
                                    onToggled: {
                                        if (!root.service || block.pid.length === 0
                                            || !modelData || !modelData.id) return;
                                        root.animKey = "m:" + block.pid + "/"
                                            + String(modelData.id);
                                        root.animFrom = block.modelData.checkedModels
                                            ? block.modelData.checkedModels.indexOf(String(modelData.id)) >= 0
                                            : false;
                                        root.service.toggleModel(block.pid, String(modelData.id));
                                    }
                                    Component.onCompleted: {
                                        var key = "m:" + block.pid + "/"
                                            + (modelData && modelData.id ? String(modelData.id) : "");
                                        if (root.animKey === key) {
                                            armFrom(root.animFrom);
                                            root.animKey = "";
                                        }
                                    }
                                }
                            }
                            }
                        }

                            // Scroll indicator: pill sized/positioned by
                            // the viewport ratio.
                            Item {
                                anchors.right: parent.right
                                anchors.rightMargin: 2
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: 3
                                visible: modelFlick.contentHeight > modelFlick.height + 1

                                Rectangle {
                                    radius: width / 2
                                    width: parent.width
                                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.5)
                                    readonly property real maxScroll: Math.max(
                                        1, modelFlick.contentHeight - modelFlick.height)
                                    height: Math.max(24,
                                        parent.height * (modelFlick.height
                                            / Math.max(1, modelFlick.contentHeight)))
                                    y: (modelFlick.contentY / maxScroll) * (parent.height - height)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Add-provider picker (below the header button) ─────────────
    Popup {
        id: addPicker
        parent: root
        y: headerRow.height + 4
        x: Math.max(0, root.width - width)
        width: 300
        // The taller branded rows no longer fit the old 420 cap —
        // grow the popup instead of scrolling it (a Flickable here
        // broke row hover; rows must sit directly in contentItem).
        height: Math.min(640, contentItem.implicitHeight + 16)
        padding: 8

        background: Rectangle {
            radius: 8
            color: Theme.withAlpha(Theme.surfaceContainer, 0.97)
            border.color: Theme.surfaceVariantAlpha
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 4

            Repeater {
                model: Providers.REGISTRY_TYPES

                delegate: AddRow {
                    required property var modelData

                    title: Providers.REGISTRY[modelData] ? Providers.REGISTRY[modelData].name : String(modelData)
                    tag: Providers.REGISTRY[modelData] ? Providers.REGISTRY[modelData].format : ""
                    iconStem: ModelIcons.providerIcon(String(modelData))
                    onChosen: {
                        if (!root.service) return;
                        root.expandedId = root.service.addProvider(String(modelData));
                        addPicker.close();
                    }
                }
            }
        }
    }
}
