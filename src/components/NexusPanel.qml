import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets

pragma ComponentBehavior: Bound

// Slideout panel: transparent full-height window; the visible surface
// slides in from its screen edge and the mask confines input to it.
PanelWindow {
    id: root

    property bool isVisible: false
    property var modelData: null
    property real panelWidth: 480
    property bool expandable: true
    property bool expanded: false
    property real expandedWidth: 960
    property Component content: null
    property real gap: 6
    property bool panelOnLeft: false
    property var service: null

    function show() {
        visible = true;
        isVisible = true;
    }

    function hide() {
        if (contentLoader.item && contentLoader.item.forceActiveFocus)
            contentLoader.item.forceActiveFocus();
        isVisible = false;
    }

    function toggle() {
        if (isVisible) hide();
        else show();
    }

    // Emitted after the slide-in animation finishes.
    signal opened()

    onOpened: {
        if (contentLoader.item && typeof contentLoader.item.focusInput === "function")
            contentLoader.item.focusInput();
    }

    visible: isVisible
    screen: modelData
    color: "transparent"

    anchors.top: true
    anchors.bottom: true
    anchors.right: !panelOnLeft
    anchors.left: panelOnLeft

    readonly property real activeWidth: expandable && expanded ? expandedWidth : panelWidth
    implicitWidth: expandable ? expandedWidth + gap : panelWidth + gap
    implicitHeight: modelData ? modelData.height : 800

    WlrLayershell.namespace: "nexus:panel"
    WlrLayershell.layer: WlrLayershell.Top
    WlrLayershell.exclusiveZone: 0
    WlrLayershell.keyboardFocus: isVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    readonly property real dpr: CompositorService.getScreenScale(root.screen)
    readonly property real alignedWidth: Theme.px(activeWidth + gap, dpr)

    mask: Region {
        item: Rectangle {
            x: root.panelOnLeft ? 0 : root.width - root.alignedWidth
            y: 0
            width: root.alignedWidth
            height: root.height
        }
    }

    Item {
        id: slide
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        // Conditional side anchors don't reset to undefined on
        // re-evaluation — the slide kept both and stretched. Use x.
        x: root.panelOnLeft ? 0 : parent.width - width
        width: root.alignedWidth

        property real offset: root.panelOnLeft ? -alignedWidth : alignedWidth

        Connections {
            target: root
            function onIsVisibleChanged() {
                slide.offset = root.isVisible ? 0 : (root.panelOnLeft ? -slide.width : slide.width);
            }

            // offset's binding is dead after the imperative write
            // above — re-derive on edge flips too, or the slide
            // renders detached from the mask.
            function onPanelOnLeftChanged() {
                slide.offset = root.isVisible ? 0
                    : (root.panelOnLeft ? -slide.width : slide.width);
            }
        }

        Behavior on offset {
            NumberAnimation {
                duration: 400
                easing.type: Easing.OutCubic
                onRunningChanged: {
                    if (!running && !root.isVisible) root.visible = false;
                    if (!running && root.isVisible) root.opened();
                }
            }
        }

        Behavior on width {
            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
        }

        Item {
            id: layeredContent
            layer.enabled: Quickshell.env("DMS_DISABLE_LAYER") !== "true"
                           && Quickshell.env("DMS_DISABLE_LAYER") !== "1"
            layer.smooth: false
            layer.textureSize: Qt.size(width * root.dpr, height * root.dpr)

            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width
            x: Theme.snap(slide.offset, root.dpr)

            Item {
                anchors.fill: parent
                anchors.topMargin: root.gap
                anchors.bottomMargin: root.gap
                anchors.rightMargin: root.panelOnLeft ? 0 : root.gap
                anchors.leftMargin: root.panelOnLeft ? root.gap : 0

                // ── Rounded translucent panel: bar + content ───────
                Rectangle {
                    id: panelSurface
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: Qt.rgba(
                        Theme.surfaceContainer.r,
                        Theme.surfaceContainer.g,
                        Theme.surfaceContainer.b,
                        SettingsData.popupTransparency
                    )
                    border.width: 1
                    border.color: Theme.surfaceVariantAlpha

                    // Panel bar (title + expand + close), DankSlideout-style
                    Item {
                        id: panelBar
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: Theme.spacingL
                        height: 36

                        Row {
                            id: barLead
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            DankActionButton {
                                id: historyButton
                                // Hidden while the settings page overlays
                                // the chat — the drawer would otherwise
                                // toggle invisibly behind it.
                                visible: root.service
                                         && root.service.historyEnabled
                                         && contentLoader.item
                                         && contentLoader.item.state === "chat"
                                iconName: contentLoader.item
                                          && contentLoader.item.historyOpen
                                          ? "menu_open" : "menu"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: {
                                    if (!contentLoader.item) return;
                                    contentLoader.item.historyOpen =
                                        !contentLoader.item.historyOpen;
                                }
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Nexus AI"
                                color: Theme.surfaceText
                                font.pixelSize: 16
                                font.weight: Font.Medium
                            }
                        }

                        Row {
                            id: barButtons
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXS

                            DankActionButton {
                                iconName: "delete_sweep"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: if (root.service) root.service.newChat()
                            }

                            DankActionButton {
                                iconName: contentLoader.item
                                          && contentLoader.item.state === "settings"
                                          ? "arrow_back" : "tune"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: {
                                    if (!contentLoader.item) return;
                                    contentLoader.item.state =
                                        contentLoader.item.state === "settings" ? "chat" : "settings";
                                }
                            }

                            // Move the panel to the other screen edge;
                            // the arrow points where it will go.
                            DankActionButton {
                                iconName: root.service && root.service.panelEdge === "left"
                                          ? "arrow_right" : "arrow_left"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: {
                                    if (!root.service) return;
                                    root.service.panelEdge =
                                        root.service.panelEdge === "left" ? "right" : "left";
                                    root.service.saveSetting("panelEdge", root.service.panelEdge);
                                }
                            }

                            DankActionButton {
                                id: expandButton
                                iconName: root.expanded ? "unfold_less" : "unfold_more"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                transform: Rotation {
                                    angle: 90
                                    origin.x: expandButton.width / 2
                                    origin.y: expandButton.height / 2
                                }
                                onClicked: root.expanded = !root.expanded
                            }

                            DankActionButton {
                                iconName: "close"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: root.hide()
                            }
                        }
                    }

                    Item {
                        anchors.top: panelBar.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Theme.spacingL
                        anchors.rightMargin: Theme.spacingL
                        anchors.bottomMargin: Theme.spacingL

                    Loader {
                        id: contentLoader
                        anchors.fill: parent
                        sourceComponent: root.content
                    }
                }
            }
        }
    }
}
}
