// Checks what the Favorites tab's list decides as pure functions of values
// written out by hand: the index a dragged entry drops at, which move
// buttons an entry offers, the text that announces a move, and the camera
// move that centers the map on a chosen favorite beside the panel sheet.
// Run it with `node test/scripts/favorite_list_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {
  EMPTY_MESSAGE,
  FAVORITE_EASE_MS,
  dropIndex,
  favoriteCamera,
  moveButtonsOf,
  moveText
} from "../../assets/js/favorite_list.js"

// The middles of three other entries, each 40 px high.
const ENTRY_HEIGHT_PIXELS = 40
const HALVING_DIVISOR = 2
const FIRST_MIDDLE_Y = ENTRY_HEIGHT_PIXELS / HALVING_DIVISOR
const SECOND_MIDDLE_Y = FIRST_MIDDLE_Y + ENTRY_HEIGHT_PIXELS
const THIRD_MIDDLE_Y = SECOND_MIDDLE_Y + ENTRY_HEIGHT_PIXELS
const BELOW_EVERY_ENTRY_Y = THIRD_MIDDLE_Y + ENTRY_HEIGHT_PIXELS
const middles = [FIRST_MIDDLE_Y, SECOND_MIDDLE_Y, THIRD_MIDDLE_Y]

const dropCases = [
  {name: "above every entry", pointerY: 0, index: 0},
  {name: "above the first middle", pointerY: FIRST_MIDDLE_Y - 1, index: 0},
  {name: "past the first middle", pointerY: FIRST_MIDDLE_Y + 1, index: 1},
  {name: "past the second middle", pointerY: SECOND_MIDDLE_Y + 1, index: 2},
  {name: "below every entry", pointerY: BELOW_EVERY_ENTRY_Y, index: 3},
  {name: "no other entry", pointerY: SECOND_MIDDLE_Y, index: 0, middles: []}
]

for (const dropCase of dropCases) {
  let caseMiddles = middles

  if (dropCase.middles !== undefined) {
    caseMiddles = dropCase.middles
  }

  const index = dropIndex({pointerY: dropCase.pointerY, middles: caseMiddles})
  deepStrictEqual(index, dropCase.index, `drop index: ${dropCase.name}`)
}

const buttonCases = [
  {name: "the only entry", index: 0, count: 1, buttons: {isUpDisabled: true, isDownDisabled: true}},
  {name: "the first of four", index: 0, count: 4, buttons: {isUpDisabled: true, isDownDisabled: false}},
  {name: "a middle one of four", index: 2, count: 4, buttons: {isUpDisabled: false, isDownDisabled: false}},
  {name: "the last of four", index: 3, count: 4, buttons: {isUpDisabled: false, isDownDisabled: true}}
]

for (const buttonCase of buttonCases) {
  const buttons = moveButtonsOf({index: buttonCase.index, count: buttonCase.count})
  deepStrictEqual(buttons, buttonCase.buttons, `move buttons: ${buttonCase.name}`)
}

deepStrictEqual(moveText({index: 1, count: 4}), "Moved to 2 of 4", "move text: second of four")
deepStrictEqual(moveText({index: 0, count: 6}), "Moved to 1 of 6", "move text: first of six")

const STOP_LONGITUDE = -122.3
const STOP_LATITUDE = 47.6
const stop = [STOP_LONGITUDE, STOP_LATITUDE]
const ZOOM_MIN = 16
const ZOOM_OUT = 12
const ZOOM_IN = 17.5
// A phone's collapsed sheet covers the bottom, and the side panel the left;
// the middle of the part each leaves is half its size away from the
// middle of the map.
const COLLAPSED_SHEET_HEIGHT_PIXELS = 120
const SIDE_PANEL_WIDTH_PIXELS = 376
const collapsedSheetOffset = [0, -COLLAPSED_SHEET_HEIGHT_PIXELS / HALVING_DIVISOR]
const sidePanelOffset = [SIDE_PANEL_WIDTH_PIXELS / HALVING_DIVISOR, 0]

const cameraCases = [
  {
    name: "a phone's collapsed sheet, zoomed out",
    zoom: ZOOM_OUT,
    insets: {left: 0, bottom: COLLAPSED_SHEET_HEIGHT_PIXELS},
    reducedMotion: false,
    camera: {center: stop, zoom: ZOOM_MIN, offset: collapsedSheetOffset, duration: FAVORITE_EASE_MS}
  },
  {
    name: "the side panel, zoomed in past the bound",
    zoom: ZOOM_IN,
    insets: {left: SIDE_PANEL_WIDTH_PIXELS, bottom: 0},
    reducedMotion: false,
    camera: {center: stop, zoom: ZOOM_IN, offset: sidePanelOffset, duration: FAVORITE_EASE_MS}
  },
  {
    name: "reduced motion",
    zoom: ZOOM_OUT,
    insets: {left: SIDE_PANEL_WIDTH_PIXELS, bottom: 0},
    reducedMotion: true,
    camera: {center: stop, zoom: ZOOM_MIN, offset: sidePanelOffset, duration: 0}
  }
]

for (const cameraCase of cameraCases) {
  const camera = favoriteCamera({
    lngLat: stop,
    zoom: cameraCase.zoom,
    zoomMin: ZOOM_MIN,
    insets: cameraCase.insets,
    reducedMotion: cameraCase.reducedMotion
  })

  deepStrictEqual(camera, cameraCase.camera, `camera: ${cameraCase.name}`)
}

deepStrictEqual(EMPTY_MESSAGE, {headline: "No favorites yet", caption: "Open a stop and tap ☆ to keep it here."}, "the empty list's message")

console.log("favorite list check passed")
