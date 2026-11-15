import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets
import "../lib/FileTools.js" as FileTools

// Permission card for everything under the shell umbrella: commands and
// the file tools. It renders whatever the service has parked in
// `pendingApproval` and answers it through service.answerShellApproval(action).
//
// Lives in the chat's layout flow directly above the composer: no
// overlay, same quiet card treatment as the rest of the app. The only
// monospace content is what the user must read character by character:
// the command, or a diff.
Item {
    id: root

    property var service: null

    readonly property var approval: service ? service.pendingApproval : null
    readonly property bool active: approval !== null && approval !== undefined
    readonly property string kind: active ? String(approval.kind || "") : ""
    readonly property string path: active ? String(approval.path || "") : ""
    readonly property string command: active ? String(approval.command || "") : ""

    readonly property string question: {
        if (!active) return "";
        if (kind === "read") return "Read " + path + "?";
        if (kind === "write") return "Write " + path + "?";
        if (kind === "edit") return "Apply this change to " + path + "?";
        return "Run this command?";
    }
    // Lines beyond the four the command preview shows (the card must stay
    // small: a heredoc can be a whole file).
    readonly property int hiddenLines: {
        if (!active || kind !== "command") return 0;
        var lines = String(approval.command || "").split("\n").length;
        return lines > 4 ? lines - 4 : 0;
    }
    // Diff budget: enough to judge the change, never a whole file.
    readonly property var diffRows: {
        if (!active || kind !== "edit") return [];
        var rows = approval.diff || [];
        return rows.slice(0, 12);
    }
    readonly property int diffMore: {
        if (!active || kind !== "edit") return 0;
        var all = approval.diff ? approval.diff.length : 0;
        return Math.max(0, all - 12) + (approval.more || 0);
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

                DIcon {
                    name: root.kind === "read" || root.kind === "write"
                          || root.kind === "edit"
                          ? (root.kind === "read" ? "description" : "edit_document")
                          : "terminal"
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

                Text {
                    visible: root.kind === "read" || root.kind === "write"
                    text: FileTools.humanSize(root.active
                                              ? (root.approval.size || 0) : 0)
                    color: Theme.surfaceVariantText
                    font.pixelSize: 11
                }
            }

            // ── command preview ───────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.kind === "command"
                implicitHeight: commandText.implicitHeight
                                + (moreLines.visible ? moreLines.implicitHeight : 0)
                                + 10
                radius: 6
                color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.5)

                Text {
                    id: commandText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.topMargin: 5
                    text: "$ " + root.command
                    color: Theme.surfaceText
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 11
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 4
                    elide: Text.ElideRight
                }

                Text {
                    id: moreLines
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: commandText.bottom
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.topMargin: 2
                    visible: root.hiddenLines > 0
                    text: "… " + root.hiddenLines + " more line"
                          + (root.hiddenLines === 1 ? "" : "s")
                    color: Theme.surfaceVariantText
                    font.pixelSize: 10
                }
            }

            // ── write preview ─────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.kind === "write"
                implicitHeight: writePreview.implicitHeight + 10
                radius: 6
                color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.5)

                Text {
                    id: writePreview
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 5
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    text: {
                        if (!root.active) return "";
                        var lines = root.approval.preview || [];
                        if (lines.length === 0) return "(empty file)";
                        return lines.slice(0, 6).join("\n")
                             + (root.approval.existed ? "\n… (replaces the existing file)" : "");
                    }
                    color: Theme.surfaceText
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 11
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 7
                    elide: Text.ElideRight
                }
            }

            // ── diff ──────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                visible: root.kind === "edit"
                implicitHeight: diffColumn.implicitHeight + 10
                radius: 6
                color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.5)

                ColumnLayout {
                    id: diffColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.topMargin: 5
                    spacing: 1

                    Repeater {
                        model: root.diffRows

                        delegate: Text {
                            required property var modelData
                            Layout.fillWidth: true
                            text: (modelData.t === " " ? "  " : modelData.t + " ")
                                  + modelData.text
                            color: modelData.t === "+" ? Theme.primary
                                 : modelData.t === "-" ? Theme.error
                                 : Theme.surfaceVariantText
                            font.family: Theme.monoFontFamily
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.diffMore > 0
                        text: "… " + root.diffMore + " more diff lines"
                        color: Theme.surfaceVariantText
                        font.pixelSize: 10
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 14

                Item { Layout.fillWidth: true }

                Action {
                    text: "Approve"
                    onTapped: if (root.service)
                        root.service.answerShellApproval("allow-once")
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
