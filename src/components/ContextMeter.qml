import QtQuick
import QtQuick.Shapes
import qs.Common
import "../lib/ContextWindows.js" as ContextWindows

// Context usage meter (composer bar, far right): [pct][ring]; hover
// slides them left and fades in the token counts over an opaque
// backdrop. Width animates; anchored right OUTSIDE the RowLayout so
// the chat box is never re-flowed.

Item {
    id: meter

    property var service: null

    readonly property var usage: service ? service.lastUsage : null
    readonly property int usedTokens: usage
        ? (usage.input || 0) + (usage.output || 0) : 0
    readonly property int window_: service ? service.contextWindow : 0
    readonly property real pct: window_ > 0
        ? Math.max(0, Math.min(usedTokens / window_, 0.999)) : 0
    readonly property bool showPct: window_ > 0
    readonly property bool expanded: meterHover.hovered

    readonly property int ringSize: 20
    readonly property int gap: 5
    readonly property int tokensWidth: expanded && tokensLabel.implicitWidth > 0
        ? tokensLabel.implicitWidth + gap : 0

    visible: usage !== null

    // Anchored raw Items don't size from implicitWidth — unpinned,
    // the meter collapses to width 0 and the layer crops the ring.
    implicitWidth: (showPct ? pctLabel.implicitWidth + gap : 0)
                   + ringSize + tokensWidth
    width: implicitWidth
    implicitHeight: ringSize
    height: implicitHeight
    Behavior on implicitWidth {
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }

    // Opaque backdrop: keeps the meter legible over the bar's chips.
    Rectangle {
        id: hoverBackdrop
        x: -4
        y: -4
        width: meter.width + 8
        height: meter.height + 8
        radius: 8
        color: Theme.withAlpha(Theme.surfaceContainer, 0.97)
        border.color: Theme.surfaceVariantAlpha
        border.width: 1
        opacity: meter.expanded ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    Text {
        id: pctLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: meter.showPct
        text: Math.round(meter.pct * 100) + "%"
        color: Theme.surfaceText
        font.pixelSize: 11
    }

    Item {
        id: ring
        x: pctLabel.visible ? pctLabel.implicitWidth + meter.gap : 0
        anchors.verticalCenter: parent.verticalCenter
        width: meter.ringSize
        height: meter.ringSize

        // Consumed fraction of the window; clamped to 99.9% (a 360°
        // PathArc degenerates).
        property real progress: meter.pct
        Behavior on progress {
            NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
        }
        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property real rr: width / 2 - 2
        readonly property real sweep: Math.PI * 2
            * Math.max(progress, 0.02)

        Shape {
            anchors.fill: parent
            antialiasing: true

            // Track: mid-gray full circle (two 180° arcs) — legible
            // on both themes.
            ShapePath {
                strokeColor: Theme.withAlpha(
                    Theme.surfaceVariantText, 0.55)
                strokeWidth: 3
                fillColor: "transparent"
                capStyle: ShapePath.Round
                startX: ring.cx
                startY: ring.cy - ring.rr
                PathArc {
                    x: ring.cx; y: ring.cy + ring.rr
                    radiusX: ring.rr; radiusY: ring.rr
                }
                PathArc {
                    x: ring.cx; y: ring.cy - ring.rr
                    radiusX: ring.rr; radiusY: ring.rr
                }
            }

            // Progress arc from 12 o'clock, clockwise.
            ShapePath {
                strokeColor: Theme.primary
                strokeWidth: 3
                fillColor: "transparent"
                capStyle: ShapePath.Round
                startX: ring.cx
                startY: ring.cy - ring.rr
                PathArc {
                    x: ring.cx + ring.rr * Math.cos(
                        -Math.PI / 2 + ring.sweep)
                    y: ring.cy + ring.rr * Math.sin(
                        -Math.PI / 2 + ring.sweep)
                    radiusX: ring.rr; radiusY: ring.rr
                    useLargeArc: ring.sweep > Math.PI
                }
            }
        }
    }

    // Exact counts, to the ring's right — revealed on hover as the
    // meter's width grows leftward.
    Text {
        id: tokensLabel
        anchors.left: ring.right
        anchors.leftMargin: meter.gap
        anchors.verticalCenter: parent.verticalCenter
        opacity: meter.expanded ? 1 : 0
        visible: opacity > 0.01
        text: meter.window_ > 0
            ? ContextWindows.formatTokens(meter.usedTokens) + " / "
              + ContextWindows.formatTokens(meter.window_)
            : ContextWindows.formatTokens(meter.usedTokens) + " tok"
        color: Theme.surfaceText
        font.pixelSize: 11
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    // Padded so hovering the backdrop's overhang doesn't flicker.
    Item {
        x: -4
        y: -7
        width: meter.width + 8
        height: meter.height + 14
        HoverHandler { id: meterHover }
    }
}
