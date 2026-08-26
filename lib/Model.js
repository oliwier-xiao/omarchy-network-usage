// Pure helpers for the network-usage plugin: parsing the collector's output,
// turning byte counts into something readable, and working out bar geometry.
// No QML types, no side effects, no I/O — everything here is a function of its
// arguments so tests/model.test.js can run it under plain node.

var UNATTRIBUTED = "(unattributed)"

// ---------------------------------------------------------------- formatting

var UNITS = ["B", "KB", "MB", "GB", "TB", "PB"]

// 1024-based with the short labels, which is what every desktop tool shows and
// what the number in a router's admin page means to the person reading it.
function formatBytes(n) {
  var b = Number(n)
  if (!isFinite(b) || b <= 0) return "0 B"
  var i = 0
  while (b >= 1024 && i < UNITS.length - 1) { b /= 1024; i++ }
  // Bytes are whole things; anything larger reads better with one decimal,
  // except once it is into three digits where the decimal is just noise.
  if (i === 0) return Math.round(b) + " B"
  return (b >= 100 ? Math.round(b) : Math.round(b * 10) / 10) + " " + UNITS[i]
}

// Split so a panel can draw the number large and the unit small beside it.
function splitBytes(n) {
  var s = formatBytes(n)
  var gap = s.lastIndexOf(" ")
  return { value: s.slice(0, gap), unit: s.slice(gap + 1) }
}

function formatRate(bytesPerSecond) {
  return formatBytes(bytesPerSecond) + "/s"
}

// Shell components such as the tooltip render their text as AutoText, which
// treats anything that looks like markup as markup. An app name is written by
// somebody else's program, so a process called `<img src="http://...">` would
// otherwise fetch that URL from inside the shell. Everything untrusted goes
// through here before it reaches a component this plugin does not own.
function plain(s) {
  return String(s === undefined || s === null ? "" : s).replace(/[<>&]/g, " ")
}

// ---------------------------------------------------------------- date keys

function dayKey(date) {
  var d = date || new Date()
  var m = d.getMonth() + 1
  var day = d.getDate()
  return d.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
}

function shiftKey(key, deltaDays) {
  var p = String(key).split("-")
  if (p.length !== 3) return ""
  var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
  if (isNaN(d.getTime())) return ""
  d.setDate(d.getDate() + deltaDays)
  return dayKey(d)
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function parseKey(key) {
  var p = String(key).split("-")
  if (p.length !== 3) return null
  var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
  return isNaN(d.getTime()) ? null : d
}

function weekdayShort(key) {
  var d = parseKey(key)
  return d ? WEEKDAYS[d.getDay()] : ""
}

function formatDate(key, todayKey) {
  if (!key) return ""
  if (key === todayKey) return "Today"
  if (todayKey && key === shiftKey(todayKey, -1)) return "Yesterday"
  var d = parseKey(key)
  if (!d) return String(key)
  return WEEKDAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
}

// ---------------------------------------------------------------- collector

// One row of `net-usage stream`: row<TAB>up<TAB>down<TAB>kind<TAB>name.
// The name is last precisely because it is the only field that may contain
// anything at all, so it never has to be escaped or quoted.
function parseRow(line) {
  if (typeof line !== "string") return null
  var f = line.split("\t")
  if (f.length < 5 || f[0] !== "row") return null
  // Six significant digits means anything past a megabyte arrives as
  // 5.12971e+06. Number widens that; parseInt would read it as 5.
  var up = Number(f[1])
  var down = Number(f[2])
  if (!isFinite(up) || !isFinite(down) || up < 0 || down < 0) return null
  var name = f.slice(4).join("\t")
  if (!name) return null
  return { up: up, down: down, kind: f[3], name: name }
}

// ---------------------------------------------------------------- day record

function emptyDay() {
  return { up: 0, down: 0, apps: {} }
}

// { name: {up, down, kind} } -> sorted array, largest first in `dir`.
function appList(day, dir) {
  if (!day || !day.apps) return []
  var out = []
  for (var name in day.apps) {
    var a = day.apps[name]
    if (!a) continue
    var up = Number(a.up) || 0
    var down = Number(a.down) || 0
    if (up <= 0 && down <= 0) continue
    out.push({ name: name, up: up, down: down, kind: a.kind || "proc" })
  }
  var key = (dir === "up") ? "up" : "down"
  out.sort(function (x, y) { return y[key] - x[key] || (x.name < y.name ? -1 : 1) })
  return out
}

// Keep the top `limit` and roll the tail into one row, so a long tail of
// tiny talkers cannot push the interesting bars off the panel.
function topRows(rows, limit, dir, showUnattributed) {
  var key = (dir === "up") ? "up" : "down"
  var kept = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (!showUnattributed && r.kind === "unattributed") continue
    if (r[key] <= 0) continue
    kept.push(r)
  }
  if (kept.length <= limit) return kept
  var head = kept.slice(0, limit)
  var rest = kept.slice(limit)
  var sum = 0
  for (var j = 0; j < rest.length; j++) sum += rest[j][key]
  if (sum > 0) {
    var other = { name: rest.length + " more", kind: "other", up: 0, down: 0 }
    other[key] = sum
    head.push(other)
  }
  return head
}

function sumOf(rows, dir) {
  var key = (dir === "up") ? "up" : "down"
  var t = 0
  for (var i = 0; i < rows.length; i++) t += rows[i][key] || 0
  return t
}

// ---------------------------------------------------------------- geometry

// Bar length as a fraction of the track. The floor on the divisor is the
// highest-consequence line here: a max of 0 would make every width NaN and
// blank the whole chart rather than draw an empty one.
function barFraction(value, max) {
  var v = Number(value) || 0
  var m = Math.max(Number(max) || 0, 1)
  if (v <= 0) return 0
  return Math.min(1, v / m)
}

function maxOf(rows, dir) {
  var key = (dir === "up") ? "up" : "down"
  var m = 0
  for (var i = 0; i < rows.length; i++) if (rows[i][key] > m) m = rows[i][key]
  return m
}

function share(value, total) {
  var t = Number(total) || 0
  if (t <= 0) return 0
  return Math.min(1, (Number(value) || 0) / t)
}

function formatShare(value, total) {
  var pct = share(value, total) * 100
  if (pct <= 0) return ""
  return (pct < 1 ? "<1" : Math.round(pct)) + "%"
}

// ---------------------------------------------------------------- 7-day strip

// The footer strip and day picker. Always exactly `count` cells ending today,
// so the row never changes width and missing days read as empty rather than
// being skipped over.
function recentDays(days, todayKey, count) {
  var out = []
  if (!todayKey) return out
  for (var i = count - 1; i >= 0; i--) {
    var key = shiftKey(todayKey, -i)
    var d = days && days[key] ? days[key] : null
    out.push({
      key: key,
      label: weekdayShort(key).charAt(0),
      weekday: weekdayShort(key),
      up: d ? Number(d.up) || 0 : 0,
      down: d ? Number(d.down) || 0 : 0,
      isToday: key === todayKey
    })
  }
  return out
}

function stripMax(cells) {
  var m = 0
  for (var i = 0; i < cells.length; i++) {
    var t = (cells[i].down || 0) + (cells[i].up || 0)
    if (t > m) m = t
  }
  return m
}

function dayFor(days, todayRecord, selectedKey, todayKey) {
  if (!selectedKey || selectedKey === todayKey) return todayRecord || emptyDay()
  return (days && days[selectedKey]) ? days[selectedKey] : emptyDay()
}

// A single honest line about how much of the day the numbers could not place.
function attributionNote(rows, total) {
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind !== "unattributed") continue
    var pct = Math.round(share(rows[i].down, total) * 100)
    if (pct < 1) return ""
    return pct + "% could not be traced to an app"
  }
  return ""
}

// Exported for tests. QML imports this file directly and ignores the guard;
// `node --test` needs it, and the accumulator arithmetic below is exactly the
// kind that fails silently rather than loudly.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    UNATTRIBUTED: UNATTRIBUTED,
    formatBytes: formatBytes,
    splitBytes: splitBytes,
    formatRate: formatRate,
    plain: plain,
    dayKey: dayKey,
    shiftKey: shiftKey,
    weekdayShort: weekdayShort,
    formatDate: formatDate,
    parseRow: parseRow,
    emptyDay: emptyDay,
    appList: appList,
    topRows: topRows,
    sumOf: sumOf,
    barFraction: barFraction,
    maxOf: maxOf,
    share: share,
    formatShare: formatShare,
    recentDays: recentDays,
    stripMax: stripMax,
    dayFor: dayFor,
    attributionNote: attributionNote
  }
}
