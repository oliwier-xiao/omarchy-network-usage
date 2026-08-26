// Colour. Omarchy gives five theme roles — foreground, background, accent,
// urgent, muted — and all the chrome uses them directly. The charts need two
// more marks than that: one for what came down and one for what went up.
//
// They are generated, not written down. Both are hue rotations off the theme's
// own accent, then bisected on lightness until they clear a contrast ratio
// against the surface they sit on. That way they follow a theme swap by
// construction, and there is no theme in which a bar disappears into its
// background.
//
// Colour is deliberately not load-bearing here. Download and upload live in
// two separate, individually labelled charts, so the hue is decoration and a
// reader who cannot tell the two apart loses nothing — which is the whole
// reason for two charts rather than one chart with two colours.

// ---------------------------------------------------------------- luminance

function channelLum(c) {
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

function hexRgb(hex) {
  var s = String(hex || "").replace("#", "")
  if (s.length === 3) s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2]
  if (s.length < 6) return { r: 0, g: 0, b: 0 }
  return {
    r: parseInt(s.substr(0, 2), 16) / 255,
    g: parseInt(s.substr(2, 2), 16) / 255,
    b: parseInt(s.substr(4, 2), 16) / 255
  }
}

// Accepts a QML color (.r/.g/.b in 0..1) or a "#rrggbb" string, so callers can
// hand it a theme token or a literal without converting first.
function lumOf(c) {
  var rgb = (c && typeof c === "object" && c.r !== undefined) ? c : hexRgb(c)
  return 0.2126 * channelLum(rgb.r) + 0.7152 * channelLum(rgb.g) + 0.0722 * channelLum(rgb.b)
}

function contrast(a, b) {
  var la = lumOf(a), lb = lumOf(b)
  var hi = Math.max(la, lb), lo = Math.min(la, lb)
  return (hi + 0.05) / (lo + 0.05)
}

function isDarkSurface(c) { return lumOf(c) < 0.5 }

// ---------------------------------------------------------------- hsl

function toHsl(c) {
  var rgb = (c && typeof c === "object" && c.r !== undefined) ? c : hexRgb(c)
  var r = rgb.r, g = rgb.g, b = rgb.b
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2, h = 0, s = 0
  if (max !== min) {
    var d = max - min
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    if (max === r) h = ((g - b) / d + (g < b ? 6 : 0))
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h *= 60
  }
  return { h: h, s: s * 100, l: l * 100 }
}

function hslHex(h, s, l) {
  var hh = ((h % 360) + 360) % 360 / 360
  var ss = Math.max(0, Math.min(100, s)) / 100
  var ll = Math.max(0, Math.min(100, l)) / 100
  function hue2(p, q, t) {
    if (t < 0) t += 1
    if (t > 1) t -= 1
    if (t < 1 / 6) return p + (q - p) * 6 * t
    if (t < 1 / 2) return q
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
    return p
  }
  var r, g, b
  if (ss === 0) { r = g = b = ll }
  else {
    var q = ll < 0.5 ? ll * (1 + ss) : ll + ss - ll * ss
    var p = 2 * ll - q
    r = hue2(p, q, hh + 1 / 3); g = hue2(p, q, hh); b = hue2(p, q, hh - 1 / 3)
  }
  function hx(v) {
    var s2 = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
    return s2.length === 1 ? "0" + s2 : s2
  }
  return "#" + hx(r) + hx(g) + hx(b)
}

// ---------------------------------------------------------------- marks

var MIN_CONTRAST = 3.2   // large solid shapes, not body text
var DOWN_HUE_SHIFT = -18 // toward the cool half: arriving, incoming
var UP_HUE_SHIFT = 142   // far enough round to never be confused with it

// Find a lightness for this hue that clears the floor against the surface.
//
// A mid-grey background is the case that breaks the obvious approaches: it is
// neither light nor dark, and a fixed offset in either direction lands inside
// the range no colour can escape. So walk outward from a preferred starting
// tone — lighter on a dark surface, darker on a light one — and take the first
// step that is legible, which keeps the mark as close to the theme's own
// weight as the contrast requirement allows.
//
// A hue that cannot reach the floor anywhere (a mid grey against mid grey)
// still has to return something, and the most legible thing available beats
// an arbitrary one.
function legible(hue, sat, surface) {
  var dark = isDarkSurface(surface)
  var start = dark ? 62 : 42
  var best = null
  var bestRatio = -1

  for (var step = 0; step <= 92; step += 2) {
    // Preferred direction first, so a tie goes to the tone that sits with the
    // theme rather than against it.
    var order = dark ? [start + step, start - step] : [start - step, start + step]
    for (var i = 0; i < order.length; i++) {
      var l = order[i]
      if (l < 4 || l > 96) continue
      var candidate = hslHex(hue, sat, l)
      var ratio = contrast(candidate, surface)
      if (ratio >= MIN_CONTRAST) return candidate
      if (ratio > bestRatio) { bestRatio = ratio; best = candidate }
    }
  }
  return best || hslHex(hue, sat, dark ? 88 : 16)
}

function markFor(accent, surface, shift) {
  var h = toHsl(accent)
  // A near-grey accent carries no usable hue, so borrow a saturation floor
  // rather than rotating grey into more grey.
  var sat = Math.max(38, Math.min(72, h.s))
  return legible(h.h + shift, sat, surface)
}

function downColor(accent, surface) { return markFor(accent, surface, DOWN_HUE_SHIFT) }
function upColor(accent, surface) { return markFor(accent, surface, UP_HUE_SHIFT) }

// The rail a bar sits in, and the tint a bar gets when it is not a process:
// containers and the unattributed row are dimmed rather than recoloured, so
// the ranking stays readable as one series.
function railColor(foreground) {
  var h = toHsl(foreground)
  return hslHex(h.h, Math.min(h.s, 20), isDarkSurface(foreground) ? 30 : 70)
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    lumOf: lumOf,
    contrast: contrast,
    isDarkSurface: isDarkSurface,
    toHsl: toHsl,
    hslHex: hslHex,
    legible: legible,
    markFor: markFor,
    downColor: downColor,
    upColor: upColor,
    railColor: railColor,
    MIN_CONTRAST: MIN_CONTRAST
  }
}
