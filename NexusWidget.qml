import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modules.Plugins

// Bar pill that opens the Nexus AI panel (same toggle as the IPC command).
PluginComponent {
    id: root

    horizontalBarPill: Component {
        DIcon {
            name: "orbit"
            size: root.iconSize
            color: Theme.widgetIconColor
        }
    }

    verticalBarPill: Component {
        DIcon {
            name: "orbit"
            size: root.iconSize
            color: Theme.widgetIconColor
        }
    }

    pillClickAction: () => {
        if (root.pluginService)
            root.pluginService.togglePlugin(root.pluginId);
    }
}
