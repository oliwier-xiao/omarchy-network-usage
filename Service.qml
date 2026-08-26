import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Model.js" as Model

// Long-running byte counter.
//
// bin/net-usage streams one block per sample, each row a running total for one
// app since the stream started. This file turns those into per-day totals and
// keeps them on disk:
//
//   ~/.local/state/omarchy/network-usage/history.json
//   { "<YYYY-MM-DD>": { "up": <bytes>, "down": <bytes>,
//                       "apps": { "<name>": { "up": n, "down": n, "kind": s } } } }
//
// State, not config: these are numbers the machine produced, not preferences a
// person set, and nothing here is meant to be hand-edited.
//
// All the side effects live in this file — the process, the timers, the disk.
// lib/Model.js is pure and testable; the panel is a read-only mirror.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  // Pushed in by the bar widget, which is the half of the plugin that can see
  // the manifest's settings. The stream restarts when the ones it depends on
  // change; the rest are read at use.
  property int sampleSeconds: 2
  property int keepDays: 90
  property bool nameContainers: true
  property string interfaceName: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string dataDir: home + "/.local/state/omarchy/network-usage"
  readonly property string historyPath: dataDir + "/history.json"

  // Nothing derived is safe to read until history has loaded: before then
  // todayKey is empty and every label would render against an empty record.
  property bool ready: false
  // Whether the collector is actually producing numbers. The panel says so
  // plainly rather than drawing an empty chart that looks like zero traffic.
  property bool available: false
  property string unavailableReason: ""
  property string watching: ""

  property string todayKey: ""
  property var days: ({})
  readonly property var today: root.days[root.todayKey] || Model.emptyDay()

  readonly property double todayDown: root.today ? (Number(root.today.down) || 0) : 0
  readonly property double todayUp: root.today ? (Number(root.today.up) || 0) : 0
  readonly property bool hasTraffic: root.todayDown > 0 || root.todayUp > 0

  // Running totals from the current stream, so a restart of the collector is
  // not mistaken for traffic. Cleared whenever the stream stands down.
  property var lastSeen: ({})

  // ------------------------------------------------------------- accumulate

  function noteRow(row) {
    if (!row) return
    var prev = root.lastSeen[row.name]
    var dUp, dDown
    if (prev === undefined) {
      // First sight in this stream: the running total IS the delta.
      dUp = row.up; dDown = row.down
    } else {
      dUp = row.up - prev.up
      dDown = row.down - prev.down
      // A total that fell means the collector restarted its counting, so the
      // new value is a fresh total rather than something to subtract from.
      if (dUp < 0) dUp = row.up
      if (dDown < 0) dDown = row.down
    }
    root.lastSeen[row.name] = { up: row.up, down: row.down }
    if (dUp <= 0 && dDown <= 0) return

    var key = root.todayKey
    if (!key) return
    // Read-modify-write the whole day object. Mutating in place would leave
    // the adapter unaware that anything changed, and nothing would ever be
    // written — a failure that looks perfectly healthy until the shell
    // restarts and the day is gone.
    var day = root.days[key] || Model.emptyDay()
    var apps = day.apps || {}
    var app = apps[row.name] || { up: 0, down: 0, kind: row.kind }
    app.up = (Number(app.up) || 0) + dUp
    app.down = (Number(app.down) || 0) + dDown
    app.kind = row.kind
    apps[row.name] = app
    day.apps = apps
    day.up = (Number(day.up) || 0) + dUp
    day.down = (Number(day.down) || 0) + dDown
    root.days[key] = day
    root.pendingWrite = true
  }

  property bool pendingWrite: false
  property var pendingRows: []

  function rollTo(key) {
    if (!key || key === root.todayKey) return
    root.todayKey = key
    if (!root.days[key]) {
      root.days[key] = Model.emptyDay()
      root.pendingWrite = true
    }
    // A new day is a new counting origin; the collector restarts too, but say
    // so here as well so a clock jump cannot fold yesterday into today.
    root.lastSeen = ({})
    root.daysChanged()
  }

  function commitSnapshot() {
    var rows = root.pendingRows
    root.pendingRows = []
    for (var i = 0; i < rows.length; i++) root.noteRow(rows[i])
    if (rows.length > 0) root.daysChanged()
  }

  // ------------------------------------------------------------- collector

  function restartStream() {
    streamProc.running = false
    root.lastSeen = ({})
    startTimer.restart()
  }

  onSampleSecondsChanged: root.restartStream()
  onInterfaceNameChanged: root.restartStream()
  onNameContainersChanged: root.restartStream()

  Timer {
    id: startTimer
    interval: 400
    onTriggered: if (root.ready) streamProc.running = true
  }

  Process {
    id: streamProc
    running: false
    command: {
      var c = [root.pluginDir + "/bin/net-usage", "stream", String(root.sampleSeconds)]
      return c
    }
    environment: ({
      "HOME": root.home,
      "NET_USAGE_IFACE": root.interfaceName,
      "NET_USAGE_CONTAINERS": root.nameContainers ? "1" : "0"
    })

    stdout: SplitParser {
      onRead: function (line) {
        var s = String(line)
        // A single line is never legitimately this long; refusing it unread
        // is cheaper than discovering why it was.
        if (s.length > 4096) return

        if (s.indexOf("ready\t") === 0) {
          var f = s.split("\t")
          root.watching = f.length > 1 ? f[1] : ""
          root.available = true
          root.unavailableReason = ""
          return
        }
        if (s.indexOf("wait\t") === 0) {
          root.available = false
          root.unavailableReason = s.split("\t")[1] || "waiting"
          return
        }
        if (s.indexOf("snap\t") === 0) {
          var day = s.split("\t")[1] || ""
          if (day) root.rollTo(day)
          root.pendingRows = []
          return
        }
        if (s === "end") { root.commitSnapshot(); return }
        if (s.indexOf("row\t") !== 0) return
        if (root.pendingRows.length >= 2000) return
        var row = Model.parseRow(s)
        if (row) root.pendingRows.push(row)
      }
    }

    onExited: function (code) {
      root.available = false
      if (!root.unavailableReason)
        root.unavailableReason = "the collector stopped"
      // net-usage stream restarts nethogs by itself; reaching here means the
      // wrapper died, which is worth a slower retry than a tight loop.
      if (root.ready) retryTimer.restart()
    }
  }

  Timer {
    id: retryTimer
    interval: 15000
    onTriggered: if (root.ready) streamProc.running = true
  }

  // The collector answering for itself, so the panel can say what is missing
  // rather than showing an empty chart.
  Process {
    id: doctorProc
    running: false
    command: [root.pluginDir + "/bin/net-usage", "doctor"]
    environment: ({ "HOME": root.home })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f[0] === "nethogs" && f[1] === "missing") {
            root.available = false
            root.unavailableReason = "nethogs is not installed"
            return
          }
          if (f[0] === "caps" && f[1] === "missing") {
            root.available = false
            root.unavailableReason = "nethogs cannot open a capture socket"
            return
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- persistence

  function scheduleSave() { saveTimer.restart() }

  function pruneOld(store) {
    var cutoff = Model.shiftKey(root.todayKey, -Math.max(1, root.keepDays))
    if (!cutoff) return store
    var out = {}
    for (var k in store) if (k >= cutoff) out[k] = store[k]
    return out
  }

  function save() {
    if (!root.ready) return
    root.days = root.pruneOld(root.days)
    historyAdapter.days = root.days
    historyFile.writeAdapter()
    root.pendingWrite = false
  }

  Timer {
    id: saveTimer
    interval: 20000
    repeat: true
    running: root.ready
    onTriggered: if (root.pendingWrite) root.save()
  }

  FileView {
    id: historyFile
    path: root.historyPath
    printErrors: false
    atomicWrites: true
    onLoaded: root.onHistoryLoaded()
    onLoadFailed: root.onHistoryLoadFailed()

    JsonAdapter {
      id: historyAdapter
      property var days: ({})
    }
  }

  function begin() {
    root.todayKey = Model.dayKey(new Date())
    if (!root.days[root.todayKey]) root.days[root.todayKey] = Model.emptyDay()
    root.days = root.pruneOld(root.days)
    root.ready = true
    root.daysChanged()
    doctorProc.running = true
    startTimer.restart()
  }

  function onHistoryLoaded() {
    var loaded = historyAdapter.days
    root.days = (loaded && typeof loaded === "object") ? loaded : ({})
    root.begin()
  }

  // A history file that will not parse is not worth losing the day over, but
  // it is also not worth overwriting silently: keep it aside once, then start
  // clean. A missing file is the ordinary first run and says nothing.
  function onHistoryLoadFailed() {
    root.days = ({})
    keepBrokenProc.running = true
    root.begin()
  }

  Process {
    id: keepBrokenProc
    running: false
    command: ["sh", "-c",
      "f=\"$1\"; [ -s \"$f\" ] && [ ! -e \"$f.broken\" ] && mv -- \"$f\" \"$f.broken\"; exit 0",
      "sh", root.historyPath]
    environment: ({ "HOME": root.home })
  }

  Process {
    id: ensureDirProc
    running: true
    command: ["mkdir", "-p", "-m", "700", root.dataDir]
    environment: ({ "HOME": root.home })
    onExited: historyFile.reload()
  }

  // Midnight, a resume from suspend, or a clock jump all land here.
  Timer {
    interval: 30000
    repeat: true
    running: root.ready
    onTriggered: {
      var key = Model.dayKey(new Date())
      if (key !== root.todayKey) {
        if (root.pendingWrite) root.save()
        root.rollTo(key)
      }
    }
  }

  Component.onDestruction: if (root.pendingWrite) root.save()
}
