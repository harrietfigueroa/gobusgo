// Checks what a bus's glyph draws in each status, as pure functions of
// values written out by hand: the fill, outline, dash, and ink of the bus,
// the text and mark of the route badge on its shoulder, the pale fill of a
// stale bus, and the names of the glyph's images with their round trip.
// Run it with `node test/scripts/vehicle_glyph_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  BadgeMark,
  GlyphImageKind,
  OutlineKind,
  glyphImageName,
  glyphStyle,
  paleColor,
  parseGlyphImageName,
  routeBadgeStyle
} from "../../assets/js/vehicle_marker_shapes.js"

const RED = "#b91c1c"
const YELLOW = "#fdb71a"
const colors = {vehicleStroke: "#334155", glyphLiveOutline: "#ffffff", badgeInk: "#0f172a", badgePaper: "#ffffff"}

deepStrictEqual(paleColor("#000000"), "#bfbfbf", "black paled three quarters toward white")
deepStrictEqual(paleColor(RED), "#eec6c6", "a route's red paled")

const styleCases = [
  {
    case: "a live bus on a dark route",
    given: {status: "reported", color: RED},
    style: {fill: RED, outline: "#ffffff", outlineKind: OutlineKind.solid, ink: "#ffffff"}
  },
  {
    case: "a live bus on a light route",
    given: {status: "reported", color: YELLOW},
    style: {fill: YELLOW, outline: "#ffffff", outlineKind: OutlineKind.solid, ink: "#0f172a"}
  },
  {
    case: "a stale bus",
    given: {status: "stale", color: RED},
    style: {fill: "#eec6c6", outline: "#334155", outlineKind: OutlineKind.solid, ink: "#334155"}
  },
  {
    case: "a bus with no report time",
    given: {status: "unknown", color: RED},
    style: {fill: "#eec6c6", outline: "#334155", outlineKind: OutlineKind.dotted, ink: "#334155"}
  },
  {
    case: "a schedule-only bus",
    given: {status: "scheduled", color: "#9ca3af"},
    style: {fill: "#ffffff", outline: "#475569", outlineKind: OutlineKind.dashed, ink: "#475569"}
  }
]

for (const {case: caseName, given, style} of styleCases) {
  deepStrictEqual(glyphStyle({...given, colors}), style, caseName)
}

const badgeCases = [
  {
    case: "a live bus's route",
    given: {status: "reported", route: "E Line", color: RED},
    badge: {text: "E Line", mark: BadgeMark.none, fill: RED, ink: "#ffffff", border: "#ffffff"}
  },
  {
    case: "a stale bus's route and a clock",
    given: {status: "stale", route: "10", color: RED},
    badge: {text: "10", mark: BadgeMark.clock, fill: "#0f172a", ink: "#ffffff", border: "#ffffff"}
  },
  {
    case: "a stale bus with no route, the clock alone",
    given: {status: "stale", route: null, color: RED},
    badge: {text: "", mark: BadgeMark.clock, fill: "#0f172a", ink: "#ffffff", border: "#ffffff"}
  },
  {
    case: "a bus with no report time, and a question mark",
    given: {status: "unknown", route: "10", color: RED},
    badge: {text: "10", mark: BadgeMark.question, fill: "#0f172a", ink: "#ffffff", border: "#ffffff"}
  },
  {
    case: "a schedule-only bus's route",
    given: {status: "scheduled", route: "49", color: "#9ca3af"},
    badge: {text: "49", mark: BadgeMark.none, fill: "#ffffff", ink: "#475569", border: "#475569"}
  }
]

for (const {case: caseName, given, badge} of badgeCases) {
  deepStrictEqual(routeBadgeStyle(given), badge, caseName)
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
console.log(`vehicle glyphs: ${styleCases.length + badgeCases.length + NAME_CASE_COUNT + PALE_CASE_COUNT} cases hold`)
