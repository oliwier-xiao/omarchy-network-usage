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
  property bool countLanNoise: false
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

  // Every write to `days` replaces the objects it touches instead of editing
  // them, and that is load-bearing rather than a matter of taste. QML does not
  // re-signal a `var` property whose binding re-evaluates to the same object
  // reference it already held, and `today` is exactly such a binding — it
  // reads `days[todayKey]`. Editing that day in place therefore left `today`,
  // `todayDown`, `todayUp` and every chart in the panel pinned to the values
  // the day was created with, while the collector ran, the deltas landed and
  // the history file grew: a panel reading 0 B on top of a working counter.
  // Publishing a new object makes the reference differ, which is the only
  // thing the binding actually watches.
  function replaceDay(key, day) {
    var next = {}
    for (var k in root.days) next[k] = root.days[k]
    next[key] = day
    root.days = next
    root.pendingWrite = true
  }

  // Folds one row's delta into `day`, a copy owned by the caller. Returns
  // whether anything actually moved, so a quiet snapshot publishes nothing.
  function noteRow(row, day) {
    if (!row) return false
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
    if (dUp <= 0 && dDown <= 0) return false

    // A fresh app record too: the table was shallow-copied from the previous
    // day object, so editing this one would reach back into the record the
    // panel is still holding.
    var prevApp = day.apps[row.name]
    day.apps[row.name] = {
      up: (prevApp ? Number(prevApp.up) || 0 : 0) + dUp,
      down: (prevApp ? Number(prevApp.down) || 0 : 0) + dDown,
      kind: row.kind
    }
    day.up = (Number(day.up) || 0) + dUp
    day.down = (Number(day.down) || 0) + dDown
    return true
  }

  property bool pendingWrite: false
  property var pendingRows: []

  function rollTo(key) {
    if (!key || key === root.todayKey) return
    root.todayKey = key
    if (!root.days[key]) root.replaceDay(key, Model.emptyDay())
    // A new day is a new counting origin; the collector restarts too, but say
    // so here as well so a clock jump cannot fold yesterday into today.
    root.lastSeen = ({})
  }

  function commitSnapshot() {
    var rows = root.pendingRows
    root.pendingRows = []
    var key = root.todayKey
    if (rows.length === 0 || !key) return

    // One copy per snapshot rather than per row: the day and its app table are
    // rebuilt once, every row is folded into that copy, and the result is
    // published in a single assignment.
    var prevDay = root.days[key] || Model.emptyDay()
    var day = {
      up: Number(prevDay.up) || 0,
      down: Number(prevDay.down) || 0,
      apps: {}
    }
    var prevApps = prevDay.apps || {}
    for (var name in prevApps) day.apps[name] = prevApps[name]

    var moved = false
    for (var i = 0; i < rows.length; i++)
      if (root.noteRow(rows[i], day)) moved = true
    if (moved) root.replaceDay(key, day)
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
  onCountLanNoiseChanged: root.restartStream()

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
      "NET_USAGE_CONTAINERS": root.nameContainers ? "1" : "0",
      "NET_USAGE_LAN_NOISE": root.countLanNoise ? "1" : "0"
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
    // Capped on the way out as well as on the way in. This is the only writer,
    // so it is the place a file that the next read would have to truncate gets
    // prevented rather than merely detected.
    var capped = {}
    for (var k in root.days) capped[k] = Model.capApps(root.days[k], Model.MAX_APPS_PER_DAY)
    root.days = capped
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

  // Write-only, deliberately. FileView has no ceiling on what it will read and
  // no way to add one, and the process it would read into is the shell the
  // whole desktop runs in. Reading is bin/net-usage's job, where it is bounded.
  FileView {
    id: historyFile
    path: root.historyPath
    printErrors: false
    atomicWrites: true
    blockAllReads: true

    JsonAdapter {
      id: historyAdapter
      property var days: ({})
    }
  }

  Process {
    id: historyProc
    running: false
    command: ["timeout", "5", root.pluginDir + "/bin/net-usage", "history"]
    environment: ({ "HOME": root.home })

    stdout: StdioCollector {
      onStreamFinished: root.onHistoryText(this.text)
    }
    // If it never produced a stream at all — missing, killed, refused — the
    // plugin still has to start, on an empty day rather than not at all.
    onExited: if (!root.ready) root.onHistoryText("")
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

  // 1.0.0 counted the broadcast and multicast traffic that no socket on this
  // machine owns, and filed all of it under one name. On a shared network that
  // was routinely most of a day — one enormous bar standing for bytes nothing
  // here asked for or read. The real bytes in that row cannot be separated
  // from the noise after the fact, and keeping it would mean charts that
  // promise to leave that traffic out while still drawing it. So it goes, once,
  // on the upgrade, and the day totals come down with it.
  // Rebuilt rather than edited in place: what the adapter hands back is its
  // own nested value, and deleting a key inside it neither takes effect nor
  // marks the adapter dirty, so the write would go out still carrying the row.
  function dropLegacyBucket(store) {
    var LEGACY = "(unattributed)"
    var out = {}
    var touched = false
    for (var k in store) {
      var day = store[k]
      if (!day || !day.apps || !day.apps[LEGACY]) { out[k] = day; continue }
      var row = day.apps[LEGACY]
      var apps = {}
      for (var n in day.apps) if (n !== LEGACY) apps[n] = day.apps[n]
      out[k] = {
        up: Math.max(0, (day.up || 0) - (row.up || 0)),
        down: Math.max(0, (day.down || 0) - (row.down || 0)),
        apps: apps
      }
      touched = true
    }
    if (touched) root.pendingWrite = true
    return out
  }

  // The only way disk contents reach this process. Everything arriving here is
  // treated as though someone else wrote it, because at this path someone else
  // could have: parse defensively, validate and cap before use, and never
  // repair — a record that fails its check is dropped, not guessed at.
  function onHistoryText(text) {
    if (root.ready) return

    var raw = null
    var s = String(text || "")
    if (s.length > 0) {
      try {
        raw = JSON.parse(s)
      } catch (e) {
        // Unparseable, which includes the file having been truncated at the
        // read ceiling. Keep it aside once so it is not silently overwritten.
        keepBrokenProc.running = true
        raw = null
      }
    }

    var store = (raw && typeof raw === "object" && raw.days && typeof raw.days === "object")
      ? raw.days
      : ({})
    root.days = root.dropLegacyBucket(
      Model.sanitizeStore(store, Model.MAX_DAYS, Model.MAX_APPS_PER_DAY))
    root.begin()
  }

  // A history file that will not parse is not worth losing the day over, but
  // it is also not worth overwriting silently: keep it aside once, then start
  // clean. A missing file is the ordinary first run and says nothing.


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
    // `mkdir -m` sets the mode only on directories it actually creates, so one
    // that already exists keeps whatever it had — including a mode an older
    // version, a restored backup or a stray umask left readable to everyone.
    // Creating it and securing it are two statements, not one.
    command: ["sh", "-c",
      "d=\"$1\"; mkdir -p -m 700 -- \"$d\" 2>/dev/null || exit 0; " +
      "[ -L \"$d\" ] || chmod 700 -- \"$d\" 2>/dev/null; exit 0",
      "sh", root.dataDir]
    environment: ({ "HOME": root.home })
    onExited: historyProc.running = true
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
