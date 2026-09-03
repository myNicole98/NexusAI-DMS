import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets

ListView {
    id: list

    property var service: null
    model: service ? service.messagesModel : null

    clip: true
    spacing: 10
    boundsBehavior: Flickable.StopAtBounds

      // Keep-alive window spans the full conversation: delegates are
      // never destroyed at a cache boundary (finite buffers wobbled
      // contentHeight and made bottom-follow flicker).
    cacheBuffer: Math.max(500, contentHeight)

      // ── Bottom-follow ─────────────────────────────────────────────
      // While streaming (and the user hasn't taken over), a frame
      // conveyor eases contentY toward the end. Drag/wheel/scroll-away
      // unpins; returning to the end, the pill, or a new message
      // re-pins. After the stream the view is user-owned.
    property bool pinned: true
    property real _peakY: 0
    property real _lastY: 0
    property real _lastTarget: 0
    // frames left in a "force to end" re-assert window (pill press)
    property int _assertTicks: 0

    function unpin() {
        pinned = false;
    }

    // New rows (message sent, chat cleared) always re-pin: submitting
    // a message means you want to see the response.
    onCountChanged: {
        pinned = true;
        _peakY = contentY;
        _lastY = contentY;
        _lastTarget = Math.max(0, contentHeight - height);
    }

    onDraggingChanged: if (dragging) unpin()
    onFlickingChanged: if (flicking) unpin()

    // Render-frame conveyor: perfectly uniform steps (synced to the
    // render loop — a Timer races/mismatches flush and frame timing,
    // which read as choppy nudging).
    FrameAnimation {
        running: (list.pinned && list.service && list.service.isStreaming)
                 || list._assertTicks > 0
        onTriggered: list.step()
    }

    function step() {
        var target = Math.max(0, contentHeight - height);
        // Pill "force to end" window: pin contentY to the end for a
        // few frames so any polish pass re-asserting a stale anchor
        // is overridden.
        if (_assertTicks > 0) {
            contentY = target;
            _peakY = target;
            _lastY = target;
            _lastTarget = target;
            _assertTicks--;
            return;
        }
        var dY = contentY - _lastY;
        var dTarget = target - _lastTarget;
          // The conveyor only increases contentY; a drop >8px with a
          // still end means the user scrolled — hand over control.
          // Re-pin via return-to-end or the pill.
        if (dY < -8 && dTarget > -2) {
            unpin();
            return;
        }
        // Content shrank (thinking box collapse — the end itself moved
        // up): re-anchor the high-water mark and keep following.
        if (contentY < _peakY - 24 && target < _peakY - 24)
            _peakY = target;
        if (contentY > _peakY) _peakY = contentY;
        var gap = target - contentY;
        if (gap < 0.5) return;
        contentY += Math.min(gap, gap * 0.15);
        _lastY = contentY;
        _lastTarget = target;
        if (contentY > _peakY) _peakY = contentY;
    }

    onContentYChanged: if (atYEnd) pinned = true

    // Streaming status strip: reserves space at the end of the
    // content while a stream is live.
    footer: Component {
        Item {
            width: list.width
            height: list.service && list.service.isStreaming ? 34 : 0
        }
    }

      // Streaming status chip on a solid surface — readable over text;
      // sticks to the viewport bottom once its footer strip slips out.
      // (Same pattern as the code block language bar.)
    Rectangle {
        id: statusRow
        visible: list.service && list.service.isStreaming
                 && list.service.messageCount > 0
        anchors.left: parent.left
        anchors.leftMargin: 6
        radius: 10
        implicitWidth: statusInner.implicitWidth + 20
        implicitHeight: statusInner.implicitHeight + 10
        color: Theme.withAlpha(Theme.surfaceContainer, 0.9)
        y: Math.min(
            list.contentHeight - list.contentY + 6,
            list.height - height - 6)

        Row {
            id: statusInner
            anchors.centerIn: parent
            spacing: 8

            HexSphereLogo {
                radius: 11
                strokeWidth: 1.5
                subdivisions: 1
                yawRate: 20
                pitchRate: 8
                interactive: false
                anchors.verticalCenter: parent.verticalCenter
                visible: statusRow.visible
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: list.service ? list.service.ponderingText : ""
                visible: text.length > 0
                color: Theme.surfaceVariantText
                font.pixelSize: 11
            }
        }
    }

    // Stream ended: the view is user-owned; the pill takes over.
    Connections {
        target: list.service
        function onIsStreamingChanged() {
            if (list.service && !list.service.isStreaming)
                list.pinned = false;
        }
    }

    // Full-width wrapper: ListView resets delegate x during layout, so
    // right-alignment must come from anchoring the bubble inside.
    delegate: Item {
        width: ListView.view ? ListView.view.width : 300
        implicitHeight: bubbleItem.height

        MessageBubble {
            id: bubbleItem
            anchors.right: parent.right
            service: list.service
            listView: list
            msgId: model.id
            role: model.role
            content: model.content
            thinking: model.thinking
            toolLog: model.toolLog
            attachments: model.attachments
            modelUsed: model.modelUsed
            modelProviderId: model.modelProviderId
            msgState: model.state
            stats: model.stats
            msgTimestamp: model.timestamp
        }
    }

    ScrollBar.vertical: DankScrollbar {
        onPressedChanged: if (pressed) list.unpin()
    }

    // Scroll-to-end pill: shows while the user holds scroll control
    // away from the end (streaming or not); re-pins the follow (or
    // returns to the bottom after the stream).
    Rectangle {
        id: toEndButton
        visible: !list.pinned && !list.atYEnd
                 && (list.contentHeight - list.height - list.contentY) > 80
                 && list.contentHeight > list.height + 40
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        width: 34
        height: 34
        radius: 17
        color: toEndHover.hovered
            ? Theme.withAlpha(Theme.primary, 0.25)
            : Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.outlineVariant

        DankIcon {
            anchors.centerIn: parent
            name: "arrow_downward"
            size: 18
            color: toEndHover.hovered ? Theme.primary : Theme.surfaceText
        }

        HoverHandler {
            id: toEndHover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: {
                // re-pin and force to end through a short re-assert
                // window (a plain write can be reverted by the view's
                // stale anchor after churn)
                list.pinned = true;
                list._assertTicks = 15;
            }
        }
    }
}
