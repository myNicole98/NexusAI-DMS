import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import "../lib/PromptPresets.js" as PromptPresets

Item {
    id: settings

    property var service: null

    // Construction-time and service-load-time binding evaluation must not
    // write back to settings. Component.onCompleted fires bottom-up (before
    // NexusService._loadSettings runs), so the flag flips via Qt.callLater —
    // after the whole creation batch and its synchronous binding updates.
    property bool _loading: true
    // Custom write-in mode: the box is editable and the Custom chip
    // stays highlighted even while the prompt is still empty.
    property bool customMode: false

    Component.onCompleted: Qt.callLater(() => { settings._loading = false })

    function persist(key, value) {
        // property assignment happens at call site; persist immediately
        if (_loading) return;
        service.saveSetting(key, value);
    }

    // Opaque-to-panel backdrop: same color as the panel container, so
    // the chat below does not bleed through the settings page.
    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g,
                       Theme.surfaceContainer.b, SettingsData.popupTransparency)
    }

    Flickable {
        id: settingsScroll

        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight + 32
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column
            width: settings.width - 32
            x: 16
            spacing: 16

            // ── Header row ────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 16
                Text {
                    text: "Settings"
                    color: Theme.surfaceText
                    font.pixelSize: 18
                    font.bold: true
                }
            }

            // ── Providers (multi-provider instances) ──────────────────
            ProvidersSection {
                Layout.fillWidth: true
                service: settings.service
            }

            // ── Native tools card (parked) ────────────────────────────
            // NativeToolsSection {
            //     Layout.fillWidth: true
            //     service: settings.service
            // }

            // ── MCP card ──────────────────────────────────────────────
            MCPSection {
                Layout.fillWidth: true
                service: settings.service
            }

            // ── Prompt card ───────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: "System Prompt"
                    color: Theme.primary
                    font.pixelSize: 13
                    font.bold: true
                }

                // Personality presets; "Custom" selects the write-in
                // box (highlight follows the box content).
                Row {
                    Layout.fillWidth: true
                    spacing: 6

                    Repeater {
                        model: PromptPresets.PRESETS

                        delegate: Rectangle {
                            id: presetChip
                            required property var modelData
                            readonly property bool active:
                                settings.customMode
                                ? modelData.id === "custom"
                                : PromptPresets.detect(service ? service.systemPrompt : "")
                                  === modelData.id

                            width: presetLabel.implicitWidth + 20
                            height: 26
                            radius: 13
                            color: presetChip.active
                                ? Theme.withAlpha(Theme.primary, 0.22)
                                : Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)
                            Behavior on color { ColorAnimation { duration: 150 } }

                            Text {
                                id: presetLabel
                                anchors.centerIn: parent
                                text: presetChip.modelData.name
                                color: presetChip.active ? Theme.primary : Theme.surfaceVariantText
                                font.pixelSize: 11
                                font.bold: presetChip.active
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!service) return;
                                    if (presetChip.modelData.id !== "custom") {
                                        settings.customMode = false;
                                        service.systemPrompt = presetChip.modelData.text;
                                    } else {
                                        // Entering custom mode: blank the
                                        // preset text so the user can write
                                        // their own, then focus the box.
                                        settings.customMode = true;
                                        if (PromptPresets.detect(service.systemPrompt)
                                            !== "custom")
                                            service.systemPrompt = "";
                                        promptArea.forceActiveFocus();
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    // Box hugs the pure text height: 13px visual padding
                    // above and below, exactly.
                    Layout.preferredHeight: Math.min(220, promptArea.contentHeight + 26)
                    radius: 8
                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)
                    border.width: promptArea.activeFocus ? 1 : 0
                    border.color: Theme.primary
                    clip: true

                    TextArea {
                        id: promptArea
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 13
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 0
                        rightPadding: 0
                        // Preset text is fixed; only Custom is editable.
                        readOnly: !settings.customMode
                                 && PromptPresets.detect(service ? service.systemPrompt : "")
                                    !== "custom"
                        text: service ? service.systemPrompt : ""
                        color: Theme.surfaceText
                        font.pixelSize: 13
                        wrapMode: TextArea.Wrap
                        placeholderText: "You are a concise assistant…"
                        placeholderTextColor: Theme.surfaceVariantText
                        background: null
                        selectionColor: Theme.withAlpha(Theme.primary, 0.4)
                        selectedTextColor: Theme.surfaceText
                        onTextChanged: if (service && !settings._loading) {
                            service.systemPrompt = text;
                            settings.persist("systemPrompt", text);
                        }
                    }
                }
            }

            // ── Panel card ────────────────────────────────────────────
            // (Panel side toggle moved to the panel top bar.)

            Item { Layout.fillHeight: true }
        }

        ScrollBar.vertical: DankScrollbar {}
    }
}
