"use strict"

// Protocol v1: day records gain kUp/kDown/restarts (additive, default 0);
// Model gains wireDown/wireUp (fallback to down/up) and divergenceNote(day)
// (empty unless kDown>=20MB and down>kDown*2, message contains the multiple
// like x2.3 and the words net-usage validate).

const { test } = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../lib/Model.js")

const MB = 1024 * 1024

// Additive kernel counters ride beside the app-counted totals, defaulting to
// zero, so an old history file without them still reads as a day with no
// kernel sample rather than as a corrupt day.
test("sanitizeStore passes kUp/kDown/restarts through", () => {
  const store = Model.sanitizeStore({
    "2026-08-27": { up: 100, down: 200, kUp: 300, kDown: 400, restarts: 2, apps: {} }
  }, 400, 100)
  assert.equal(store["2026-08-27"].kUp, 300)
  assert.equal(store["2026-08-27"].kDown, 400)
  assert.equal(store["2026-08-27"].restarts, 2)
})

// Missing kernel fields are dropped, not repaired — the file-level rule this
// function has always kept. Absent reads as "no sample" downstream, so the
// wire helpers fall back to the counted totals instead of drawing a zero.
test("sanitizeStore leaves missing kernel fields absent and the wire falls back", () => {
  const store = Model.sanitizeStore({
    "2026-08-27": { up: 100, down: 200, apps: {} }
  }, 400, 100)
  const day = store["2026-08-27"]
  assert.equal(day.kUp, undefined)
  assert.equal(day.kDown, undefined)
  assert.equal(day.restarts, undefined)
  assert.equal(Model.wireDown(day), 200, "no sample falls back to counted down")
  assert.equal(Model.wireUp(day), 100, "no sample falls back to counted up")
})

// Garbage is dropped for the same reason: a zeroed kDown would read as a
// sample of zero and hide the real counted bytes, while absent lets the
// fallback show them.
test("sanitizeStore drops garbage kernel fields", () => {
  const store = Model.sanitizeStore({
    "2026-08-27": { up: 100, down: 200, kUp: -5, kDown: NaN, restarts: "x", apps: {} }
  }, 400, 100)
  const day = store["2026-08-27"]
  assert.equal(day.kUp, undefined, "a negative counter is dropped, not kept")
  assert.equal(day.kDown, undefined, "NaN is dropped, not zeroed")
  assert.equal(day.restarts, undefined, "a string is dropped, not zeroed")
})

// Capping and pruning reshape the per-app map; the kernel counters describe
// the wire, not the apps, so they must survive both untouched.
test("capApps preserves kUp/kDown/restarts", () => {
  const apps = {}
  for (let i = 0; i < 10; i++) apps["app" + i] = { up: 1, down: 1, kind: "proc" }
  const capped = Model.capApps({ up: 10, down: 10, kUp: 11, kDown: 12, restarts: 3, apps }, 5)
  assert.equal(capped.kUp, 11)
  assert.equal(capped.kDown, 12)
  assert.equal(capped.restarts, 3)
})

// The wire totals are the kernel counters when present and the app-counted
// totals when the day predates them — never undefined, never NaN.
test("wireDown/wireUp prefer the kernel counter and fall back to the totals", () => {
  assert.equal(Model.wireDown({ up: 1, down: 2, kDown: 400 }), 400)
  assert.equal(Model.wireUp({ up: 1, down: 2, kUp: 300 }), 300)
  assert.equal(Model.wireDown({ up: 1, down: 2 }), 2, "no kernel sample falls back to counted down")
  assert.equal(Model.wireUp({ up: 1, down: 2 }), 1, "no kernel sample falls back to counted up")
  assert.equal(Model.wireDown({ up: 1, down: 2, kDown: 0 }), 0, "an explicit zero is a sample, not an absence")
})

// The divergence note is the panel's tripwire: quiet by default, specific
// when the counted bytes dwarf what the kernel saw on the wire.
test("divergenceNote stays empty when the kernel sample is too small to trust", () => {
  assert.equal(Model.divergenceNote({ up: 0, down: 100 * MB, kDown: 10 * MB }), "")
})

test("divergenceNote stays empty when counted is within twice the kernel", () => {
  assert.equal(Model.divergenceNote({ up: 0, down: 40 * MB, kDown: 30 * MB }), "")
  assert.equal(Model.divergenceNote({ up: 0, down: 60 * MB, kDown: 30 * MB }), "", "exactly twice is not above twice")
})

test("divergenceNote names the multiple and points at validate", () => {
  const note = Model.divergenceNote({ up: 0, down: 69 * MB, kDown: 30 * MB })
  assert.ok(note.length > 0, "a 2.3x divergence must say something")
  assert.ok(/x2\.3/.test(note), "the message contains the multiple, got: " + note)
  assert.ok(note.includes("net-usage validate"), "the message points at the tool, got: " + note)
})

// kers rows carry ABSOLUTE kernel counters (since boot). Counting the first
// sight as a delta would add the whole boot total — gigabytes — as phantom
// traffic for the day, so first sight is a pure baseline.
test("kersDelta treats first sight as a baseline, not traffic", () => {
  assert.deepEqual(Model.kersDelta(undefined, 9000000000, 500000000), { dRx: 0, dTx: 0 })
  assert.deepEqual(Model.kersDelta(null, 9000000000, 500000000), { dRx: 0, dTx: 0 })
})

// The common case: two absolute readings, the delta is what moved between
// them, per side.
test("kersDelta returns per-side deltas between absolute readings", () => {
  assert.deepEqual(
    Model.kersDelta({ rx: 9000000000, tx: 500000000 }, 9010000000, 500500000),
    { dRx: 10000000, dTx: 500000 })
})

// A counter that went backwards wrapped or reset (interface re-created,
// 64-bit rollover). The delta would be negative nonsense; the current value
// is the only honest reading for that side.
test("kersDelta returns the current value when a counter wraps", () => {
  assert.deepEqual(
    Model.kersDelta({ rx: 9000000000, tx: 500000000 }, 1000000, 500500000),
    { dRx: 1000000, dTx: 500000 })
})

// Upload-only movement must not conjure download bytes, and vice versa — a
// zero delta is a zero, not an absence.
test("kersDelta keeps a quiet side at zero", () => {
  assert.deepEqual(
    Model.kersDelta({ rx: 9000000000, tx: 500000000 }, 9000000000, 500500000),
    { dRx: 0, dTx: 500000 })
})

// Counters arrive from text parsing, so NaN and negatives are a matter of
// time. They coerce to 0 on the way in; the negative delta below resolves to
// the coerced current value, so no NaN or negative ever comes out to poison
// the day totals.
test("kersDelta coerces garbage readings to zero", () => {
  assert.deepEqual(Model.kersDelta({ rx: 100, tx: 50 }, NaN, -10), { dRx: 0, dTx: 0 })
})

test("kersDelta never emits NaN or negatives", () => {
  const cases = [
    [undefined, NaN, -10],
    [null, -1, Infinity],
    [{ rx: NaN, tx: -5 }, NaN, -10],
    [{ rx: 1e15, tx: 1e15 }, 0, 0]
  ]
  for (const [prev, rx, tx] of cases) {
    const r = Model.kersDelta(prev, rx, tx)
    assert.ok(r.dRx >= 0 && isFinite(r.dRx), "dRx clean, got: " + JSON.stringify(r))
    assert.ok(r.dTx >= 0 && isFinite(r.dTx), "dTx clean, got: " + JSON.stringify(r))
  }
})
