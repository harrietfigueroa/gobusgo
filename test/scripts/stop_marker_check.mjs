// Checks what a stop's marker draws, as pure functions of values written out
// by hand: the angle of each direction's arrow, the chips beside the sign
// and the count of the rest, the chips' image names and their round trip,
// and the side of the sign the chips stand on. Run it with
// `node test/scripts/stop_marker_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  AngleKind,
  ChipsImageKind,
  CURB_OFFSET_UNITS,
  ChipsSide,
  chipsImageName,
  chipsOffset,
  chipsOffsetCases,
  chipsSide,
  curbOffset,
  curbOffsetCases,
  directionAngle,
  iconSizeAt,
  signBox,
  parseChipsImageName,
  shownChips
} from "../../assets/js/stop_marker_shapes.js"

const angleCases = [
  {direction: "N", angle: {kind: AngleKind.found, degrees: 0}},
  {direction: "NE", angle: {kind: AngleKind.found, degrees: 45}},
  {direction: "E", angle: {kind: AngleKind.found, degrees: 90}},
  {direction: "SE", angle: {kind: AngleKind.found, degrees: 135}},
  {direction: "S", angle: {kind: AngleKind.found, degrees: 180}},
  {direction: "SW", angle: {kind: AngleKind.found, degrees: 225}},
  {direction: "W", angle: {kind: AngleKind.found, degrees: 270}},
  {direction: "NW", angle: {kind: AngleKind.found, degrees: 315}},
  {direction: "Inbound", angle: {kind: AngleKind.missing}},
  {direction: undefined, angle: {kind: AngleKind.missing}}
]

for (const {direction, angle} of angleCases) {
  deepStrictEqual(directionAngle(direction), angle, `angle of ${String(direction)}`)
}

const sideCases = [
  {direction: "N", side: ChipsSide.below},
  {direction: "E", side: ChipsSide.below},
  {direction: "W", side: ChipsSide.below},
  {direction: "SE", side: ChipsSide.above},
  {direction: "S", side: ChipsSide.above},
  {direction: "SW", side: ChipsSide.above},
  {direction: undefined, side: ChipsSide.below}
]

for (const {direction, side} of sideCases) {
  deepStrictEqual(chipsSide(direction), side, `chips side of ${String(direction)}`)
}

// The sign stands to the right of the stop's direction of travel, on a
// north-up map with y downward: north's right is east, east's is south. A
// diagonal direction's offset is the curb offset times cos 45°, rounded to
// hundredths.
const CURB = CURB_OFFSET_UNITS
const CURB_DIAGONAL = 11.31
const curbCases = [
  {direction: "N", offset: [CURB, 0]},
  {direction: "NE", offset: [CURB_DIAGONAL, CURB_DIAGONAL]},
  {direction: "E", offset: [0, CURB]},
  {direction: "SE", offset: [-CURB_DIAGONAL, CURB_DIAGONAL]},
  {direction: "S", offset: [-CURB, 0]},
  {direction: "SW", offset: [-CURB_DIAGONAL, -CURB_DIAGONAL]},
  {direction: "W", offset: [0, -CURB]},
  {direction: "NW", offset: [CURB_DIAGONAL, -CURB_DIAGONAL]},
  {direction: "Inbound", offset: [0, 0]},
  {direction: undefined, offset: [0, 0]}
]

for (const {direction, offset} of curbCases) {
  deepStrictEqual(curbOffset(direction), offset, `curb offset of ${String(direction)}`)
}

// The chips follow the sign to its curb, then stand on their side of it,
// written out as the sums rounded to hundredths: 13 − 11.31 and 13 − 16.
const CHIPS_GAP_UNITS = 13
const DIAGONAL_CHIPS_Y = 1.69
const WEST_CHIPS_Y = -3
const chipsOffsetCaseList = [
  {direction: "N", offset: [CURB, CHIPS_GAP_UNITS]},
  {direction: "NW", offset: [CURB_DIAGONAL, DIAGONAL_CHIPS_Y]},
  {direction: "SE", offset: [-CURB_DIAGONAL, -DIAGONAL_CHIPS_Y]},
  {direction: "S", offset: [-CURB, -CHIPS_GAP_UNITS]},
  {direction: "W", offset: [0, WEST_CHIPS_Y]},
  {direction: "Inbound", offset: [0, CHIPS_GAP_UNITS]}
]

for (const {direction, offset} of chipsOffsetCaseList) {
  deepStrictEqual(chipsOffset({direction, gapUnits: CHIPS_GAP_UNITS}), offset, `chips offset of ${String(direction)}`)
}

const COMPASS_DIRECTION_COUNT = 8
const PAIR_LENGTH = 2
const matchCases = curbOffsetCases()
deepStrictEqual(matchCases.length, COMPASS_DIRECTION_COUNT * PAIR_LENGTH, "a curb offset pair for each compass direction")
deepStrictEqual(matchCases.slice(0, PAIR_LENGTH), ["N", ["literal", [CURB, 0]]], "the curb offset pair of north")
deepStrictEqual(
  chipsOffsetCases(CHIPS_GAP_UNITS).slice(0, PAIR_LENGTH),
  ["N", ["literal", [CURB, CHIPS_GAP_UNITS]]],
  "the chips offset pair of north"
)

// A sign's icon size grows from 0.75 at zoom 14 to 1 at zoom 16, and holds
// outside that range, as the layers' `icon-size` interpolates it.
const ZOOM_BELOW_SIGNS = 13
const ZOOM_SIGNS = 14
const ZOOM_BETWEEN = 15
const ZOOM_WHOLE = 16
const ZOOM_CLOSE = 18
const ICON_SIZE_SMALL = 0.75
const ICON_SIZE_BETWEEN = 0.875
const sizeCases = [
  {zoom: ZOOM_BELOW_SIGNS, size: ICON_SIZE_SMALL},
  {zoom: ZOOM_SIGNS, size: ICON_SIZE_SMALL},
  {zoom: ZOOM_BETWEEN, size: ICON_SIZE_BETWEEN},
  {zoom: ZOOM_WHOLE, size: 1},
  {zoom: ZOOM_CLOSE, size: 1}
]

for (const {zoom, size} of sizeCases) {
  deepStrictEqual(iconSizeAt(zoom), size, `icon size at zoom ${zoom}`)
}

// A sign's box on the screen: its center moved from the stop's point by the
// curb offset at the zoom's icon size, and half its side at that size.
const STOP_POINT = {x: 100, y: 200}
const HALF_SIGN_SMALL = 8.25
const HALF_SIGN_WHOLE = 11
const CURB_SMALL = 12
const boxCases = [
  {
    case: "a northbound stop at zoom 14",
    given: {stopPoint: STOP_POINT, direction: "N", zoom: ZOOM_SIGNS},
    box: {center: {x: STOP_POINT.x + CURB_SMALL, y: STOP_POINT.y}, halfSize: HALF_SIGN_SMALL}
  },
  {
    case: "a westbound stop at zoom 16",
    given: {stopPoint: STOP_POINT, direction: "W", zoom: ZOOM_WHOLE},
    box: {center: {x: STOP_POINT.x, y: STOP_POINT.y - CURB}, halfSize: HALF_SIGN_WHOLE}
  },
  {
    case: "a stop with no compass direction",
    given: {stopPoint: STOP_POINT, direction: "Inbound", zoom: ZOOM_WHOLE},
    box: {center: STOP_POINT, halfSize: HALF_SIGN_WHOLE}
  }
]

for (const {case: caseName, given, box} of boxCases) {
  deepStrictEqual(signBox(given), box, caseName)
}

const count = {fill: "#e2e8f0", ink: "#0f172a"}
const yellow = {name: "10", color: "#FDB71A"}
const red = {name: "C Line", color: "#9C182F"}

const chipCases = [
  {
    case: "two chips",
    chips: [yellow, red],
    shown: [
      {text: "10", fill: "#FDB71A", ink: "#0f172a"},
      {text: "C Line", fill: "#9C182F", ink: "#ffffff"}
    ]
  },
  {
    case: "six chips, four shown and a count",
    chips: [yellow, yellow, yellow, yellow, red, red],
    shown: [
      {text: "10", fill: "#FDB71A", ink: "#0f172a"},
      {text: "10", fill: "#FDB71A", ink: "#0f172a"},
      {text: "10", fill: "#FDB71A", ink: "#0f172a"},
      {text: "10", fill: "#FDB71A", ink: "#0f172a"},
      {text: "+2", fill: "#e2e8f0", ink: "#0f172a"}
    ]
  },
  {case: "no chip", chips: [], shown: []}
]

for (const {case: caseName, chips, shown} of chipCases) {
  deepStrictEqual(shownChips({chips, count}), shown, caseName)
}

const name = chipsImageName({theme: "dark", routeChips: `[["10","#FDB71A"]]`})
deepStrictEqual(name, `stop-chips:dark:[["10","#FDB71A"]]`, "a chips image's name")
deepStrictEqual(
  parseChipsImageName(name),
  {kind: ChipsImageKind.chips, theme: "dark", chips: [{name: "10", color: "#FDB71A"}]},
  "a chips image's name read back"
)
deepStrictEqual(parseChipsImageName("vehicle-marker-pointed-#fff"), {kind: ChipsImageKind.other}, "another image's name")
function parseUnknownTheme() {
  parseChipsImageName("stop-chips:dusk:[]")
}

throws(parseUnknownTheme, "a chips image of an unknown theme")

const NAME_CASE_COUNT = 4
const MATCH_CASE_COUNT = 3
const caseCount = angleCases.length + sideCases.length + curbCases.length + chipsOffsetCaseList.length + MATCH_CASE_COUNT + sizeCases.length + boxCases.length + chipCases.length + NAME_CASE_COUNT
console.log(`stop markers: ${caseCount} cases hold`)
