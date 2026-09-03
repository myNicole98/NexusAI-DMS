import QtQuick
import QtQuick.Controls
import qs.Common

// Comic speech-bubble tooltip: rounded body with a tail that merges
// into the body outline (one continuous path, no seam line across the
// junction). Expects to be hosted as a Popup parented to the chip it
// describes, centered above it. Shows after hovering the anchor for
// `delay` ms and closes as soon as the pointer leaves — drive it via
// `hovering` from the anchor's HoverHandler.onHoveredChanged.
Popup {
    id: tip

    property string tipText: ""
    // Set from outside: true while the pointer is over the anchor.
    property bool hovering: false
    // Hover dwell time before the bubble pops.
    property int delay: 500

    readonly property real bodyHeight: bodyText.implicitHeight + 14
    readonly property real tailLength: 9

    onHoveringChanged: {
        if (hovering) {
            armTimer.restart();
        } else {
            armTimer.stop();
            if (opened) close();
        }
    }

    Timer {
        id: armTimer
        interval: tip.delay
        onTriggered: tip.open()
    }

    width: Math.min(bodyText.implicitWidth + 20, 240)
    height: bodyHeight + tailLength
    padding: 0
    background: null
    closePolicy: Popup.NoAutoClose

    // Centered above the anchor, parent-relative — the same proven
    // coordinate pattern as the composer's popups (no popup-layer
    // mapping, which evaluates unreliably while closed).
    x: (parent.width - width) / 2
    y: -height - 1

    enter: Transition {
        NumberAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.OutCubic
        }
    }
    exit: Transition {
        NumberAnimation {
            property: "opacity"
            to: 0
            duration: 120
            easing.type: Easing.InCubic
        }
    }

    // QColor → CSS rgba(): Canvas's fillStyle parses #rrggbb but not
    // Qt's #aarrggbb toString form, so build the string manually.
    function css(c) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255)
            + "," + Math.round(c.b * 255) + "," + c.a + ")";
    }

    contentItem: Item {
        implicitWidth: tip.width
        implicitHeight: tip.height

        Canvas {
            id: bubble
            anchors.fill: parent
            antialiasing: true

            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                var w = width;
                var bh = tip.bodyHeight;
                var th = tip.tailLength;
                var cx = w / 2;
                var tw = 7;   // tail half-width
                var r = 10;   // body corner radius
                // One continuous outline: rounded rect whose bottom
                // edge flows out into the tail and back — the tail
                // reads as part of the bubble, not a glued-on arrow.
                ctx.beginPath();
                ctx.moveTo(r, 0.5);
                ctx.lineTo(w - r, 0.5);
                ctx.arcTo(w, 0.5, w, r + 0.5, r);
                ctx.lineTo(w, bh - r);
                ctx.arcTo(w, bh + 0.5, w - r, bh + 0.5, r);
                ctx.lineTo(cx + tw, bh + 0.5);
                ctx.lineTo(cx, bh + th);
                ctx.lineTo(cx - tw, bh + 0.5);
                ctx.lineTo(r, bh + 0.5);
                ctx.arcTo(0, bh + 0.5, 0, bh - r, r);
                ctx.lineTo(0, r + 0.5);
                ctx.arcTo(0, 0.5, r, 0.5, r);
                ctx.closePath();
                ctx.fillStyle = tip.css(Theme.surfaceContainerHigh);
                ctx.fill();
                ctx.lineWidth = 1;
                ctx.strokeStyle = tip.css(Theme.outlineVariant);
                ctx.stroke();
            }
            // Canvas never auto-repaints on resize/show.
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()
            Component.onCompleted: requestPaint()
        }

        Text {
            id: bodyText
            x: (parent.width - width) / 2
            y: 7
            width: Math.min(implicitWidth, tip.width - 20)
            text: tip.tipText
            color: Theme.surfaceText
            font.pixelSize: 12
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
