// Checks what the vehicle map tells a screen reader about its view as pure
// functions of values written out by hand: the part of the map beside the
// panel sheet, the stop nearest its middle, the sentence of what is in view,
// and when that sentence is announced. Run it with
// `node test/scripts/map_view_text_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  ANNOUNCEMENT_GAP_MS,
  AnnouncerEffectKind,
  announcerStep,
  initialAnnouncer,
  MoveEventKind,
  nearestPlace,
  PlaceKind,
  viewBox,
  viewSentence
} from "../../assets/js/map_view_text.js"

const openMap = {width: 800, height: 600, insets: {left: 0, bottom: 0}}
const openMapCorner = {x: 800, y: 600}
const openMapBox = {box: [[0, 0], [openMapCorner.x, openMapCorner.y]], center: {x: 400, y: 300}}
const phoneMap = {width: 390, height: 844, insets: {left: 0, bottom: 144}}
const phoneMapCorner = {x: 390, y: 700}
const phoneMapBox = {box: [[0, 0], [phoneMapCorner.x, phoneMapCorner.y]], center: {x: 195, y: 350}}
const desktopMap = {width: 1280, height: 800, insets: {left: 372, bottom: 0}}
const desktopMapCorners = {left: 372, right: 1280, bottom: 800}
const desktopMapBox = {
  box: [[desktopMapCorners.left, 0], [desktopMapCorners.right, desktopMapCorners.bottom]],
  center: {x: 826, y: 400}
}
const coveredMap = {width: 390, height: 844, insets: {left: 0, bottom: 900}}

const boxCases = [
  {name: "a map no sheet covers", view: openMap, expected: openMapBox},
  {name: "a phone's map under a collapsed sheet", view: phoneMap, expected: phoneMapBox},
  {name: "a desktop's map beside the side panel", view: desktopMap, expected: desktopMapBox}
]

for (const {name, view, expected} of boxCases) {
  deepStrictEqual(viewBox(view), expected, name)
}

function coveredViewBox() {
  return viewBox(coveredMap)
}

throws(coveredViewBox, "a sheet taller than the map")

const center = {x: 100, y: 100}

const placeCases = [
  {name: "no place", places: [], expected: {kind: PlaceKind.missing}},
  {
    name: "the one place",
    places: [{name: "Pine St & 3rd Ave", x: 300, y: 40}],
    expected: {kind: PlaceKind.found, name: "Pine St & 3rd Ave"}
  },
  {
    name: "the nearer of two",
    places: [{name: "Far", x: 180, y: 100}, {name: "Near", x: 90, y: 110}],
    expected: {kind: PlaceKind.found, name: "Near"}
  },
  {
    name: "the first of two as near",
    places: [{name: "West", x: 90, y: 100}, {name: "East", x: 110, y: 100}],
    expected: {kind: PlaceKind.found, name: "West"}
  }
]

for (const {name, places, expected} of placeCases) {
  deepStrictEqual(nearestPlace({places, center}), expected, name)
}

const near = {kind: PlaceKind.found, name: "Pine St & 3rd Ave"}
const nowhere = {kind: PlaceKind.missing}

const sentenceCases = [
  {
    name: "vehicles and stops near a stop",
    view: {vehicleCount: 12, stopCount: 30, stopsDrawn: true, nearest: near},
    expected: "In view: 12 vehicles and 30 stops, centered near Pine St & 3rd Ave."
  },
  {
    name: "one vehicle and one stop",
    view: {vehicleCount: 1, stopCount: 1, stopsDrawn: true, nearest: near},
    expected: "In view: 1 vehicle and 1 stop, centered near Pine St & 3rd Ave."
  },
  {
    name: "no vehicle and no stop",
    view: {vehicleCount: 0, stopCount: 0, stopsDrawn: true, nearest: nowhere},
    expected: "In view: no vehicles and no stops."
  },
  {
    name: "stops whose names are not supplied",
    view: {vehicleCount: 3, stopCount: 2, stopsDrawn: true, nearest: nowhere},
    expected: "In view: 3 vehicles and 2 stops."
  },
  {
    name: "a zoom that draws no stops",
    view: {vehicleCount: 240, stopCount: 0, stopsDrawn: false, nearest: nowhere},
    expected: "In view: 240 vehicles. Zoom in to show the stops."
  }
]

for (const {name, view, expected} of sentenceCases) {
  deepStrictEqual(viewSentence(view), expected, name)
}

const negativeCount = {vehicleCount: -1, stopCount: 0, stopsDrawn: true, nearest: nowhere}
const fractionalCount = {vehicleCount: 1.5, stopCount: 0, stopsDrawn: true, nearest: nowhere}
const hiddenStopsCounted = {vehicleCount: 1, stopCount: 2, stopsDrawn: false, nearest: nowhere}

const refusedViews = [
  {name: "a negative count", view: negativeCount},
  {name: "a fractional count", view: fractionalCount},
  {name: "stops counted at a zoom that draws none", view: hiddenStopsCounted}
]

for (const {name, view} of refusedViews) {
  throws(function refusedSentence() { return viewSentence(view) }, name)
}

// Each case runs its events from the first state and compares the effect of
// the last one. The times are milliseconds on the page's clock.
const FIRST_REST_MS = 1_000
const EARLY_REST_MS = 2_500
const LATE_REST_MS = 9_000
const GAP_REST_MS = FIRST_REST_MS + ANNOUNCEMENT_GAP_MS
const EARLY_WAIT_MS = ANNOUNCEMENT_GAP_MS - (EARLY_REST_MS - FIRST_REST_MS)
const TEXT = "In view: 12 vehicles and 30 stops."
const OTHER_TEXT = "In view: 3 vehicles and 2 stops."
const started = {kind: MoveEventKind.started}
const riderEnded = {kind: MoveEventKind.ended, announced: true}
const pageEnded = {kind: MoveEventKind.ended, announced: false}

function rested({nowMs, text}) {
  return {kind: MoveEventKind.rested, nowMs, text}
}

const none = {kind: AnnouncerEffectKind.none}

function announce(text) {
  return {kind: AnnouncerEffectKind.announce, text}
}

const announcerCases = [
  {name: "a rest after the rider's move", events: [started, riderEnded, rested({nowMs: FIRST_REST_MS, text: TEXT})], expected: announce(TEXT)},
  {name: "a rest after the page's move", events: [started, pageEnded, rested({nowMs: FIRST_REST_MS, text: TEXT})], expected: none},
  {name: "a rest with no move, after a fetch", events: [rested({nowMs: FIRST_REST_MS, text: TEXT})], expected: none},
  {name: "a rest during a move", events: [started, riderEnded, started, rested({nowMs: FIRST_REST_MS, text: TEXT})], expected: none},
  {
    name: "a rest after the rider's move and then the page's",
    events: [started, riderEnded, started, pageEnded, rested({nowMs: FIRST_REST_MS, text: TEXT})],
    expected: announce(TEXT)
  },
  {
    name: "a second rest after one announcement",
    events: [started, riderEnded, rested({nowMs: FIRST_REST_MS, text: TEXT}), rested({nowMs: LATE_REST_MS, text: OTHER_TEXT})],
    expected: none
  },
  {
    name: "the same text twice in a row",
    events: [started, riderEnded, rested({nowMs: FIRST_REST_MS, text: TEXT}), started, riderEnded, rested({nowMs: LATE_REST_MS, text: TEXT})],
    expected: none
  },
  {
    name: "another text inside the gap",
    events: [started, riderEnded, rested({nowMs: FIRST_REST_MS, text: TEXT}), started, riderEnded, rested({nowMs: EARLY_REST_MS, text: OTHER_TEXT})],
    expected: {kind: AnnouncerEffectKind.wait, ms: EARLY_WAIT_MS}
  },
  {
    name: "another text once the gap has passed",
    events: [
      started,
      riderEnded,
      rested({nowMs: FIRST_REST_MS, text: TEXT}),
      started,
      riderEnded,
      rested({nowMs: EARLY_REST_MS, text: OTHER_TEXT}),
      rested({nowMs: GAP_REST_MS, text: OTHER_TEXT})
    ],
    expected: announce(OTHER_TEXT)
  }
]

for (const {name, events, expected} of announcerCases) {
  let state = initialAnnouncer
  let effect = none

  for (const event of events) {
    const step = announcerStep({state, event})
    state = step.state
    effect = step.effect
  }

  deepStrictEqual(effect, expected, name)
}

const caseCount = boxCases.length + placeCases.length + sentenceCases.length + announcerCases.length
console.log(`map view text check passed: ${caseCount} cases`)
