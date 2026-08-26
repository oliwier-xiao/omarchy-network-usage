"use strict"

const { test } = require("node:test")
const assert = require("node:assert/strict")
const P = require("../lib/Palette.js")

// A sweep of real Omarchy theme surfaces, light and dark, plus the awkward
// ones: near-black, near-white, and a mid grey where neither direction is
// obviously the safe one.
const SURFACES = [
  "#101315", "#000000", "#1a1b26", "#282828", "#2e3440", "#24273a",
  "#ffffff", "#fafafa", "#eff1f5", "#e4e4e4", "#808080", "#7f7f7f"
]

// Accents from actual themes, including two deliberately unusable ones: a
// pure grey with no hue to rotate, and a colour that sits right on a common
// background.
const ACCENTS = [
  "#cacccc", "#7aa2f7", "#a6e3a1", "#e78284", "#d79921", "#b48ead",
  "#808080", "#000000", "#ffffff", "#101315"
]

test("every direction mark clears the contrast floor on every surface", () => {
  for (const surface of SURFACES) {
    for (const accent of ACCENTS) {
      for (const [label, color] of [["down", P.downColor(accent, surface)],
                                    ["up", P.upColor(accent, surface)]]) {
        const ratio = P.contrast(color, surface)
        assert.ok(ratio >= P.MIN_CONTRAST - 0.01,
          `${label} mark ${color} on ${surface} (accent ${accent}) only reaches ${ratio.toFixed(2)}`)
      }
    }
  }
})

// The two marks never have to be told apart — that is what the two separate
// charts are for — but they should not be the same colour either, or the
// separation looks like an accident rather than a decision.
test("download and upload are visibly different hues", () => {
  for (const accent of ACCENTS) {
    const d = P.toHsl(P.downColor(accent, "#101315"))
    const u = P.toHsl(P.upColor(accent, "#101315"))
    let gap = Math.abs(d.h - u.h) % 360
    if (gap > 180) gap = 360 - gap
    assert.ok(gap > 60, `accent ${accent} produced hues only ${gap.toFixed(0)}° apart`)
  }
})

test("a greyscale accent still yields a coloured mark rather than more grey", () => {
  const mark = P.downColor("#808080", "#101315")
  assert.ok(P.toHsl(mark).s >= 30, `saturation floor did not apply: ${mark}`)
})

test("isDarkSurface splits light from dark", () => {
  assert.equal(P.isDarkSurface("#101315"), true)
  assert.equal(P.isDarkSurface("#ffffff"), false)
})

test("hslHex round-trips through toHsl", () => {
  const hex = P.hslHex(210, 60, 50)
  const back = P.toHsl(hex)
  assert.ok(Math.abs(back.h - 210) < 2, `hue drifted to ${back.h}`)
  assert.ok(Math.abs(back.s - 60) < 2, `saturation drifted to ${back.s}`)
})

test("contrast is symmetric and bounded", () => {
  assert.ok(Math.abs(P.contrast("#000", "#fff") - 21) < 0.1)
  assert.equal(P.contrast("#123456", "#123456").toFixed(3), "1.000")
})
