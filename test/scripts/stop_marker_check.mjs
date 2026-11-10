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
  ChipsSide,
  chipsImageName,
  chipsSide,
  directionAngle,
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
console.log(`stop markers: ${angleCases.length + sideCases.length + chipCases.length + NAME_CASE_COUNT} cases hold`)
