import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets
import "../lib/ModelIcons.js" as ModelIcons

// Theme-aware brand icon. The startup scan indexes which stems exist in
// icons/<theme>/, icons/models/ and the other theme, so this renders
// exactly ONE image — probing a path that does not exist makes Qt log
// "Cannot open" on every render (that flood used to dominate the shell
// log). A brand with no asset gets a neutral glyph instead.
Item {
    id: root

    property string stem: ""
    property int size: 20
    width: size
    height: size
    implicitWidth: size
    implicitHeight: size

    readonly property bool dark:
        (Theme.surface.r * 0.299 + Theme.surface.g * 0.587
         + Theme.surface.b * 0.114) < 0.5

    // "" until the index has the stem — then exactly one existing file.
    // The icon index is module state (not observable), and rows built
    // before the startup scan landed would otherwise stay glyph-only
    // forever. While an icon is unresolved this re-evaluates a few
    // times; the counter is read in the binding on purpose, it is the
    // dependency that makes the retry visible.
    property int _retry: 0
    readonly property string rel: {
        // _retry is read on purpose: it is the dependency that makes the
        // binding re-evaluate when the Timer ticks.
        var tick = root._retry;
        return stem.length > 0 && tick >= 0
            ? ModelIcons.pathFor(stem, dark) : "";
    }

    // Poll only while the index itself is missing. Once it is populated,
    // an unresolved stem genuinely has no asset and the glyph is final.
    Timer {
        interval: 250
        repeat: true
        running: root.rel.length === 0 && root._retry < 40
                 && !ModelIcons.indexReady()
        onTriggered: root._retry++
    }

    Image {
        id: brandImg
        anchors.fill: parent
        source: root.rel.length > 0
            ? Qt.resolvedUrl("../../resources/icons/" + root.rel).toString()
            : ""
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        mipmap: true
        visible: status === Image.Ready
    }

    // Fallback mark for a brand with no bundled asset: a neutral glyph
    // beats an empty box.
    DIcon {
        anchors.centerIn: parent
        visible: brandImg.status !== Image.Ready
        name: "smart_toy"
        size: Math.round(root.size * 0.8)
        color: Theme.surfaceVariantText
    }
}
