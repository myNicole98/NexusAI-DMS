import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Shell tool settings: the YOLO opt-in only. The tool switch itself is
// the terminal chip on the chat bar; every command is decided per call
// on the approval card.
Item {
    id: root

    property var service: null

    implicitHeight: body.implicitHeight

    readonly property bool yolo: service ? service.shellYoloEnabled : false

    // ── Row: toggle ───────────────────────────────────────────────
    component ToggleRow : Rectangle {
        id: toggleRow

        property string label: ""
        property string description: ""
        property bool checked: false
        property bool danger: false
        property bool armed: false
        signal toggled()

        height: 56
        radius: 8
        color: toggleRow.checked
            ? Theme.withAlpha(toggleRow.danger ? Theme.error : Theme.primary, 0.14)
            : Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)
        Behavior on color { ColorAnimation { duration: 220 } }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
            opacity: toggleHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        HoverHandler {
            id: toggleHover
            cursorShape: Qt.PointingHandCursor
        }

        DankIcon {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            name: toggleRow.checked ? "check_box" : "check_box_outline_blank"
            size: 20
            color: toggleRow.checked
                   ? (toggleRow.danger ? Theme.error : Theme.primary)
                   : Theme.surfaceVariantText
            Behavior on color { ColorAnimation { duration: 200 } }
        }

        ColumnLayout {
            anchors.left: parent.left
            anchors.leftMargin: 44
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: toggleRow.label
                color: toggleRow.danger && toggleRow.checked
                       ? Theme.error : Theme.surfaceText
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: toggleRow.armed
                      ? "Tap again to confirm"
                      : toggleRow.description
                color: toggleRow.armed ? Theme.error : Theme.surfaceVariantText
                font.pixelSize: 11
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        TapHandler {
            onTapped: toggleRow.toggled()
        }
    }

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "Shell Tool"
                color: Theme.primary
                font.pixelSize: 13
                font.bold: true
            }
            Item { Layout.fillWidth: true }
        }

        ToggleRow {
            id: yoloRow
            Layout.fillWidth: true
            label: "YOLO mode"
            description: "Run every command without asking. Only for a model " +
                         "and a machine you trust."
            checked: root.yolo
            danger: true
            armed: armTimer.running
            onToggled: {
                if (!root.service) return;
                if (!root.service.shellYoloEnabled) {
                    // Turning it ON takes a second tap.
                    if (!armTimer.running) { armTimer.restart(); return; }
                    armTimer.stop();
                    root.service.setShellYoloEnabled(true);
                } else {
                    root.service.setShellYoloEnabled(false);
                }
            }
        }

        Timer {
            id: armTimer
            interval: 4000
            repeat: false
        }
    }
}
