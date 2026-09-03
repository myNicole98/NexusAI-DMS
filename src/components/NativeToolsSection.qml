import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Native chat tools settings (web_search / webfetch): one toggle row
// per tool. Per-tool switches only — the master switch lives on the
// chat bar; rows dim and hint there when it is off.
Item {
    id: root

    property var service: null

    readonly property bool masterOn: service ? service.webToolsEnabled : false

    implicitHeight: body.implicitHeight

    // Toggle row: checkbox + display name + description. Unlike
    // the MCP tool rows there is no list rebuild behind these binds —
    // the flags are plain service booleans — so the crossfade and
    // bounce can drive straight off `checked`.
    component NativeToolRow : Rectangle {
        id: toolRow

        property string label: ""
        property string description: ""
        property bool checked: false
        property bool rowEnabled: true
        signal toggled()

        height: 56
        radius: 8
        color: toolRow.checked
            ? Theme.withAlpha(Theme.primary, 0.14)
            : Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)
        opacity: toolRow.rowEnabled ? 1 : 0.45
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Behavior on color { ColorAnimation { duration: 220 } }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
            opacity: toolHover.hovered && toolRow.rowEnabled ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        HoverHandler {
            id: toolHover
            enabled: toolRow.rowEnabled
            cursorShape: Qt.PointingHandCursor
        }

        SequentialAnimation {
            id: checkBounce
            NumberAnimation {
                target: checkBox; property: "scale"
                to: 1.15; duration: 140; easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                target: checkBox; property: "scale"
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

            DankIcon {
                anchors.fill: parent
                name: "check_box_outline_blank"
                size: 20
                visible: opacity > 0.01
                opacity: toolRow.checked ? 0 : 1
                color: Theme.surfaceVariantText
                Behavior on opacity {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.InOutQuad
                    }
                }
            }

            DankIcon {
                anchors.fill: parent
                name: "check_box"
                size: 20
                visible: opacity > 0.01
                opacity: toolRow.checked ? 1 : 0
                color: Theme.primary
                Behavior on opacity {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.InOutQuad
                    }
                }
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
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
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
            enabled: toolRow.rowEnabled
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
                text: "Native Tools"
                color: Theme.primary
                font.pixelSize: 13
                font.bold: true
            }

            Item { Layout.fillWidth: true }
        }

        Text {
            Layout.fillWidth: true
            visible: !root.masterOn
            text: "Native tools are switched off — use the language icon " +
                  "above the chat input to turn them on."
            color: Theme.surfaceVariantText
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        NativeToolRow {
            Layout.fillWidth: true
            label: "Web Search"
            description: "Let the model search the web with DuckDuckGo."
            checked: root.service ? root.service.webSearchEnabled : false
            rowEnabled: root.masterOn
            onToggled: if (root.service)
                root.service.setNativeToolEnabled("web_search",
                                                  !root.service.webSearchEnabled)
        }

        NativeToolRow {
            Layout.fillWidth: true
            label: "Web Fetch"
            description: "Let the model open a URL and read its content."
            checked: root.service ? root.service.webFetchEnabled : false
            rowEnabled: root.masterOn
            onToggled: if (root.service)
                root.service.setNativeToolEnabled("webfetch",
                                                  !root.service.webFetchEnabled)
        }
    }
}
