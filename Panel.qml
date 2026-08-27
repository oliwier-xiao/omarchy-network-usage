import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model
import "lib/Palette.js" as Palette

// The panel: what today cost, and which apps spent it.
//
// Two ranked bar charts rather than one chart of two colours. Download and
// upload are different questions asked of the same list, and a reader almost
// always has one of them in mind — putting them side by side would make the
// answer to either harder to find. Separating them also means the colour is
// decoration rather than the thing carrying the meaning, which is why the
// charts stay readable for a reader who cannot tell the two hues apart.
//
// Read-only. Service.qml owns every number here.
Panel {
  id: root
  moduleName: "oliwier.network-usage"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("oliwier.network-usage") : null
  readonly property bool serviceReady: service && service.ready === true
  readonly property bool available: serviceReady && service.available === true
  readonly property string unavailableReason: serviceReady ? String(service.unavailableReason || "") : ""
  readonly property var days: serviceReady ? service.days : ({})
  readonly property string todayKey: serviceReady ? service.todayKey : ""

  // Day selection: clicking a cell in the footer strip pins that day; empty
  // means the live one. Everything below flows from activeDay, so the charts,
  // the hero and the note all follow the selection together.
  property string selectedKey: ""
  readonly property string activeKey: root.selectedKey || root.todayKey
  readonly property var activeDay: root.serviceReady
    ? Model.dayFor(root.days, root.service.today, root.selectedKey, root.todayKey)
    : null
  readonly property string activeLabel: Model.formatDate(root.activeKey, root.todayKey)

  readonly property int topApps: Math.max(3, Math.min(15, Number(setting("topApps", 8)) || 8))
  readonly property bool showUnattributed: setting("showUnattributed", true) === true

  // The tail is rolled into one row so a long list cannot push the interesting
  // bars off the panel — but the roll-up is a door, not a wall. Clicking it, or
  // pressing e, drops the limit and lists every app; the panel scrolls to fit.
  property bool downExpanded: false
  property bool upExpanded: false

  readonly property var downRows: root.serviceReady
    ? Model.topRows(Model.appList(root.activeDay, "down"),
                    root.downExpanded ? Infinity : root.topApps,
                    "down", root.showUnattributed) : []
  readonly property var upRows: root.serviceReady
    ? Model.topRows(Model.appList(root.activeDay, "up"),
                    root.upExpanded ? Infinity : root.topApps,
                    "up", root.showUnattributed) : []

  readonly property double dayDown: root.activeDay ? (Number(root.activeDay.down) || 0) : 0
  readonly property double dayUp: root.activeDay ? (Number(root.activeDay.up) || 0) : 0
  readonly property bool hasTraffic: root.dayDown > 0 || root.dayUp > 0

  readonly property var stripCells: root.serviceReady ? Model.recentDays(root.days, root.todayKey, 7) : []
  readonly property double stripMax: Model.stripMax(root.stripCells)
  readonly property string attributionNote: root.serviceReady
    ? Model.attributionNote(Model.appList(root.activeDay, "down"), root.dayDown) : ""

  // ---- appearance ---------------------------------------------------------

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentBackground: bar ? bar.background : Color.background
  readonly property string contentFontFamily: Style.font.family

  readonly property color downColor: Palette.downColor(Color.accent, root.contentBackground)
  readonly property color upColor: Palette.upColor(Color.accent, root.contentBackground)

  function dim(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  readonly property color muted: root.dim(root.contentForeground, 0.62)
  readonly property color veryMuted: root.dim(root.contentForeground, 0.38)
  readonly property color rail: root.dim(root.contentForeground, 0.10)

  function cycleDay() {
    var cells = root.stripCells
    if (cells.length === 0) return
    var idx = -1
    for (var i = 0; i < cells.length; i++) if (cells[i].key === root.activeKey) idx = i
    idx = (idx <= 0) ? cells.length - 1 : idx - 1
    root.selectedKey = cells[idx].key === root.todayKey ? "" : cells[idx].key
  }

  // One bar. The rail is always drawn, so an app with almost nothing still
  // occupies a row you can read a name off, rather than vanishing.
  component ChartRow: Item {
    id: rowItem
    required property var row
    required property string dir
    required property double max
    required property double total
    required property color mark
    width: parent ? parent.width : 0
    height: Style.space(20)

    // The rolled-up tail is the only row that stands for other rows rather
    // than an app, so it is the only one worth clicking.
    readonly property bool isRollup: rowItem.row.kind === "other"
    signal activated()

    readonly property double value: rowItem.dir === "up" ? rowItem.row.up : rowItem.row.down
    // Containers and the unattributed row are dimmed rather than recoloured:
    // the ranking is one series, and a second hue would imply a second scale.
    readonly property real weight: rowItem.row.kind === "unattributed" ? 0.45
      : rowItem.row.kind === "other" ? 0.55
      : rowItem.row.kind === "container" ? 0.82 : 1.0

    Text {
      id: nameText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(104)
      elide: Text.ElideRight
      // Process names come from other people's programs. Anything but plain
      // text here would let a name choose markup, and one of them can be an
      // image tag pointing anywhere.
      textFormat: Text.PlainText
      text: rowItem.row.name
      color: rowItem.row.kind === "proc" ? root.contentForeground : root.muted
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      id: track
      anchors.left: nameText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(9)

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.rail
      }

      Rectangle {
        height: parent.height
        radius: height / 2
        width: Math.max(
          Model.barFraction(rowItem.value, rowItem.max) > 0 ? Style.space(3) : 0,
          parent.width * Model.barFraction(rowItem.value, rowItem.max))
        color: root.dim(rowItem.mark, rowItem.weight)

        Behavior on width {
          NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(62)
      textFormat: Text.PlainText
      text: Model.formatBytes(rowItem.value)
      color: root.muted
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: rowItem.isRollup ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (rowItem.isRollup) rowItem.activated()

      PanelToolTip {
        visible: rowHover.containsMouse
        text: rowItem.isRollup
          ? Model.plain(rowItem.row.name) + "  ·  "
            + Model.formatBytes(rowItem.value) + "  ·  click to list them"
          : Model.plain(rowItem.row.name) + "  ·  "
            + Model.formatBytes(rowItem.value)
            + (rowItem.total > 0 ? "  ·  " + Model.formatShare(rowItem.value, rowItem.total) : "")
            + (rowItem.row.kind === "container" ? "  ·  container" : "")
      }
    }
  }

  // One chart: a direction, its total, and the apps that spent it.
  component DirChart: Column {
    id: chart
    required property string title
    required property string glyph
    required property string dir
    required property var rows
    required property double total
    required property color mark
    required property bool expanded
    signal toggleExpand()
    spacing: Style.space(4)
    width: parent ? parent.width : 0

    readonly property double maxValue: Model.maxOf(chart.rows, chart.dir)

    Item {
      width: parent.width
      height: Style.space(22)

      Text {
        id: chartTitle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: chart.glyph + "  " + chart.title
        color: chart.mark
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Model.formatBytes(chart.total)
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.subtitle
      }
    }

    Repeater {
      model: chart.rows
      ChartRow {
        required property var modelData
        row: modelData
        dir: chart.dir
        max: chart.maxValue
        total: chart.total
        mark: chart.mark
        onActivated: chart.toggleExpand()
      }
    }

    // Expanding removes the roll-up row that opened the list, so the way back
    // has to be drawn somewhere. A plain line rather than another bar: it
    // stands for an action, and giving it a rail would imply it had a value.
    Item {
      visible: chart.expanded
      width: parent.width
      height: Style.space(20)

      Text {
        id: collapseLabel
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "show fewer"
        color: collapseHover.containsMouse ? root.contentForeground : root.veryMuted
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: collapseHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: chart.toggleExpand()
      }
    }

    // A chart with no bars still has to say something, or an empty area reads
    // as a failed load rather than a quiet day.
    Text {
      visible: chart.rows.length === 0
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.space(10)
      bottomPadding: Style.space(10)
      textFormat: Text.PlainText
      text: root.available ? "Nothing yet." : ""
      color: root.veryMuted
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      // Arrows scroll rather than change day. They used to cycle the day,
      // which `d` already does and the footer already names; once the content
      // outgrew the card, reaching the rest of it was the job with no key.
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) panelFlick.scrollBy(dy)
      }
      onTextKey: function (t) {
        if (t === "d" || t === "D") root.cycleDay()
        else if (t === "t" || t === "T") root.selectedKey = ""
        else if (t === "e" || t === "E") {
          // Both charts together: they are two views of one list, and leaving
          // them out of step makes the panel read as two unrelated states.
          var next = !(root.downExpanded && root.upExpanded)
          root.downExpanded = next
          root.upExpanded = next
        }
      }

      // Two ranked charts, a hero, a week strip and a footer run past any
      // height the card is willing to take, and the cap is reached well
      // before the content ends. Without somewhere to scroll, the upload
      // chart stopped mid-row and the week strip could not be reached at
      // all — the panel looked finished exactly where it ran out of room.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        // The key catcher takes arrows before the Flickable can, so the
        // keyboard path has to move the view itself rather than leave it
        // to the built-in handling.
        function scrollBy(steps) {
          if (contentHeight <= height) return
          var next = contentY + steps * Style.space(48)
          contentY = Math.max(0, Math.min(contentHeight - height, next))
        }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- header -------------------------------------------------------
          Item {
            width: parent.width
            height: Style.space(24)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.activeLabel
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.serviceReady && root.service.watching ? root.service.watching : ""
              color: root.veryMuted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- the collector is not running ---------------------------------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.serviceReady && !root.available

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.unavailableReason === "nethogs is not installed"
                ? "Not counting: nethogs is not installed. Without it, nothing on the machine can say which app spent what — the kernel does not keep that score."
                : "Not counting: " + (root.unavailableReason || "the collector is not running") + "."
              color: root.muted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: root.unavailableReason === "nethogs is not installed"
              textFormat: Text.PlainText
              text: "It is in the standard repositories, and it grants itself what it needs when it installs. No sudo or pkexec is required afterwards."
              color: root.veryMuted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- hero ---------------------------------------------------------
          Item {
            width: parent.width
            height: Style.space(46)
            visible: root.available || root.hasTraffic

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                anchors.baseline: downValue.baseline
                textFormat: Text.PlainText
                text: "󰇚"
                color: root.downColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                id: downValue
                textFormat: Text.PlainText
                text: Model.splitBytes(root.dayDown).value
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                anchors.baseline: downValue.baseline
                textFormat: Text.PlainText
                text: Model.splitBytes(root.dayDown).unit
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                anchors.baseline: upValue.baseline
                textFormat: Text.PlainText
                text: "󰕒"
                color: root.upColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                id: upValue
                textFormat: Text.PlainText
                text: Model.splitBytes(root.dayUp).value
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                anchors.baseline: upValue.baseline
                textFormat: Text.PlainText
                text: Model.splitBytes(root.dayUp).unit
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- the two charts -----------------------------------------------
          DirChart {
            title: "DOWNLOAD"
            glyph: "󰇚"
            dir: "down"
            rows: root.downRows
            total: root.dayDown
            mark: root.downColor
            expanded: root.downExpanded
            onToggleExpand: root.downExpanded = !root.downExpanded
          }

          PanelSeparator { width: parent.width }

          DirChart {
            title: "UPLOAD"
            glyph: "󰕒"
            dir: "up"
            rows: root.upRows
            total: root.dayUp
            mark: root.upColor
            expanded: root.upExpanded
            onToggleExpand: root.upExpanded = !root.upExpanded
          }

          // ---- honesty line -------------------------------------------------
          Text {
            width: parent.width
            visible: root.attributionNote !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.attributionNote
            color: root.veryMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { width: parent.width }

          // ---- seven-day strip, doubling as the day picker --------------------
          Row {
            id: strip
            width: parent.width
            height: Style.space(40)
            spacing: Style.space(4)

            readonly property real cellWidth:
              (width - spacing * Math.max(0, root.stripCells.length - 1)) / Math.max(1, root.stripCells.length)

            Repeater {
              model: root.stripCells

              Item {
                id: cell
                required property var modelData
                width: strip.cellWidth
                height: strip.height

                readonly property bool isActive: cell.modelData.key === root.activeKey
                readonly property double totalBytes: cell.modelData.down + cell.modelData.up

                // Down stacked on up, so a day's height is what it cost in total
                // and the split inside it stays visible.
                Item {
                  id: bars
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: dayLabel.top
                  anchors.bottomMargin: Style.space(4)
                  width: Math.min(parent.width - Style.space(4), Style.space(18))
                  height: Style.space(22)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(2)
                    color: root.rail
                  }

                  Column {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    spacing: 0

                    Rectangle {
                      width: parent.width
                      height: bars.height * Model.barFraction(cell.modelData.up, root.stripMax)
                      color: root.dim(root.upColor, cell.isActive ? 1.0 : 0.55)
                      Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    }

                    Rectangle {
                      width: parent.width
                      height: bars.height * Model.barFraction(cell.modelData.down, root.stripMax)
                      radius: Style.space(2)
                      color: root.dim(root.downColor, cell.isActive ? 1.0 : 0.55)
                      Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    }
                  }
                }

                Text {
                  id: dayLabel
                  anchors.bottom: parent.bottom
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: cell.modelData.label
                  color: cell.isActive ? root.contentForeground : root.veryMuted
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: cellHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedKey =
                    (cell.modelData.key === root.todayKey) ? "" : cell.modelData.key

                  PanelToolTip {
                    visible: cellHover.containsMouse
                    text: cell.modelData.weekday + "  ↓ "
                      + Model.formatBytes(cell.modelData.down)
                      + "   ↑ " + Model.formatBytes(cell.modelData.up)
                  }
                }
              }
            }
          }

          // ---- footer -------------------------------------------------------
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "↑↓ scroll    e all apps    d day    t today    esc close"
            color: root.veryMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // In the card's own padding rather than over the content. Attached to the
      // Flickable it lands exactly where every byte total is right-aligned, and
      // sat on top of the numbers it was there to help you reach. Out here it
      // costs nothing and doubles as the only standing hint that the panel has
      // more below the fold.
      Item {
        id: scrollRail
        visible: panelFlick.interactive
        anchors.top: panelFlick.top
        anchors.bottom: panelFlick.bottom
        anchors.left: panelFlick.right
        anchors.leftMargin: Math.max(2, Math.round((panel.padding - width) / 2))
        width: Style.space(3)

        readonly property real ratio: panelFlick.visibleArea.heightRatio

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: root.dim(root.contentForeground, 0.09)
        }

        Rectangle {
          width: parent.width
          radius: width / 2
          // A floor on the handle: proportional alone turns into a speck once
          // an expanded chart makes the content several screens long, and a
          // speck reads as a rendering fault rather than a position.
          height: Math.max(Style.space(20), parent.height * scrollRail.ratio)
          y: scrollRail.ratio >= 1 ? 0
            : (parent.height - height)
              * (panelFlick.visibleArea.yPosition / (1 - scrollRail.ratio))
          color: root.dim(root.contentForeground, panelFlick.moving ? 0.5 : 0.28)

          Behavior on color { ColorAnimation { duration: 160 } }
        }
      }
    }
  }
}
