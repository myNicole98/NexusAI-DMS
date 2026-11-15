import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modals.FileBrowser

// Shell tool settings: the master switch, the YOLO opt-in and the list
// of folders reads are allowed in. The policy itself is
// ShellTools.analyze's; this file only edits what the user has granted.
Item {
    id: root

    property var service: null

    implicitHeight: body.implicitHeight

    readonly property var dirs: service ? (service.shellAllowedDirs || []) : []
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

    // ── Row: grant entry with remove ──────────────────────────────
    component GrantRow : Rectangle {
        id: grantRow

        property string label: ""
        property string value: ""
        signal removed()

        height: 40
        radius: 8
        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
            opacity: grantHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: removeBtn.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: grantRow.value
            color: Theme.surfaceText
            font.pixelSize: 12
            font.family: Theme.monoFontFamily
            elide: Text.ElideMiddle
        }

        Item {
            id: removeBtn
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28

            DankIcon {
                anchors.centerIn: parent
                name: "close"
                size: 16
                color: removeHover.hovered ? Theme.error : Theme.surfaceVariantText
                Behavior on color { ColorAnimation { duration: 150 } }
            }

            HoverHandler {
                id: removeHover
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onTapped: grantRow.removed()
            }
        }

        HoverHandler {
            id: grantHover
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
            description: "Run every command without asking, folders ignored. "
                         + "Only for a model and a machine you trust."
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

        // ── Allowed folders ───────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6
            Text {
                text: "Allowed folders"
                color: Theme.surfaceText
                font.pixelSize: 13
            }
            Item { Layout.fillWidth: true }
            Text {
                text: "add"
                color: folderHover.hovered ? Theme.surfaceText : Theme.primary
                font.pixelSize: 12
                HoverHandler {
                    id: folderHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: {
                        folderLoader.active = true;
                        if (folderLoader.item) folderLoader.item.open();
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.dirs.length === 0
            text: "No folders yet — the first read outside home will ask and "
                  + "offer to add one."
            color: Theme.surfaceVariantText
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Repeater {
            model: root.dirs
            delegate: GrantRow {
                required property string modelData
                Layout.fillWidth: true
                value: modelData
                onRemoved: if (root.service)
                    root.service.removeShellAllowedDir(modelData)
            }
        }

    }

    // DMS folder picker (folderMode). Same LazyLoader pattern as the
    // composer's image picker — never Qt's GTK FileDialog.
    LazyLoader {
        id: folderLoader
        active: false

        FileBrowserSurfaceModal {
            browserTitle: "Allow reading in this folder"
            browserIcon: "folder_open"
            browserType: "nexus_shell"
            folderMode: true
            allowStacking: true

            onFileSelected: (path) => {
                close();
                var p = String(path).replace(/^file:\/\//, "");
                try { p = decodeURIComponent(p); }
                catch (e) { /* keep raw */ }
                if (root.service) root.service.addShellAllowedDir(p);
            }
            onDialogClosed: folderLoader.active = false
        }
    }
}
