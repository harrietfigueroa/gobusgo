// Checks where the popups that open by themselves stand beside the panel
// sheet: the part of the map the sheet covers, on the left from the md
// breakpoint up and along the bottom on a phone, holds no popup, so no
// popup's button is in the tab order while hidden. Run it with
// `node test/scripts/popup_placement_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {coveredBoxes, placePopups} from "../../assets/js/popup_placement.js"

const VIEW = {width: 1280, height: 900}
const PHONE_VIEW = {width: 390, height: 844}
const SIZE = {width: 160, height: 32}
const TIP_LENGTH = 10
const GAP_PIXELS = 4
const SIDE_PANEL = {left: 372, bottom: 0}
const PHONE_SHEET = {left: 0, bottom: 105}
const NO_SHEET = {left: 0, bottom: 0}

function sideOf({point, insets, view}) {
  const sides = placePopups({
    popups: [{id: "stop", point, size: SIZE}],
    obstacles: coveredBoxes({insets, view}),
    view,
    tipLength: TIP_LENGTH,
    gapPixels: GAP_PIXELS
  })

  if (sides.has("stop")) {
    return sides.get("stop")
  }

  return "none"
}

const coveredCases = [
  {case: "a page with no sheet covers nothing", insets: NO_SHEET, view: VIEW, count: 0},
  {case: "the side panel covers the left", insets: SIDE_PANEL, view: VIEW, count: 1},
  {case: "the phone's sheet covers the bottom", insets: PHONE_SHEET, view: PHONE_VIEW, count: 1}
]

for (const {case: caseName, insets, view, count} of coveredCases) {
  deepStrictEqual(coveredBoxes({insets, view}).length, count, caseName)
}

const cases = [
  {case: "a stop beside the side panel opens above", point: {x: 800, y: 450}, insets: SIDE_PANEL, view: VIEW, side: "above"},
  {case: "a stop under the side panel opens no popup", point: {x: 200, y: 450}, insets: SIDE_PANEL, view: VIEW, side: "none"},
  {case: "the same stop with no sheet opens above", point: {x: 200, y: 450}, insets: NO_SHEET, view: VIEW, side: "above"},
  {case: "a stop at the panel's edge opens away from it", point: {x: 400, y: 450}, insets: SIDE_PANEL, view: VIEW, side: "right"},
  {case: "a stop under the phone's sheet opens no popup", point: {x: 195, y: 800}, insets: PHONE_SHEET, view: PHONE_VIEW, side: "none"},
  {case: "a stop just over the phone's sheet opens above", point: {x: 195, y: 720}, insets: PHONE_SHEET, view: PHONE_VIEW, side: "above"}
]

for (const {case: caseName, point, insets, view, side} of cases) {
  deepStrictEqual(sideOf({point, insets, view}), side, caseName)
}

console.log(`popup placement: ${cases.length + coveredCases.length} cases hold`)
