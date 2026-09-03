import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import "./src/services"
import "./src/components"

Item {
    id: root

    property var pluginService: null
    property string pluginId: "nexusAI"

    function toggle() {
        if (variants.instances.length > 0)
            variants.instances[0].toggle();
    }

    IpcHandler {
        target: "nexus"

        function toggle(): string {
            root.toggle();
            return "NEXUS_TOGGLE_SUCCESS";
        }
    }

    NexusService {
        id: nexusService
        pluginId: root.pluginId
    }

    Variants {
        id: variants
        model: Quickshell.screens

        delegate: NexusPanel {
            id: nexusPanel
            panelOnLeft: nexusService.panelEdge === "left"
            service: nexusService
            content: NexusChat {
                service: nexusService
                panel: nexusPanel
            }
        }
    }
}
