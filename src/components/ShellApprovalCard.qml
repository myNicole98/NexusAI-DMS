import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Permission card for the native shell tool. It renders whatever the
// service has parked in `pendingApproval` and answers it through
// service.answerShellApproval(action, folder).
//
// It lives in the chat's layout flow directly above the composer: no
// overlay, no floating box — same quiet card treatment as the rest of
// the app. The command line is the one thing allowed to be monospace.
Item {
    id: root

    property var service: null

    readonly property var approval: service ? service.pendingApproval : null
    readonly property bool active: approval !== null && approval !== undefined
    readonly property string kind: active ? String(approval.kind || "") : ""
    readonly property bool isPath: kind === "path" || kind === "cwd"
    readonly property string command: active ? String(approval.command || "") : ""
    readonly property string folder: active ? String(approval.folder || "") : ""
    readonly property string question: {
        if (!active) return "";
        if (kind === "cwd") return "Work in " + folder + "?";
        if (kind === "path")
            return "Read " + (approval.paths && approval.paths.length > 0
                              ? approval.paths[0] : folder) + "?";
        return "Run this command?";
    }

    implicitHeight: active ? card.implicitHeight : 0
    visible: opacity > 0.01
    opacity: active ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 220 } }

    // Text-only action, like the app's other inline affordances.
    component Action : Text {
        id: action
        property bool danger: false
        signal tapped()

        font.pixelSize: 12
        font.weight: Font.Medium
        color: action.danger ? Theme.error : Theme.primary
        opacity: actionHover.hovered ? 0.72 : 1
        Behavior on opacity { NumberAnimation { duration: 150 } }

        HoverHandler {
            id: actionHover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler { onTapped: action.tapped() }
    }

    Rectangle {
        id: card
        width: parent.width
        implicitHeight: content.implicitHeight + 20
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.55)

        ColumnLayout {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 10
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                DankIcon {
                    name: root.isPath ? "folder_open" : "terminal"
                    size: 14
                    color: Theme.primary
                }

                Text {
                    Layout.fillWidth: true
                    text: root.question
                    color: Theme.surfaceText
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: commandText.implicitHeight + 10
                radius: 6
                color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.5)

                Text {
                    id: commandText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    text: "$ " + root.command
                    color: Theme.surfaceText
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 11
                    elide: Text.ElideMiddle
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 14

                Item { Layout.fillWidth: true }

                Action {
                    text: root.isPath ? "Allow once" : "Approve"
                    onTapped: if (root.service)
                        root.service.answerShellApproval("allow-once")
                }

                Action {
                    visible: root.isPath
                    text: "Allow " + root.folder
                    onTapped: if (root.service)
                        root.service.answerShellApproval("allow-folder", root.folder)
                }

                Action {
                    text: "Deny"
                    danger: true
                    onTapped: if (root.service)
                        root.service.answerShellApproval("deny")
                }
            }
        }
    }
}
