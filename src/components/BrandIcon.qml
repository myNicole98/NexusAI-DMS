import QtQuick
import qs.Common

// Theme-aware brand icon: stem resolved against icons/<theme>/<stem>.svg
// then icons/models/<stem>.svg; nothing renders when absent. Theme is
// detected by surface luminance.
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

    readonly property string _primary: stem.length > 0
        ? Qt.resolvedUrl("../../resources/icons/"
            + (dark ? "dark" : "light") + "/" + stem + ".svg").toString()
        : ""
    readonly property string _alt: stem.length > 0
        ? Qt.resolvedUrl("../../resources/icons/"
            + (dark ? "light" : "dark") + "/" + stem + ".svg").toString()
        : ""
    readonly property string _model: stem.length > 0
        ? Qt.resolvedUrl("../../resources/icons/models/" + stem + ".svg").toString()
        : ""

    Image {
        id: primaryImg
        anchors.fill: parent
        source: root._primary
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        mipmap: true
        visible: status === Image.Ready
    }

    Image {
        id: altImg
        anchors.fill: parent
        source: root._alt
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        mipmap: true
        visible: primaryImg.status !== Image.Ready && status === Image.Ready
    }

    Image {
        id: modelImg
        anchors.fill: parent
        source: root._model
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        mipmap: true
        visible: primaryImg.status !== Image.Ready
                 && altImg.status !== Image.Ready && status === Image.Ready
    }

}
