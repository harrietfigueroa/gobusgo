// Checks what a bus's glyph draws in each status, as pure functions of
// values written out by hand: the fill, outline, dash, and ink of the bus,
// the text and mark of the route badge on its shoulder, the pale fill of a
// stale bus, the opacity of a regional dot's stroke, the names of the
// glyph's images with their round trip, and the contrast of every marker's
// edge on the light map's land.
// Run it with `node test/scripts/vehicle_glyph_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {contrastRatio} from "../../assets/js/core/math/color_contrast.js"
import {Theme, mapColors} from "../../assets/js/theme.js"
import {
  BadgeMark,
  GlyphImageKind,
  OutlineKind,
  dotStrokeOpacity,
  glyphImageName,
  glyphStyle,
  paleColor,
  parseGlyphImageName,
  routeBadgeStyle
} from "../../assets/js/vehicle_marker_shapes.js"

const RED = "#b91c1c"
const YELLOW = "#fdb71a"
const SLATE = "#334155"
const WHITE = "#ffffff"
const FADED_OPACITY = 0.45
const NON_TEXT_CONTRAST_MIN = 3
const CHANNEL_MAX = 255
const HEX_RADIX = 16
const HEX_PAIR_LENGTH = 2
const EDGE_COUNT_PER_STATUS = 3
const lightColors = mapColors(Theme.light)
const darkColors = mapColors(Theme.dark)

deepStrictEqual(paleColor("#000000"), "#bfbfbf", "black paled three quarters toward white")
deepStrictEqual(paleColor(RED), "#eec6c6", "a route's red paled")

const styleCases = [
  {
    case: "a live bus on a dark route, on the light map",
    given: {status: "reported", color: RED, colors: lightColors},
    style: {fill: RED, outline: SLATE, outlineKind: OutlineKind.solid, ink: WHITE}
  },
  {
    case: "a live bus on a light route, on the light map",
    given: {status: "reported", color: YELLOW, colors: lightColors},
    style: {fill: YELLOW, outline: SLATE, outlineKind: OutlineKind.solid, ink: "#0f172a"}
  },
  {
    case: "a live bus on the dark map",
    given: {status: "reported", color: RED, colors: darkColors},
    style: {fill: RED, outline: WHITE, outlineKind: OutlineKind.solid, ink: WHITE}
  },
  {
    case: "a stale bus",
    given: {status: "stale", color: RED, colors: lightColors},
    style: {fill: "#eec6c6", outline: SLATE, outlineKind: OutlineKind.solid, ink: SLATE}
  },
  {
    case: "a bus with no report time",
    given: {status: "unknown", color: RED, colors: lightColors},
    style: {fill: "#eec6c6", outline: SLATE, outlineKind: OutlineKind.dotted, ink: SLATE}
  },
  {
    case: "a schedule-only bus",
    given: {status: "scheduled", color: "#9ca3af", colors: lightColors},
    style: {fill: WHITE, outline: "#475569", outlineKind: OutlineKind.dashed, ink: "#475569"}
  }
]

for (const {case: caseName, given, style} of styleCases) {
  deepStrictEqual(glyphStyle(given), style, caseName)
}

const badgeCases = [
  {
    case: "a live bus's route, on the light map",
    given: {status: "reported", route: "E Line", color: RED, colors: lightColors},
    badge: {text: "E Line", mark: BadgeMark.none, fill: RED, ink: WHITE, border: SLATE}
  },
  {
    case: "a live bus's route, on the dark map",
    given: {status: "reported", route: "E Line", color: RED, colors: darkColors},
    badge: {text: "E Line", mark: BadgeMark.none, fill: RED, ink: WHITE, border: WHITE}
  },
  {
    case: "a stale bus's route and a clock",
    given: {status: "stale", route: "10", color: RED, colors: lightColors},
    badge: {text: "10", mark: BadgeMark.clock, fill: "#0f172a", ink: WHITE, border: SLATE}
  },
  {
    case: "a stale bus's route, on the dark map",
    given: {status: "stale", route: "10", color: RED, colors: darkColors},
    badge: {text: "10", mark: BadgeMark.clock, fill: "#0f172a", ink: WHITE, border: WHITE}
  },
  {
    case: "a stale bus with no route, the clock alone",
    given: {status: "stale", route: null, color: RED, colors: lightColors},
    badge: {text: "", mark: BadgeMark.clock, fill: "#0f172a", ink: WHITE, border: SLATE}
  },
  {
    case: "a bus with no report time, and a question mark",
    given: {status: "unknown", route: "10", color: RED, colors: lightColors},
    badge: {text: "10", mark: BadgeMark.question, fill: "#0f172a", ink: WHITE, border: SLATE}
  },
  {
    case: "a schedule-only bus's route",
    given: {status: "scheduled", route: "49", color: "#9ca3af", colors: lightColors},
    badge: {text: "49", mark: BadgeMark.none, fill: WHITE, ink: "#475569", border: "#475569"}
  }
]

for (const {case: caseName, given, badge} of badgeCases) {
  deepStrictEqual(routeBadgeStyle(given), badge, caseName)
}

// A faded dot keeps its stroke whole on the light map, and fades it with
// the dot on the dark one.
const strokeCases = [
  {case: "a faded dot's stroke on the light map", given: {opacity: FADED_OPACITY, colors: lightColors}, opacity: 1},
  {case: "a whole dot's stroke on the light map", given: {opacity: 1, colors: lightColors}, opacity: 1},
  {case: "a faded dot's stroke on the dark map", given: {opacity: FADED_OPACITY, colors: darkColors}, opacity: FADED_OPACITY},
  {case: "a whole dot's stroke on the dark map", given: {opacity: 1, colors: darkColors}, opacity: 1}
]

for (const {case: caseName, given, opacity} of strokeCases) {
  deepStrictEqual(dotStrokeOpacity(given), opacity, caseName)
}

// `foreground` at `alpha` over `background`, both written #rrggbb, as the
// browser composites them.
function blend({foreground, background, alpha}) {
  let blended = "#"

  for (let index = 1; index < foreground.length; index += HEX_PAIR_LENGTH) {
    const top = Number.parseInt(foreground.slice(index, index + HEX_PAIR_LENGTH), HEX_RADIX)
    const bottom = Number.parseInt(background.slice(index, index + HEX_PAIR_LENGTH), HEX_RADIX)
    const channel = Math.round(top * alpha + bottom * (1 - alpha))
    ok(channel <= CHANNEL_MAX, `a blended channel is at most ${CHANNEL_MAX}, got: ${channel}`)
    blended += channel.toString(HEX_RADIX).padStart(HEX_PAIR_LENGTH, "0")
  }

  return blended
}

// Every marker's edge on the light map stands at 3:1 or more against the
// land whatever its route's color, WCAG 2.2 1.4.11: a regional dot's
// stroke at the opacity it is drawn at, a glyph's outline, and its route
// badge's border. The statuses fade a dot to 0.45 while stale or with no
// report time. The land colors are the commonest of the light basemap
// downtown at zoom 14 and 16, sampled from screenshots.
// https://www.w3.org/TR/WCAG22/#non-text-contrast — checked 2026-11-10
const lightLands = ["#e2dfda", "#d7d6d3", "#d2d1d0"]
const statusOpacities = new Map([["reported", 1], ["stale", FADED_OPACITY], ["unknown", FADED_OPACITY], ["scheduled", 1]])
let edgeCaseCount = 0

for (const land of lightLands) {
  for (const [status, opacity] of statusOpacities) {
    const strokeOpacity = dotStrokeOpacity({opacity, colors: lightColors})
    const stroke = blend({foreground: lightColors.vehicleStroke, background: land, alpha: strokeOpacity})
    const dotRatio = contrastRatio({foreground: stroke, background: land})
    ok(dotRatio >= NON_TEXT_CONTRAST_MIN, `a ${status} dot's stroke ${stroke} on ${land} is ${dotRatio}:1`)

    const {outline} = glyphStyle({status, color: YELLOW, colors: lightColors})
    const glyphRatio = contrastRatio({foreground: outline, background: land})
    ok(glyphRatio >= NON_TEXT_CONTRAST_MIN, `a ${status} glyph's outline ${outline} on ${land} is ${glyphRatio}:1`)

    const {border} = routeBadgeStyle({status, route: "10", color: YELLOW, colors: lightColors})
    const badgeRatio = contrastRatio({foreground: border, background: land})
    ok(badgeRatio >= NON_TEXT_CONTRAST_MIN, `a ${status} route badge's border ${border} on ${land} is ${badgeRatio}:1`)
    edgeCaseCount += EDGE_COUNT_PER_STATUS
  }
}

const glyphName = glyphImageName({part: "glyph", status: "stale", color: RED, theme: "dark", route: ""})
deepStrictEqual(glyphName, "vehicle-glyph|glyph|stale|#b91c1c|dark|", "a glyph's image name")
deepStrictEqual(
  parseGlyphImageName("vehicle-glyph|badge|reported|#b91c1c|light|E Line"),
  {kind: GlyphImageKind.glyph, part: "badge", status: "reported", color: RED, theme: "light", route: "E Line"},
  "a badge's image name read back"
)
deepStrictEqual(
  parseGlyphImageName("vehicle-glyph|badge|reported|#b91c1c|light|A|B"),
  {kind: GlyphImageKind.glyph, part: "badge", status: "reported", color: RED, theme: "light", route: "A|B"},
  "a route name holding the separator read back whole"
)
deepStrictEqual(parseGlyphImageName("stop-sign-light"), {kind: GlyphImageKind.other}, "another image's name")

function parseUnknownPart() {
  parseGlyphImageName("vehicle-glyph|wheel|reported|#b91c1c|light|")
}

throws(parseUnknownPart, "an image of an unknown part")

const NAME_CASE_COUNT = 5
const PALE_CASE_COUNT = 2
const caseCount = styleCases.length + badgeCases.length + strokeCases.length + edgeCaseCount + NAME_CASE_COUNT + PALE_CASE_COUNT
console.log(`vehicle glyphs: ${caseCount} cases hold`)
