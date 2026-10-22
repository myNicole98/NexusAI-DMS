import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets

pragma ComponentBehavior: Bound

// Slideout panel: docked (edge slide-in) or floating (inset layered
// popup). Docked=one side anchored; floating=all sides anchored with
// margins insetting the surface to the floating rect.
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

    readonly property bool floating: service ? service.panelMode === "floating" : false
    readonly property real floatVMargin: root.gap + 24

    // Floating rect (screen coords); -1 = modular centered default.
    property real floatX: -1
    property real floatY: -1
    property real floatW: -1
    property real floatH: -1

    // Animate button-driven rect changes; drags stay 1:1.
    property bool _animRect: true

    Behavior on floatX {
        enabled: root._animRect
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }
    Behavior on floatY {
        enabled: root._animRect
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }
    Behavior on floatW {
        enabled: root._animRect
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }
    Behavior on floatH {
        enabled: root._animRect
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }

    // Resolve the modular defaults into the rect once, on entry.
    function materializeFloatRect() {
        if (floatX < 0) floatX = effFloatX;
        if (floatY < 0) floatY = effFloatY;
        if (floatW < 0) floatW = effFloatW;
        if (floatH < 0) floatH = effFloatH;
    }

    // Reduced (30% smaller) and fullscreen sub-modes.
    property bool floatSmall: false
    property bool floatFull: false
    property var _preSmallRect: null
    property var _preFullRect: null

    function toggleFloatSmall() {
        if (floatSmall) {
            if (_preSmallRect) {
                floatX = _preSmallRect.x; floatY = _preSmallRect.y;
                floatW = _preSmallRect.w; floatH = _preSmallRect.h;
            }
            floatSmall = false;
        } else {
            _preSmallRect = { x: effFloatX, y: effFloatY,
                              w: effFloatW, h: effFloatH };
            var w = Math.round(effFloatW * 0.7);
            var h = Math.round(effFloatH * 0.7);
            floatX = Math.round(effFloatX + (effFloatW - w) / 2);
            floatY = Math.round(effFloatY + (effFloatH - h) / 2);
            floatW = w; floatH = h;
            floatSmall = true;
        }
    }

    function toggleFloatFull() {
        if (floatFull) {
            if (_preFullRect) {
                floatX = _preFullRect.x; floatY = _preFullRect.y;
                floatW = _preFullRect.w; floatH = _preFullRect.h;
            }
            floatFull = false;
        } else {
            _preFullRect = { x: effFloatX, y: effFloatY,
                             w: effFloatW, h: effFloatH };
            floatX = 0; floatY = 0;
            floatW = scrW; floatH = scrH;
            floatFull = true;
        }
    }

    function show() {
        visible = true;
        if (root.floating) {
            // Start the fade after the surface maps, or its early
            // frames are lost and the fade-in reads too fast.
            Qt.callLater(function () {
                if (root.visible) root.isVisible = true;
            });
        } else {
            isVisible = true;
        }
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

    // Fired when the show animation finishes.
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
    anchors.left: root.floating ? true : root.panelOnLeft
    anchors.right: root.floating ? true : !root.panelOnLeft

    readonly property real activeWidth: expandable && expanded ? expandedWidth : panelWidth
    implicitWidth: expandable ? expandedWidth + gap : panelWidth + gap
    implicitHeight: modelData ? modelData.height : 800

    WlrLayershell.namespace: "nexus:panel"
    WlrLayershell.layer: WlrLayershell.Top
    WlrLayershell.exclusiveZone: 0
    WlrLayershell.keyboardFocus: isVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // Same blur request DMS surfaces use (compositor ext-background-effect).
    WindowBlur {
        id: blurHelper
        targetWindow: root
        blurEnabled: root.isVisible

        Binding {
            target: blurHelper
            property: "surfaceColor"
            value: panelSurface.color
        }
        blurX: slide.x + layeredContent.x + floatHost.x
        blurY: floatHost.y
        blurWidth: floatHost.width
        blurHeight: floatHost.height
        blurRadius: Theme.cornerRadius
    }

    readonly property real dpr: CompositorService.getScreenScale(root.screen)
    readonly property real alignedWidth: Theme.px(activeWidth + gap, dpr)
    // Real surface size (root.width is unsynced on layer windows).
    readonly property real _surfW: contentItem ? contentItem.width
        : (modelData ? modelData.width : 1920)
    readonly property real _surfH: contentItem ? contentItem.height
        : (modelData ? modelData.height : 1440)
    readonly property real scrW: modelData ? modelData.width : 1920
    readonly property real scrH: modelData ? modelData.height : 1080

    // Modular default: ~16:9, screen-scaled, capped for ultrawides.
    readonly property real defFloatW: Math.min(scrW * 0.78, 2080,
                                              scrW - 2 * (gap + 12))
    readonly property real defFloatH: Math.min(Math.round(defFloatW * 9 / 16),
                                               scrH - 2 * floatVMargin)
    readonly property real effFloatW: floatW >= 0 ? floatW : defFloatW
    readonly property real effFloatH: floatH >= 0 ? floatH : defFloatH
    readonly property real effFloatX: floatX >= 0
        ? floatX : Math.round((scrW - effFloatW) / 2)
    readonly property real effFloatY: floatY >= 0
        ? floatY : Math.round((scrH - effFloatH) / 2)

    WlrLayershell.margins {
        left: root.floating ? root.effFloatX : 0
        top: root.floating ? root.effFloatY : 0
        right: root.floating ? root.scrW - root.effFloatX - root.effFloatW : 0
        bottom: root.floating ? root.scrH - root.effFloatY - root.effFloatH : 0
    }

    // Docked: input confined to the side strip.
    mask: Region {
        item: Rectangle {
            x: root.floating ? 0
                : (root.panelOnLeft ? 0 : root._surfW - root.alignedWidth)
            y: 0
            width: root.floating ? root._surfW : root.alignedWidth
            height: root._surfH
        }
    }

    // Floating resize handle: edge/corner strip.
    component ResizeHandle : MouseArea {
        property string edge: "r"
        z: 10   // above the panel content
        property real _sx: 0
        property real _sy: 0
        property real _x0: 0
        property real _y0: 0
        property real _w0: 0
        property real _h0: 0
        cursorShape: edge === "l" || edge === "r" ? Qt.SizeHorCursor
            : edge === "t" || edge === "b" ? Qt.SizeVerCursor
            : (edge === "tl" || edge === "br") ? Qt.SizeFDiagCursor
            : Qt.SizeBDiagCursor
        onPressed: (mouse) => {
            root._animRect = false;
            var p = mapToItem(root.contentItem, mouse.x, mouse.y);
            _sx = p.x; _sy = p.y;
            _x0 = root.effFloatX; _y0 = root.effFloatY;
            _w0 = root.effFloatW; _h0 = root.effFloatH;
        }
        onReleased: root._animRect = true
        onPositionChanged: (mouse) => {
            if (!pressed) return;
            var p = mapToItem(root.contentItem, mouse.x, mouse.y);
            var dx = p.x - _sx, dy = p.y - _sy;
            var nx = _x0, ny = _y0, nw = _w0, nh = _h0;
            var MINW = 340, MINH = 260;
            if (edge.indexOf("l") >= 0) {
                nw = _w0 - dx; nx = _x0 + dx;
                if (nw < MINW) { nx += MINW - nw; nw = MINW; }
            } else if (edge.indexOf("r") >= 0) {
                nw = _w0 + dx;
                if (nw < MINW) nw = MINW;
            }
            if (edge === "t") {
                nh = _h0 - dy; ny = _y0 + dy;
                if (nh < MINH) { ny += MINH - nh; nh = MINH; }
            } else if (edge === "b") {
                nh = _h0 + dy;
                if (nh < MINH) nh = MINH;
            }
            var maxW = scrW - 2 * root.gap;
            var maxH = scrH - 2 * root.gap;
            if (nw > maxW) {
                if (edge.indexOf("l") >= 0) nx += nw - maxW;
                nw = maxW;
            }
            if (nh > maxH) {
                if (edge === "t") ny += nh - maxH;
                nh = maxH;
            }
            if (nx < root.gap) { nw -= root.gap - nx; nx = root.gap; }
            if (ny < root.gap) { nh -= root.gap - ny; ny = root.gap; }
            if (nx + nw > scrW - root.gap)
                nw = scrW - root.gap - nx;
            if (ny + nh > scrH - root.gap)
                nh = scrH - root.gap - ny;
            root.floatX = nx; root.floatY = ny;
            root.floatW = nw; root.floatH = nh;
        }
    }

    Item {
        id: slide
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        x: root.floating ? 0
            : (root.panelOnLeft ? 0 : parent.width - width)
        width: root.floating ? parent.width : root.alignedWidth
        // Floating fades in; docked slides.
        opacity: root.floating && !root.isVisible ? 0 : 1
        Behavior on opacity {
            NumberAnimation {
                duration: 220
                easing.type: Easing.OutCubic
                onRunningChanged: {
                    if (!running && root.floating) {
                        if (!root.isVisible) root.visible = false;
                        else root.opened();
                    }
                }
            }
        }

        property real offset: root.panelOnLeft ? -alignedWidth : alignedWidth

        // offset is written imperatively (killing its binding), so
        // re-derive it on every state change.
        Connections {
            target: root
            function onIsVisibleChanged() {
                slide.offset = root.isVisible ? 0 : (root.floating
                    ? 0
                    : (root.panelOnLeft ? -slide.width : slide.width));
            }

            function onPanelOnLeftChanged() {
                slide.offset = root.isVisible ? 0
                    : (root.floating ? 0
                       : (root.panelOnLeft ? -slide.width : slide.width));
            }

            function onFloatingChanged() {
                if (!root.floating) {
                    // Drop transient sub-mode rects on the way out.
                    if (root.floatFull) root.toggleFloatFull();
                    if (root.floatSmall) root.toggleFloatSmall();
                } else {
                    root.materializeFloatRect();
                }
                slide.offset = root.isVisible ? 0
                    : (root.floating ? 0
                       : (root.panelOnLeft ? -slide.width : slide.width));
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
            enabled: !root.floating   // resize drags track 1:1
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
                id: floatHost
                anchors.fill: parent
                anchors.topMargin: root.floating ? 0 : root.gap
                anchors.bottomMargin: root.floating ? 0 : root.gap
                anchors.leftMargin: root.floating ? 0
                    : (root.panelOnLeft ? root.gap : 0)
                anchors.rightMargin: root.floating ? 0
                    : (root.panelOnLeft ? 0 : root.gap)

                // 8 floating-only resize handles (edges + corners).
                ResizeHandle {
                    edge: "l"; enabled: root.floating
                    anchors.left: parent.left; anchors.top: parent.top
                    anchors.bottom: parent.bottom; width: 6
                }
                ResizeHandle {
                    edge: "r"; enabled: root.floating
                    anchors.right: parent.right; anchors.top: parent.top
                    anchors.bottom: parent.bottom; width: 6
                }
                ResizeHandle {
                    edge: "t"; enabled: root.floating
                    anchors.top: parent.top; anchors.left: parent.left
                    anchors.right: parent.right; height: 6
                }
                ResizeHandle {
                    edge: "b"; enabled: root.floating
                    anchors.bottom: parent.bottom; anchors.left: parent.left
                    anchors.right: parent.right; height: 6
                }
                ResizeHandle {
                    edge: "tl"; enabled: root.floating
                    anchors.top: parent.top; anchors.left: parent.left
                    width: 14; height: 14
                }
                ResizeHandle {
                    edge: "tr"; enabled: root.floating
                    anchors.top: parent.top; anchors.right: parent.right
                    width: 14; height: 14
                }
                ResizeHandle {
                    edge: "bl"; enabled: root.floating
                    anchors.bottom: parent.bottom; anchors.left: parent.left
                    width: 14; height: 14
                }
                ResizeHandle {
                    edge: "br"; enabled: root.floating
                    anchors.bottom: parent.bottom; anchors.right: parent.right
                    width: 14; height: 14
                }

                // Rounded translucent panel: bar + content.
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
                                // Hidden while settings overlays the chat.
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

                            // Edge flip (docked only).
                            DankActionButton {
                                visible: !root.floating
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

                            // Reduced size toggle (floating, not fullscreen).
                            DankActionButton {
                                visible: root.floating && !root.floatFull
                                iconName: root.floatSmall
                                          ? "expand_content" : "collapse_content"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: root.toggleFloatSmall()
                            }

                            // Fullscreen toggle (floating).
                            DankActionButton {
                                visible: root.floating
                                iconName: root.floatFull
                                          ? "fullscreen_exit" : "fullscreen"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: root.toggleFloatFull()
                            }

                            // Float/dock the panel.
                            DankActionButton {
                                iconName: root.floating ? "dock_to_left" : "open_in_new"
                                iconSize: Theme.iconSize - 4
                                iconColor: Theme.surfaceText
                                onClicked: {
                                    if (!root.service) return;
                                    root.service.panelMode =
                                        root.floating ? "docked" : "floating";
                                    root.service.saveSetting(
                                        "panelMode", root.service.panelMode);
                                }
                            }

                            // Wide/narrow (docked only).
                            DankActionButton {
                                id: expandButton
                                visible: !root.floating
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
                        onLoaded: if (item && item.panel !== undefined)
                            item.panel = root
                    }
                }
            }
        }
    }
}
}
