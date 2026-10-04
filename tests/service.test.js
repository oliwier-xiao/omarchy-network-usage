"use strict"

// Service.qml's own JavaScript, run under node. The functions and the
// collector's line handler are read out of the file as they are and called on a
// stand-in for `root`, with the Timers and Processes they touch replaced by
// recorders. Nothing here is a copy of the logic: change Service.qml and this
// runs the change.

const { test } = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../lib/Model.js")

const QML = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
  .split("\n").map(l => l.replace(/^\s*\/\/.*$/, "")).join("\n")

function closing(s, open) {
  let depth = 0
  for (let i = open; i < s.length; i++) {
    if (s[i] === "{") depth++
    else if (s[i] === "}" && --depth === 0) return i
  }
  throw new Error("unbalanced braces")
}

function fn(name) {
  const m = new RegExp("function " + name + "\\s*\\(([^)]*)\\)\\s*\\{").exec(QML)
  if (!m) throw new Error("Service.qml has no function " + name)
  const open = m.index + m[0].length - 1
  return { args: m[1], body: QML.slice(open + 1, closing(QML, open)) }
}

function handler(marker) {
  const at = QML.indexOf(marker)
  if (at < 0) throw new Error("Service.qml has no " + marker)
  const open = QML.indexOf("{", at)
  return QML.slice(open + 1, closing(QML, open))
}

const IDS = ["historyRetry", "historyDeadline", "historyProc", "keepBrokenProc", "doctorProc",
             "startTimer", "streamProc", "retryTimer", "saveTimer", "historyWrite"]

function service(extra) {
  const calls = []
  const ids = {}
  for (const id of IDS) {
    ids[id] = {
      running: false,
      restart() { calls.push(id + ".restart") },
      stop() { calls.push(id + ".stop") },
      write() {},
    }
  }
  const root = Object.assign({
    days: {}, todayKey: "2026-10-04", ready: true, keepDays: 90,
    lastSeen: Object.create(null), lastKernel: Object.create(null),
    pendingRows: [], pendingKers: [], pendingWrite: false, fenceNextEnd: false,
    dropSnapshot: false, watching: "", available: false, unavailableReason: "",
    doctorReason: "", lastRestartReason: "",
    historyText: "", historyStreamDone: false, historyCode: -1, historyTries: 0, saveBlocked: false,
    home: "/home/u", pluginDir: "/p",
    daysChanged() {},   // the property's change signal, which begin() emits by hand
  }, extra || {})
  const scope = ["root", "Model", "Qt", "console", "Quickshell"].concat(IDS)
  const values = [root, Model, { callLater(f) { f() } }, { warn() {} }, { env() { return "" } }]
    .concat(IDS.map(id => ids[id]))
  for (const name of ["replaceDay", "noteRow", "noteKers", "rollTo", "commitSnapshot", "pruneOld",
                      "dropLegacyBucket", "settleHistory", "historyFailed", "save", "begin",
                      "onHistoryText", "loadHistory", "childEnv"]) {
    const f = fn(name)
    root[name] = new Function(...scope, "return function (" + f.args + ") {" + f.body + "}")(...values)
  }
  const onRead = handler("onRead: function (line) {")
  root.onRead = new Function(...scope, "return function (line) {" + onRead + "}")(...values)
  Object.defineProperty(root, "today", { get() { return root.days[root.todayKey] || Model.emptyDay() } })
  root.calls = calls
  root.ids = ids
  return root
}

function feed(root, lines) { for (const l of lines) root.onRead(l) }
function snap(day, rows) {
  return ["snap\t" + day].concat(rows.map(r => "row\t" + r.join("\t")), ["end"])
}

test("a stale snapshot after midnight is dropped, not counted into yesterday again", () => {
  const root = service()
  root.days = { "2026-10-04": Model.emptyDay() }
  let total = 0
  for (let i = 0; i < 5; i++) {
    total += 400e6
    feed(root, snap("2026-10-04", [[0, total, "proc", "curl"]]))
  }
  assert.equal(root.days["2026-10-04"].down, total)
  // The panel's own timer turns the day first; the collector has not probed yet.
  root.rollTo("2026-10-05")
  feed(root, snap("2026-10-04", [[0, total + 1e6, "proc", "curl"]]))
  assert.equal(root.todayKey, "2026-10-05", "never rolled back")
  assert.equal(root.days["2026-10-04"].down, total, "yesterday is not counted twice")
  // The collector restarts on its own day change and counts the new day from zero.
  feed(root, snap("2026-10-05", [[0, 5e6, "proc", "curl"]]))
  assert.equal(root.days["2026-10-05"].down, 5e6)
})

test("a process and a container with one name are two running totals", () => {
  const root = service()
  root.days = { "2026-10-04": Model.emptyDay() }
  feed(root, snap("2026-10-04", [[0, 1000, "proc", "nginx"], [0, 50000, "container", "nginx"]]))
  feed(root, snap("2026-10-04", [[0, 1500, "proc", "nginx"], [0, 59000, "container", "nginx"]]))
  feed(root, snap("2026-10-04", [[0, 2000, "proc", "nginx"], [0, 68000, "container", "nginx"]]))
  assert.equal(root.days["2026-10-04"].down, 2000 + 68000)
  assert.equal(root.days["2026-10-04"].apps.nginx.down, 2000 + 68000)
})

test("names a plain object already has do not wipe the day", () => {
  const root = service()
  root.days = { "2026-10-04": Model.emptyDay() }
  const names = ["constructor", "toString", "valueOf", "hasOwnProperty", "__proto__"]
  feed(root, snap("2026-10-04", names.map(n => [100, 1000, "proc", n])))
  feed(root, snap("2026-10-04", names.map(n => [120, 1100, "proc", n])))
  const day = root.days["2026-10-04"]
  assert.equal(day.down, 1100 * names.length)
  assert.equal(day.up, 120 * names.length)
  for (const n of names) assert.equal(day.apps[n].down, 1100, n)
})

test("a restart note starts the running totals again", () => {
  const root = service()
  root.days = { "2026-10-04": Model.emptyDay() }
  feed(root, snap("2026-10-04", [[0, 3700000, "proc", "curl"]]))
  feed(root, ["note\trestart\troute-moved"])
  // the END snapshot of the old collector is fenced off
  feed(root, snap("2026-10-04", [[0, 3700000, "proc", "curl"]]))
  // the new collector's total overtakes the old one: all of it is new
  feed(root, snap("2026-10-04", [[0, 4700000, "proc", "curl"]]))
  assert.equal(root.days["2026-10-04"].down, 3700000 + 4700000)
})

test("ready names the interface; counting shows as working from the first snapshot", () => {
  const root = service()
  root.days = { "2026-10-04": Model.emptyDay() }
  root.doctorReason = "nethogs cannot open a capture socket"
  root.available = false
  root.unavailableReason = root.doctorReason
  feed(root, ["ready\twg0\t2"])
  assert.equal(root.watching, "wg0")
  assert.equal(root.available, false, "a nethogs that dies at once said ready every two seconds")
  feed(root, ["wait\tnethogs stopped right after starting"])
  assert.equal(root.unavailableReason, "nethogs cannot open a capture socket", "doctor's reason stands")
  feed(root, snap("2026-10-04", []))
  assert.equal(root.available, true)
  assert.equal(root.unavailableReason, "")
})

test("a history read that was killed is retried, and never written over", () => {
  const root = service({ ready: false })
  root.historyStreamDone = true
  root.historyCode = 124
  root.settleHistory()
  assert.equal(root.ready, false)
  assert.ok(root.calls.includes("historyRetry.restart"))
  root.historyTries = 3
  root.settleHistory()
  assert.equal(root.ready, true, "it still starts, on today alone")
  assert.equal(root.saveBlocked, true)
  root.pendingWrite = true
  root.save()
  assert.equal(root.ids.historyWrite.running, false, "nothing is written over a history it could not read")
})

test("a history the reader refused is kept aside; a readable one is loaded", () => {
  const refused = service({ ready: false })
  refused.historyStreamDone = true
  refused.historyCode = 3
  refused.settleHistory()
  assert.equal(refused.ids.keepBrokenProc.running, true)
  assert.equal(refused.ready, true)
  assert.equal(refused.saveBlocked, false)

  const ok = service({ ready: false })
  ok.historyText = JSON.stringify({ days: { "2026-10-03": { up: 1, down: 2, apps: {} } } })
  ok.historyStreamDone = true
  ok.historyCode = 0
  ok.settleHistory()
  assert.equal(ok.ready, true)
  assert.equal(ok.days["2026-10-03"].down, 2)
})

test("every process starts from a cleared environment", () => {
  const procs = QML.split(/\n\s*Process \{/).slice(1)
  assert.equal(procs.length, 6)
  for (const p of procs) {
    assert.match(p, /clearEnvironment: true/)
    assert.match(p, /environment: root\.childEnv\(/)
    assert.doesNotMatch(p, /command: \["(sh|timeout)"/, "commands are named absolutely")
  }
  const env = service().childEnv({ "NET_USAGE_IFACE": "eth0" })
  assert.deepEqual(Object.keys(env).sort(), ["HOME", "LC_ALL", "NET_USAGE_IFACE", "PATH"])
  assert.equal(env.LC_ALL, "C")
})
