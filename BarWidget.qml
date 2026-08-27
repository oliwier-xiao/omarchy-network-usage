import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "lib/Model.js" as Model

// The bar slot: what today has cost so far, and a way in. Panel.qml does the
// reading; Service.qml does the counting. This file owns the glyph, the label
// and the settings that the service half cannot see for itself.
//
// The glyph is a bar chart rather than the speedometer every other network
// widget wears, because this is not a speedometer: it answers what was spent,
// not how fast it is going.
BarWidget {
  id: root
  moduleName: "oliwier.network-usage"

  readonly property string glyph: "󰄨"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("oliwier.network-usage") : null
  readonly property bool serviceReady: service && service.ready === true

  readonly property string labelMode: String(setting("barLabel", "Download"))
  readonly property double down: serviceReady ? service.todayDown : 0
  readonly property double up: serviceReady ? service.todayUp : 0
  readonly property bool available: serviceReady && service.available === true

  readonly property string label: {
    if (!root.serviceReady || root.labelMode === "Nothing") return ""
    if (root.labelMode === "Both directions")
      return "↓ " + Model.formatBytes(root.down) + "  ↑ " + Model.formatBytes(root.up)
    return Model.formatBytes(root.down)
  }

  // Settings live on this half of the plugin; the service is loaded by the
  // shell without them. Push rather than poll, so a changed setting takes
  // effect on the next sample instead of the next restart.
  function pushSettings() {
    var s = root.service
    if (!s) return
    s.sampleSeconds = Number(setting("sampleSeconds", 2)) || 2
    s.keepDays = Number(setting("keepDays", 90)) || 90
    s.nameContainers = setting("nameContainers", true) === true
    s.countLanNoise = setting("countLanNoise", false) === true
    s.interfaceName = String(setting("interface", ""))
  }

  onServiceChanged: pushSettings()
  onSettingsChanged: { pushSettings(); injectPanel() }
  onBarChanged: injectPanel()
  Component.onCompleted: pushSettings()

  // ---- Panel shape contract for shell.summon/hide/toggle routing ----------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "oliwier.network-usage"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function status(): void {
      console.log("oliwier.network-usage: watching=" + (root.service ? root.service.watching : "-")
        + " available=" + root.available
        + " down=" + Model.formatBytes(root.down)
        + " up=" + Model.formatBytes(root.up))
    }
  }

  // The vertical bar hides the button's text, so the reading is stacked as
  // glyph lines instead — same shape the built-in widgets use on an edge bar.
  readonly property var verticalLines: {
    if (!root.vertical) return []
    var lines = [root.glyph]
    if (!root.iconOnly && root.label) {
      var parts = Model.formatBytes(root.down).split(" ")
      for (var i = 0; i < parts.length; i++) if (parts[i]) lines.push(parts[i])
    }
    return lines
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical
      ? ""
      : root.iconOnly || !root.label ? root.glyph : root.glyph + " " + root.label
    labelVisible: !root.vertical && !root.iconOnly && root.label !== ""
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.5
    tooltipText: {
      if (!root.serviceReady) return "Network usage · starting"
      if (!root.available) return "Network usage · " + (root.service.unavailableReason || "not counting")
      return "Today · ↓ " + Model.formatBytes(root.down)
        + "   ↑ " + Model.formatBytes(root.up)
        + (root.service.watching ? "  on " + root.service.watching : "")
    }
    onPressed: function (b) {
      if (b === Qt.RightButton) root.toggleIconOnly()
      else root.togglePanel()
    }

    OpticalGlyph {
      visible: !root.vertical && (root.iconOnly || !root.label)
      anchors.fill: parent
      text: root.glyph
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.foreground
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData === root.glyph ? Style.font.icon
            : (modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize)
          color: button.foreground
        }
      }
    }
  }
}
