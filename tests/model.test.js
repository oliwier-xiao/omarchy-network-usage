"use strict"

const { test } = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../lib/Model.js")

// The single most dangerous line in the plugin. nethogs prints totals at six
// significant digits, so anything past a megabyte arrives in scientific
// notation; parseInt reads "3.09517e+06" as 3 and reports a 3 MB download as
// three bytes, with nothing anywhere to suggest something went wrong.
test("parseRow widens scientific notation instead of truncating it", () => {
  const row = Model.parseRow("row\t82734\t3.09517e+06\tproc\tcurl")
  assert.equal(row.up, 82734)
  assert.equal(row.down, 3095170)
  assert.notEqual(row.down, 3)
})

test("parseRow keeps a name that contains tabs-free spaces and slashes", () => {
  const row = Model.parseRow("row\t10\t20\tproc\t/usr/lib/chromium/chromium")
  assert.equal(row.name, "/usr/lib/chromium/chromium")
  assert.equal(row.kind, "proc")
})

test("parseRow refuses every shape that is not a row", () => {
  assert.equal(Model.parseRow("Refreshing:"), null)
  assert.equal(Model.parseRow("Adding local address: 10.48.23.73"), null)
  assert.equal(Model.parseRow("Unknown connection: 172.19.0.2:53736-172.66.0.218:80"), null)
  assert.equal(Model.parseRow("snap\t2026-08-26"), null)
  assert.equal(Model.parseRow("end"), null)
  assert.equal(Model.parseRow(""), null)
  assert.equal(Model.parseRow(null), null)
  assert.equal(Model.parseRow("row\tnope\t20\tproc\tx"), null)
  assert.equal(Model.parseRow("row\t-5\t20\tproc\tx"), null)
  assert.equal(Model.parseRow("row\t10\t20\tproc\t"), null)
})

// A max of zero would make every width NaN and blank the chart, which reads as
// a broken plugin rather than an empty one.
test("barFraction floors the divisor so an empty chart still draws", () => {
  assert.equal(Model.barFraction(0, 0), 0)
  assert.equal(Model.barFraction(5, 0), 1)
  assert.equal(Model.barFraction(50, 100), 0.5)
  assert.equal(Model.barFraction(500, 100), 1, "never overflows the track")
  assert.equal(Model.barFraction(-5, 100), 0)
  assert.equal(Model.barFraction("x", 100), 0)
})

test("formatBytes uses 1024 and drops the decimal where it is noise", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(-1), "0 B")
  assert.equal(Model.formatBytes(512), "512 B")
  assert.equal(Model.formatBytes(1024), "1 KB")
  assert.equal(Model.formatBytes(1536), "1.5 KB")
  assert.equal(Model.formatBytes(1024 * 1024), "1 MB")
  assert.equal(Model.formatBytes(3095170), "3 MB")
  assert.equal(Model.formatBytes(1024 * 1024 * 150), "150 MB")
})

test("splitBytes separates the number from its unit", () => {
  assert.deepEqual(Model.splitBytes(1536), { value: "1.5", unit: "KB" })
  assert.deepEqual(Model.splitBytes(0), { value: "0", unit: "B" })
})

// Names are written by other people's programs and end up inside a shell
// component that renders AutoText.
test("plain strips anything a name could use as markup", () => {
  assert.equal(Model.plain('<img src="http://x/">'), ' img src="http://x/" ')
  assert.equal(Model.plain("a &amp; b"), "a  amp; b")
  assert.equal(Model.plain("curl"), "curl")
  assert.equal(Model.plain(null), "")
})

test("shiftKey crosses month and year boundaries", () => {
  assert.equal(Model.shiftKey("2026-08-26", -1), "2026-08-25")
  assert.equal(Model.shiftKey("2026-03-01", -1), "2026-02-28")
  assert.equal(Model.shiftKey("2026-01-01", -1), "2025-12-31")
  assert.equal(Model.shiftKey("nonsense", -1), "")
})

test("dayKey pads month and day", () => {
  assert.equal(Model.dayKey(new Date(2026, 7, 26)), "2026-08-26")
  assert.equal(Model.dayKey(new Date(2026, 0, 3)), "2026-01-03")
})

const DAY = {
  up: 300, down: 3000,
  apps: {
    curl: { up: 100, down: 2000, kind: "proc" },
    "webae-postgres": { up: 50, down: 900, kind: "container" },
    "(unknown UDP)": { up: 0, down: 60, kind: "unattributed" },
    chatty: { up: 150, down: 40, kind: "proc" },
    silent: { up: 0, down: 0, kind: "proc" }
  }
}

test("appList ranks by the direction asked for and drops empty rows", () => {
  const down = Model.appList(DAY, "down")
  assert.deepEqual(down.map(r => r.name), ["curl", "webae-postgres", "(unknown UDP)", "chatty"])
  const up = Model.appList(DAY, "up")
  assert.equal(up[0].name, "chatty", "upload ranks differently from download")
})

test("topRows rolls the tail into one row rather than dropping it", () => {
  const rows = Model.topRows(Model.appList(DAY, "down"), 2, "down", true)
  assert.equal(rows.length, 3)
  assert.equal(rows[2].name, "2 more")
  assert.equal(rows[2].down, 100, "the tail keeps its bytes")
  assert.equal(rows[2].kind, "other")
})

test("topRows can hide the unattributed row without losing the others", () => {
  const rows = Model.topRows(Model.appList(DAY, "down"), 10, "down", false)
  assert.equal(rows.some(r => r.kind === "unattributed"), false)
  assert.equal(rows.length, 3)
})

// A roll-up surviving beside the rows it stood for would count its bytes twice.
test("an unlimited topRows lists every app and drops the roll-up", () => {
  const all = Model.appList(DAY, "down")
  const capped = Model.topRows(all, 2, "down", true)
  const rows = Model.topRows(all, Infinity, "down", true)

  assert.equal(rows.some(r => r.kind === "other"), false, "no roll-up row")
  assert.equal(rows.length, all.length, "every app is listed")
  assert.equal(
    rows.reduce((t, r) => t + r.down, 0),
    capped.reduce((t, r) => t + r.down, 0),
    "expanding moves no bytes, it only stops summarising them")
})

test("recentDays always returns the full strip, gaps included", () => {
  const cells = Model.recentDays({ "2026-08-26": DAY }, "2026-08-26", 7)
  assert.equal(cells.length, 7)
  assert.equal(cells[6].key, "2026-08-26")
  assert.equal(cells[6].isToday, true)
  assert.equal(cells[0].down, 0, "a day with no record reads as zero, not as missing")
  assert.equal(cells[6].down, 3000)
})

test("formatDate names the recent days and dates the rest", () => {
  assert.equal(Model.formatDate("2026-08-26", "2026-08-26"), "Today")
  assert.equal(Model.formatDate("2026-08-25", "2026-08-26"), "Yesterday")
  assert.equal(Model.formatDate("2026-08-20", "2026-08-26"), "Thu 20 Aug")
  assert.equal(Model.formatDate("", "2026-08-26"), "")
})

test("attributionNote stays quiet below one percent", () => {
  assert.equal(Model.attributionNote(Model.appList(DAY, "down"), 3000), "2% could not be traced to an app")
  const tiny = { up: 0, down: 10000, apps: { "(unknown UDP)": { up: 0, down: 1, kind: "unattributed" } } }
  assert.equal(Model.attributionNote(Model.appList(tiny, "down"), 10000), "")
})

// The gap arrives as one row per protocol. Reporting the larger of the two
// would quietly halve the number the line exists to be honest about.
test("attributionNote adds the unknown buckets together", () => {
  const split = {
    up: 0, down: 1000,
    apps: {
      curl: { up: 0, down: 800, kind: "proc" },
      "(unknown TCP)": { up: 0, down: 120, kind: "unattributed" },
      "(unknown UDP)": { up: 0, down: 80, kind: "unattributed" }
    }
  }
  const rows = Model.appList(split, "down")
  assert.equal(Model.attributionNote(rows, 1000), "20% could not be traced to an app")
})

test("both unknown buckets hide together", () => {
  const split = {
    up: 0, down: 1000,
    apps: {
      curl: { up: 0, down: 800, kind: "proc" },
      "(unknown TCP)": { up: 0, down: 120, kind: "unattributed" },
      "(unknown UDP)": { up: 0, down: 80, kind: "unattributed" }
    }
  }
  const rows = Model.topRows(Model.appList(split, "down"), 10, "down", false)
  assert.deepEqual(rows.map(r => r.name), ["curl"])
})

test("dayFor falls back to an empty day rather than undefined", () => {
  const empty = Model.dayFor({}, null, "2026-01-01", "2026-08-26")
  assert.equal(empty.down, 0)
  assert.deepEqual(empty.apps, {})
})

// ---------------------------------------------------------------- hardening

test("capApps keeps the busiest names and folds the rest without losing bytes", () => {
  const apps = {}
  for (let i = 0; i < 250; i++) apps["app" + i] = { up: i, down: i * 2, kind: "proc" }
  const day = { up: 31125, down: 62250, apps }
  const capped = Model.capApps(day, 100)

  assert.equal(Object.keys(capped.apps).length, 101, "100 names plus one overflow row")
  assert.ok(capped.apps["app249"], "the busiest survived")
  assert.equal(capped.apps["app0"], undefined, "the quietest did not")

  const sum = Object.values(capped.apps).reduce((t, r) => t + r.up + r.down, 0)
  const before = Object.values(apps).reduce((t, r) => t + r.up + r.down, 0)
  assert.equal(sum, before, "capping moves bytes, it never drops them")
})

test("capApps accumulates into an overflow row that already exists", () => {
  const apps = { "(other apps)": { up: 1000, down: 2000, kind: "other" } }
  for (let i = 0; i < 10; i++) apps["app" + i] = { up: 1, down: 1, kind: "proc" }
  const capped = Model.capApps({ up: 0, down: 0, apps }, 5)
  assert.equal(capped.apps["(other apps)"].up, 1000 + 5, "the old sum is carried, not replaced")
})

test("capApps leaves a day that fits completely alone", () => {
  const day = { up: 1, down: 2, apps: { curl: { up: 1, down: 2, kind: "proc" } } }
  assert.equal(Model.capApps(day, 100), day, "same object back, no needless copy")
})

test("sanitizeStore drops everything that is not a plausible record", () => {
  const store = Model.sanitizeStore({
    "2026-08-27": { up: 5, down: 6, apps: { curl: { up: 5, down: 6, kind: "proc" } } },
    "not-a-date": { up: 1, down: 1, apps: {} },
    "2026-08-26": "a string where a day should be",
    "2026-08-25": { up: -9, down: NaN, apps: {
      ok: { up: 1, down: 1, kind: "proc" },
      negative: { up: -5, down: 1, kind: "proc" },
      infinite: { up: Infinity, down: 1, kind: "proc" },
      notAnObject: 42
    } }
  }, 400, 100)

  assert.deepEqual(Object.keys(store).sort(), ["2026-08-25", "2026-08-27"])
  assert.equal(store["2026-08-27"].apps.curl.down, 6)
  assert.deepEqual(Object.keys(store["2026-08-25"].apps), ["ok"], "only the sane row survives")
  assert.equal(store["2026-08-25"].up, 0, "a negative total reads as zero, not as itself")
  assert.equal(store["2026-08-25"].down, 0, "NaN reads as zero")
})

test("sanitizeStore keeps the most recent days when there are too many", () => {
  const raw = {}
  for (let d = 1; d <= 28; d++) {
    const key = "2026-02-" + String(d).padStart(2, "0")
    raw[key] = { up: d, down: d, apps: {} }
  }
  const store = Model.sanitizeStore(raw, 5, 100)
  assert.deepEqual(Object.keys(store).sort(), [
    "2026-02-24", "2026-02-25", "2026-02-26", "2026-02-27", "2026-02-28"
  ])
})

test("sanitizeStore survives the shapes a hostile file would actually take", () => {
  assert.deepEqual(Model.sanitizeStore(null, 400, 100), {})
  assert.deepEqual(Model.sanitizeStore("a string", 400, 100), {})
  assert.deepEqual(Model.sanitizeStore(12345, 400, 100), {})
  assert.deepEqual(Model.sanitizeStore([], 400, 100), {})
  assert.deepEqual(Model.sanitizeStore({ __proto__: { evil: 1 } }, 400, 100), {})
})

test("sanitizeStore clips a name long enough to be a payload", () => {
  const apps = {}
  apps["x".repeat(5000)] = { up: 1, down: 1, kind: "y".repeat(5000) }
  const store = Model.sanitizeStore({ "2026-08-27": { up: 1, down: 1, apps } }, 400, 100)
  const name = Object.keys(store["2026-08-27"].apps)[0]
  assert.equal(name.length, 128)
  assert.equal(store["2026-08-27"].apps[name].kind.length, 32)
})
