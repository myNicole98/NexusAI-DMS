import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import "../lib/ModelIcons.js" as ModelIcons
import "../lib/FuzzyMatch.js" as FuzzyMatch

  // Bottom-bar chip, two zones: active model + chevron (model picker:
  // pinned first, then per-provider groups), and tune icon (params
  // popup). Popups open upward; picking a model from another instance
  // switches the active provider too.
Rectangle {
    id: selector

    property var service: null

    radius: 8
    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
    implicitHeight: 34

    // No-op placeholder while the service is missing; keep the chip
    // visible so the layout is stable.
    readonly property string modelLabel:
        (service && service.activeModel && service.activeModel.length > 0)
            ? service.modelLabel(service.activeProviderId, service.activeModel)
            : "set model"
    // Brand stem of the model in use ("" when none is active).
    readonly property string activeStem: {
        // Unused on purpose: reading modelIconStems is the QML
        // dependency that re-runs this binding when the startup icon
        // scan lands — iconForModel also matches AUTO_RULES, a plain
        // lib var that cannot notify on its own.
        var _scan = service ? service.modelIconStems : null;
        return (service && service.activeModel && service.activeModel.length > 0)
            ? ModelIcons.iconForModel(service.activeModel,
                service.activeInstance && service.activeInstance.type
                    ? String(service.activeInstance.type) : "")
            : "";
    }

    // Provider groups the user collapsed in the picker (pid → true).
    property var collapsedProviders: ({})
    function toggleCollapsed(pid) {
        var m = {};
        for (var k in collapsedProviders) m[k] = collapsedProviders[k];
        if (m[pid]) delete m[pid];
        else m[pid] = true;
        collapsedProviders = m;
    }

    // Flat rows for the picker list: header rows and model rows.
    // Reads pinnedModels/providers (reassigned on every change) so the
    // ListView model binding re-evaluates through the service's
    // reassignment pattern. Stale pins (provider deleted) are skipped.
    function buildRows(filter) {
        if (!service) return [];
        var f = String(filter || "").toLowerCase();
        var rows = [];
        var pins = service.pinnedModels || [];
        for (var i = 0; i < pins.length; i++) {
            var rec = pins[i];
            if (!rec || !rec.providerId || !rec.model) continue;
            var pinInst = service.getProvider(rec.providerId);
            if (!pinInst || pinInst.enabled === false) continue;
            if (rows.length === 0)
                rows.push({ kind: "header", name: "Pinned", type: "" });
            rows.push({ kind: "model", providerId: String(rec.providerId),
                        model: String(rec.model),
                        type: String(pinInst.type) });
        }
        var provs = service.providers || [];
        for (var j = 0; j < provs.length; j++) {
            var p = provs[j];
            if (!p || !p.id) continue;
            // Disabled providers vanish from the picker.
            if (p.enabled === false) continue;
            var checked = p.checkedModels || [];
            if (checked.length === 0) continue;
            var collapsed = collapsedProviders[String(p.id)] === true;
            rows.push({ kind: "header",
                        name: p.name && p.name.length > 0 ? String(p.name) : String(p.id),
                        type: String(p.type), pid: String(p.id),
                        collapsed: collapsed });
            if (collapsed && !f) continue;   // search ignores collapse
            for (var k = 0; k < checked.length; k++)
                rows.push({ kind: "model", providerId: String(p.id),
                            model: String(checked[k]),
                            type: String(p.type) });
        }
        
        if (!f) return rows;
        var out = [];
        for (var r = 0; r < rows.length; r++) {
            var row = rows[r];
            if (row.kind === "header") { out.push(row); continue; }
            var lbl = service.modelLabel(row.providerId, row.model);
            if (FuzzyMatch.matches(f, row.model)
                || FuzzyMatch.matches(f, String(lbl))) out.push(row);
        }
        // drop headers left without any following model row
        var pruned = [];
        for (r = 0; r < out.length; r++) {
            if (out[r].kind === "model") { pruned.push(out[r]); continue; }
            if (r + 1 < out.length && out[r + 1].kind === "model") pruned.push(out[r]);
        }
        return pruned;
    }

    // Model zone (left): label + chevron. Hover highlights the zone
    // (not the tune section) and shows the pointing cursor.
    Item {
        id: modelArea
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: 12
        width: modelRow.implicitWidth + 8

        Rectangle {
            anchors.fill: parent
            radius: 8
            // Fade via opacity: interpolating color toward "transparent"
            // drifts the RGB toward black and reads as a dark flash.
            color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
            opacity: modelHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        RowLayout {
            id: modelRow
            anchors.centerIn: parent
            spacing: 6

            BrandIcon {
                size: 16
                stem: selector.activeStem
            }

            Text {
                text: selector.modelLabel
                color: Theme.surfaceVariantText
                font.pixelSize: 12
                elide: Text.ElideRight
                Layout.maximumWidth: 180
            }

            DankIcon {
                name: modelPicker.visible ? "expand_more" : "expand_less"
                size: 16
                color: Theme.surfaceVariantText
            }
        }

        HoverHandler { id: modelHover; cursorShape: Qt.PointingHandCursor }

        TapHandler {
            onTapped: modelPicker.visible ? modelPicker.close() : modelPicker.open()
        }
    }

    // Zone divider
    Rectangle {
        id: zoneDivider
        anchors.left: modelArea.right
        anchors.leftMargin: 6
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: 8
        width: 1
        color: Theme.withAlpha(Theme.outlineVariant, 0.6)
    }

    // Tune zone (right): generation params
    Item {
        id: tuneArea
        anchors.left: zoneDivider.right
        anchors.leftMargin: 6
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 36

        DankIcon {
            anchors.centerIn: parent
            name: "instant_mix"
            size: 18
            color: genPopup.visible || tuneHover.hovered
                   ? Theme.primary : Theme.surfaceVariantText
            Behavior on color { ColorAnimation { duration: 250 } }
        }

        HoverHandler { id: tuneHover; cursorShape: Qt.PointingHandCursor }

        TapHandler {
            onTapped: genPopup.visible ? genPopup.close() : genPopup.open()
        }
    }

    // Width budget: left margin 12 + model area (row + 8) + divider
    // (6 margin + 1 + 6 margin) + tune zone 36 + right padding 8.
    implicitWidth: modelRow.implicitWidth + 77

    // ── Unified model picker ─────────────────────────────────────
    Popup {
        id: modelPicker
        y: -height - 8
        width: Math.min(selector.width + 220, 380)
        height: Math.min(640, contentItem.implicitHeight + 24)
        padding: 8

        background: Rectangle {
            radius: 12
            color: Theme.surfaceContainerHigh
            border.color: Theme.outlineVariant
        }

        contentItem: ColumnLayout {
            id: pickerCol
            spacing: 8

            // Make a manual entry the active model; if the id is not
            // already in the active instance's checked list, persist it
            // there too so it reappears next time.
            function pickModel(id) {
                if (!selector.service || id.length === 0) return;
                var svc = selector.service;
                var models = svc.activeModels();
                var known = false;
                for (var i = 0; i < models.length; i++)
                    if (models[i] === id) { known = true; break; }
                if (!known)
                    svc.toggleModel(svc.activeProviderId, id);
                svc.setActiveModel(id);
                modelPicker.close();
            }

            // Cross-instance selection: switching provider resets the
            // active model (setActiveProvider), so set it afterwards.
            function selectModel(providerId, modelId) {
                if (!selector.service || !modelId || modelId.length === 0) return;
                selector.service.setActiveProvider(String(providerId));
                selector.service.setActiveModel(String(modelId));
                modelPicker.close();
            }

            ListView {
                id: modelList
                Layout.fillWidth: true
                // Floor of 56 keeps the empty-state hint visible when
                // no provider has checked models.
                Layout.preferredHeight: Math.min(480, Math.max(contentHeight, 56))
                clip: true
                spacing: 2
                model: selector.service
                    ? selector.buildRows(manualEntry.text) : []

                delegate: Item {
                    id: rowDelegate
                    required property var modelData
                    readonly property bool isModelRow:
                        modelData && modelData.kind === "model"
                    readonly property string rowProviderId:
                        isModelRow ? String(modelData.providerId) : ""
                    readonly property string rowModelId:
                        isModelRow ? String(modelData.model) : ""
                    readonly property string rowIconStem: {
                        // Unused read — same dependency trick as
                        // activeStem above (subscribes to the icon scan).
                        var _scan = selector.service ? selector.service.modelIconStems : null;
                        return isModelRow
                            ? ModelIcons.iconForModel(rowModelId,
                                modelData && modelData.type ? String(modelData.type) : "")
                            : "";
                    }
                    readonly property string headerIconStem:
                        !isModelRow && modelData && modelData.type
                        ? ModelIcons.providerIcon(String(modelData.type)) : ""
                    readonly property string rowPid:
                        !isModelRow && modelData && modelData.pid
                        ? String(modelData.pid) : ""
                    readonly property bool rowCollapsed:
                        rowPid.length > 0
                        && selector.collapsedProviders[rowPid] === true
                    readonly property bool rowPinned:
                        selector.service && isModelRow
                        && selector.service.isPinned(rowProviderId, rowModelId)
                    readonly property bool rowActive:
                        selector.service && isModelRow
                        && rowProviderId === selector.service.activeProviderId
                        && rowModelId === selector.service.activeModel

                    width: modelList.width
                    height: isModelRow ? 44 : 26

                    // Group header (or the "Pinned" section label):
                    // provider logo + name; tappable to collapse the
                    // group (except the Pinned label).
                    Row {
                        visible: !rowDelegate.isModelRow
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        BrandIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            size: 14
                            stem: rowDelegate.headerIconStem
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowDelegate.isModelRow ? ""
                                  : (rowDelegate.modelData ? String(rowDelegate.modelData.name) : "")
                            color: Theme.withAlpha(Theme.surfaceVariantText, 0.6)
                            font.pixelSize: 11
                        }

                        TapHandler {
                            onTapped: if (rowDelegate.rowPid.length > 0)
                                selector.toggleCollapsed(rowDelegate.rowPid)
                        }
                        HoverHandler {
                            id: headerHover
                            enabled: rowDelegate.rowPid.length > 0
                            cursorShape: Qt.PointingHandCursor
                        }
                    }

                    // Collapse chevron (anchored right; the Row is a
                    // positioner and can't host it).
                    DankIcon {
                        visible: !rowDelegate.isModelRow
                                 && rowDelegate.rowPid.length > 0
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        name: rowDelegate.rowCollapsed ? "expand_more" : "expand_less"
                        size: 16
                        color: headerHover.hovered ? Theme.primary : Theme.surfaceVariantText
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    ItemDelegate {
                        id: modelDelegate
                        visible: rowDelegate.isModelRow
                        width: parent.width
                        height: parent.height
                        hoverEnabled: true
                        background: Rectangle {
                            radius: 6
                            color: modelDelegate.hovered
                                ? Theme.withAlpha(Theme.primary, 0.14) : "transparent"
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }

                        // Select area: everything left of the pin zone,
                        // so a tap on the pin never also selects.
                        Item {
                            id: selectArea
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.right: pinZone.left
                            anchors.leftMargin: 26
                            anchors.rightMargin: 2

                            TapHandler {
                                onTapped: pickerCol.selectModel(
                                              rowDelegate.rowProviderId,
                                              rowDelegate.rowModelId)
                            }

                            RowLayout {
                                anchors.fill: parent
                                spacing: 8

                                BrandIcon {
                                    Layout.alignment: Qt.AlignVCenter
                                    size: 16
                                    stem: rowDelegate.rowIconStem
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: selector.service
                                        ? selector.service.modelLabel(
                                              rowDelegate.rowProviderId,
                                              rowDelegate.rowModelId)
                                        : rowDelegate.rowModelId
                                    color: modelDelegate.hovered ? Theme.primary : Theme.surfaceText
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                }
                                DankIcon {
                                    visible: rowDelegate.rowActive
                                    name: "check"
                                    size: 16
                                    color: Theme.primary
                                }
                            }
                        }

                        // Pin zone: own TapHandler, no overlap with the
                        // select area — toggling must not select. Hover
                        // tints the pin to the accent color.
                        Item {
                            id: pinZone
                            width: 32
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom

                            HoverHandler {
                                id: pinHover
                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                onTapped: if (selector.service && rowDelegate.isModelRow)
                                    selector.service.togglePinned(
                                        rowDelegate.rowProviderId,
                                        rowDelegate.rowModelId)
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                name: "push_pin"
                                size: 16
                                filled: rowDelegate.rowPinned
                                color: rowDelegate.rowPinned || pinHover.hovered
                                       ? Theme.primary : Theme.surfaceVariantText
                                Behavior on color { ColorAnimation { duration: 250 } }
                            }
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: modelList.count === 0
                    text: manualEntry.text.length > 0
                          ? "No models match"
                          : "No models — enable some in settings"
                    color: Theme.surfaceVariantText
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    width: parent.width - 16
                    horizontalAlignment: Text.AlignHCenter
                }

            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                DankTextField {
                    id: manualEntry
                    Layout.fillWidth: true
                    placeholderText: "Search model"
                    leftIconName: "search"
                    showClearButton: true
                }
                DankButton {
                    iconName: "check"
                    text: ""
                    buttonHeight: 36
                    onClicked: pickerCol.pickModel(manualEntry.text.trim())
                }
            }
        }
    }

    // ── Generation params (Common Settings) ──────────────────────

    // Checkbox card: checkbox center-left; title top-right with the
    // number box beside it; slider below. Content grays when unchecked.
    // Values are handled in raw slider units; `multiplier` converts to
    // the real-world value (temperature uses 0.01).
    component SettingCard : Rectangle {
        id: card

        property string label: ""
        property bool checked: false
        property int rawValue: 0
        property int rawMin: 0
        property int rawMax: 100
        property int rawStep: 1
        property real multiplier: 1.0
        property int decimals: 0
        signal toggled(bool checked)
        signal valueEdited(int rawValue)

        // True while the card syncs the slider from rawValue — suppresses
        // the slider's onValueChanged side effects (focus steal + echo).
        property bool _syncing: false

        // True when the point (card-relative) sits over one of the
        // card's interactive children — taps there must NOT toggle
        // the checkbox.
        function overChild(child, p) {
            if (!child || !child.visible) return false;
            var tl = card.mapFromItem(child, 0, 0);
            return p.x >= tl.x && p.x <= tl.x + child.width
                && p.y >= tl.y && p.y <= tl.y + child.height;
        }

        function displayValue() {
            return (rawValue * multiplier).toFixed(decimals);
        }

        width: parent ? parent.width : 260
        implicitHeight: cardContent.implicitHeight + 8
        radius: 6
        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.22)

        // Passive hover highlight: a soft wash that fades in under
        // the pointer. HoverHandler only — input stays with the
        // slider/checkbox/number box.
        HoverHandler { id: cardHover }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.primary, 0.07)
            opacity: cardHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }
        }

        // Check toggle feedback: the box pops once, like the MCP
        // tool rows.
        SequentialAnimation {
            id: checkBounce
            NumberAnimation {
                target: checkIcon; property: "scale"
                to: 1.15; duration: 140; easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                target: checkIcon; property: "scale"
                to: 1.0; duration: 240; easing.type: Easing.InOutQuad
            }
        }

        // Whole-card toggle: a tap anywhere that is not on the number
        // box or the slider flips the checkbox (the checkbox graphic
        // itself included — it has no separate handler).
        TapHandler {
            onTapped: (eventPoint) => {
                if (card.overChild(valueBox, eventPoint.position)) return;
                if (card.overChild(slider, eventPoint.position)) return;
                checkBounce.restart();
                card.toggled(!card.checked);
            }
        }

        DankIcon {
            id: checkIcon
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            name: card.checked ? "check_box" : "check_box_outline_blank"
            size: 20
            color: card.checked ? Theme.primary : Theme.surfaceVariantText
        }

        ColumnLayout {
            id: cardContent
            anchors.left: checkIcon.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 2
            opacity: card.checked ? 1.0 : 0.35
            Behavior on opacity { NumberAnimation { duration: 200 } }

            RowLayout {
                width: parent.width
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: card.label
                    color: Theme.surfaceText
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                // DankTextField hardcodes left alignment; this minimal
                // field gives us right-aligned numeric input.
                Rectangle {
                    id: valueBox
                    Layout.preferredWidth: 76
                    Layout.preferredHeight: 24
                    radius: 4
                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
                    border.width: 1
                    border.color: valueInput.activeFocus ? Theme.primary : Theme.outlineVariant
                    enabled: card.checked

                    TextInput {
                        id: valueInput
                        anchors.fill: parent
                        anchors.margins: 4
                        verticalAlignment: TextInput.AlignVCenter
                        horizontalAlignment: TextInput.AlignRight
                        text: card.displayValue()
                        color: Theme.surfaceText
                        font.pixelSize: 12
                        clip: true
                        selectByMouse: true
                        // NOTE: never write card.rawValue here — it would
                        // break rawValue's binding to the service and the
                        // slider would snap back. Push through valueEdited;
                        // the rawValue binding updates the card.
                        onTextChanged: if (activeFocus && !isNaN(parseFloat(text))) {
                            card.valueEdited(Math.round(parseFloat(text) / card.multiplier));
                        }
                    }
                }
            }

            BallSlider {
                id: slider
                Layout.fillWidth: true
                Layout.preferredHeight: 20
                enabled: card.checked
                minimum: card.rawMin
                maximum: card.rawMax
                step: card.rawStep
                // No `value:` binding — the slider writes value
                // imperatively on drag, which would break it. Sync both
                // directions via onValueChanged + onRawValueChanged.
                Component.onCompleted: value = card.rawValue
                onValueChanged: {
                    if (card._syncing) return;
                    // Clicking the number box gives it activeFocus; a
                    // plain slider drag never clears it (the slider is
                    // not a focus scope), which would freeze the text.
                    // Steal focus back and always sync while dragging.
                    valueInput.focus = false;
                    card.valueEdited(value);
                    valueInput.text = card.displayValue();
                }
            }
        }

        Connections {
            target: card
            function onRawValueChanged() {
                card._syncing = true;
                slider.value = card.rawValue;
                card._syncing = false;
                if (!valueInput.activeFocus)
                    valueInput.text = card.displayValue();
            }
        }
    }

    // Local slider with a round thumb (DMS's DankSlider uses a bar
    // handle, and shell widgets are read-only for plugins). Mirrors
    // DankSlider's contract: int `value` written imperatively during
    // drag, same position→value math and wheel stepping.
    component BallSlider : Item {
        id: bs

        property int value: 50
        property int minimum: 0
        property int maximum: 100
        property int step: 1

        implicitHeight: 20

        function updateValueFromPosition(x) {
            var travel = Math.max(1, track.width - ball.width);
            var ratio = Math.max(0, Math.min(1, (x - ball.width / 2) / travel));
            var raw = minimum + ratio * (maximum - minimum);
            var v = step > 1 ? Math.round(raw / step) * step : Math.round(raw);
            v = Math.max(minimum, Math.min(maximum, v));
            if (v !== value) value = v;
        }

        // Track line.
        Rectangle {
            id: track
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: 4
            radius: 2
            color: bs.enabled
                ? Theme.withAlpha(Theme.outlineVariant, 0.9)
                : Theme.withAlpha(Theme.outlineVariant, 0.4)
        }

        // Fill from the left edge to the ball's center.
        Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            height: 4
            radius: 2
            width: Math.max(0, Math.min(track.width,
                ball.x + ball.width / 2))
            color: bs.enabled ? Theme.primary
                              : Theme.withAlpha(Theme.primary, 0.3)
        }

        // Ball thumb: grows slightly on hover/press.
        Rectangle {
            id: ball
            width: 16
            height: 16
            radius: 8
            anchors.verticalCenter: track.verticalCenter
            x: {
                var range = bs.maximum - bs.minimum;
                var ratio = range === 0
                    ? 0 : (bs.value - bs.minimum) / range;
                var travel = track.width - width;
                return Math.max(0, Math.min(travel, travel * ratio));
            }
            color: bs.enabled ? Theme.primary
                              : Theme.withAlpha(Theme.primary, 0.3)
            scale: area.pressed || area.containsMouse ? 1.15 : 1.0
            Behavior on scale {
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
            }
        }

        MouseArea {
            id: area
            anchors.fill: parent
            // Generous vertical hit area, like DankSlider's.
            anchors.topMargin: -8
            anchors.bottomMargin: -8
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            preventStealing: true
            enabled: bs.enabled

            onPressed: (mouse) => bs.updateValueFromPosition(mouse.x)
            onPositionChanged: (mouse) => {
                if (pressed) bs.updateValueFromPosition(mouse.x);
            }
            onWheel: (wheel) => {
                var wheelStep = bs.step > 1
                    ? bs.step : Math.max(1, (bs.maximum - bs.minimum) / 100);
                var v = wheel.angleDelta.y > 0
                    ? Math.min(bs.maximum, bs.value + wheelStep)
                    : Math.max(bs.minimum, bs.value - wheelStep);
                if (bs.step > 1) v = Math.round(v / bs.step) * bs.step;
                v = Math.round(v);
                if (v !== bs.value) bs.value = v;
                wheel.accepted = true;
            }
        }
    }

    Popup {
        id: genPopup
        // Chip sits at the panel's bottom-left: align the popup's left
        // edge to the chip so it opens rightward, inside the panel.
        x: 0
        y: -height - 8
        width: 320
        height: Math.min(420, contentItem.implicitHeight + 24)
        padding: 12
        // Gold-standard popup motion: rises out of the tune chip —
        // fade + subtle scale anchored at the bottom edge — with a
        // quicker, quieter exit.
        transformOrigin: Popup.Bottom

        enter: Transition {
            NumberAnimation {
                property: "opacity"
                from: 0; to: 1
                duration: 180
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                property: "scale"
                from: 0.94; to: 1
                duration: 180
                easing.type: Easing.OutCubic
            }
        }
        exit: Transition {
            NumberAnimation {
                property: "opacity"
                to: 0
                duration: 140
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                property: "scale"
                to: 0.96
                duration: 140
                easing.type: Easing.InCubic
            }
        }

        background: Rectangle {
            radius: 8
            color: Theme.withAlpha(Theme.surfaceContainer, 0.97)
            border.color: Theme.surfaceVariantAlpha
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 6

            Text {
                text: "Common Settings"
                color: Theme.surfaceVariantText
                font.pixelSize: 12
                font.bold: true
            }

            SettingCard {
                label: "Context Window Size"
                visible: service ? service.activeIsOllama : false
                rawMin: 1024
                rawMax: 32768
                rawStep: 1024
                rawValue: service ? service.numCtx : 8192
                checked: service ? service.useContextWindow : false
                onToggled: (checked) => {
                    if (!service) return;
                    service.useContextWindow = checked;
                    service.saveSetting("useContextWindow", checked);
                }
                onValueEdited: (raw) => {
                    if (!service) return;
                    service.numCtx = raw;
                    service.saveSetting("numCtx", raw);
                }
            }

            SettingCard {
                label: "Temperature"
                decimals: 2
                multiplier: 0.01
                rawMin: 0
                rawMax: 200
                rawStep: 5
                rawValue: service ? Math.round(service.temperature * 100) : 70
                checked: service ? service.useTemperature : false
                onToggled: (checked) => {
                    if (!service) return;
                    service.useTemperature = checked;
                    service.saveSetting("useTemperature", checked);
                }
                onValueEdited: (raw) => {
                    if (!service) return;
                    service.temperature = raw * multiplier;
                    service.saveSetting("temperature", raw * multiplier);
                }
            }

            SettingCard {
                label: "Max Output Token"
                rawMin: 0
                rawMax: 16384
                rawStep: 256
                rawValue: service ? service.maxTokens : 4096
                checked: service ? service.useMaxTokens : false
                onToggled: (checked) => {
                    if (!service) return;
                    service.useMaxTokens = checked;
                    service.saveSetting("useMaxTokens", checked);
                }
                onValueEdited: (raw) => {
                    if (!service) return;
                    service.maxTokens = raw;
                    service.saveSetting("maxTokens", raw);
                }
            }
        }
    }
}
