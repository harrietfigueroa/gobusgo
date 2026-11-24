// Checks what a tap on the vehicle map does, as pure functions of values
// written out by hand: a tap on no item while the view shows one deselects
// it, and any other tap leaves the view to the item's own listener; and the
// stop signs near a tap open nothing unless the map draws one under the
// tap, and then one stop or a list of every sign within reach, nearest
// first by the distance from the tap to each sign's box, a sign drawn under
// the tap at the tap and before another as near, with the count of all
// reached. Run it with `node test/scripts/map_selection_check.mjs`; it
// exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {StopTapKind, TapOutcome, stopTapOutcome, tapOutcome} from "../../assets/js/map_selection.js"

const cases = [
  {name: "a tap on the empty map while an item is shown", given: {isItemHit: false, isShowing: true}, outcome: TapOutcome.deselect},
  {name: "a tap on the empty map while nothing is shown", given: {isItemHit: false, isShowing: false}, outcome: TapOutcome.none},
  {name: "a tap on an item while another is shown", given: {isItemHit: true, isShowing: true}, outcome: TapOutcome.none},
  {name: "a tap on an item while nothing is shown", given: {isItemHit: true, isShowing: false}, outcome: TapOutcome.none}
]

for (const {name, given, outcome} of cases) {
  deepStrictEqual(tapOutcome(given), outcome, name)
}

// Every sign is a square of half side 8 around its center; the tap is at
// (100, 100). A sign's distance is from the tap to the nearest point of its
// square, 0 inside it, and 0 for a sign the map draws under the tap.
const TAP = {x: 100, y: 100}
const HALF_SIZE = 8
const TOUCH_RADIUS = 22
const POINTER_RADIUS = 0
const COUNT_MAX = 12
const AT_EDGE_X = 130
const NEAR_X = 110
const FAR_X_IN_REACH = 125
const BESIDE_X = 120
const PAST_EDGE_X = 131
const TOUCHING_X = 112
const OVERLAPPING_X = 105
const FAR_X = 200

function sign({id, x, isUnderTap}) {
  return {id, item: id, center: {x, y: TAP.y}, halfSize: HALF_SIZE, isUnderTap}
}

// Fourteen signs in a column through the tap, each 1 px lower than the
// last, so each is 1 px farther than the one before it.
const COLUMN_COUNT = 14
const ID_DIGIT_COUNT = 2
const column = []

for (let index = 0; index < COLUMN_COUNT; index += 1) {
  const id = `stop-${String(index).padStart(ID_DIGIT_COUNT, "0")}`
  const center = {x: TAP.x, y: TAP.y + HALF_SIZE + index}
  column.push({id, item: id, center, halfSize: HALF_SIZE, isUnderTap: index === 0})
}

const columnNearest = []

for (const candidate of column.slice(0, COUNT_MAX)) {
  columnNearest.push(candidate.item)
}

const stopCases = [
  {name: "no sign near", candidates: [], radiusPixels: TOUCH_RADIUS, outcome: {kind: StopTapKind.none}},
  {
    name: "every sign beyond the radius",
    candidates: [sign({id: "a", x: FAR_X, isUnderTap: false})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.none}
  },
  {
    name: "one sign under the tap",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.one, item: "a"}
  },
  {
    name: "a sign the map draws under the tap outside its box",
    candidates: [sign({id: "a", x: FAR_X, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.one, item: "a"}
  },
  {
    name: "a tap inside a sign's box where the map draws no sign",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: false})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.none}
  },
  {
    name: "a sign drawn under the tap outside its box first, beside another within the radius",
    candidates: [sign({id: "near", x: NEAR_X, isUnderTap: false}), sign({id: "drawn", x: FAR_X, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.list, items: ["drawn", "near"], count: 2}
  },
  {
    name: "a tap near two signs touching neither",
    candidates: [sign({id: "far", x: AT_EDGE_X, isUnderTap: false}), sign({id: "near", x: NEAR_X, isUnderTap: false})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.none}
  },
  {
    name: "a sign drawn under the tap before another whose box holds the tap",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: false}), sign({id: "b", x: OVERLAPPING_X, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.list, items: ["b", "a"], count: 2}
  },
  {
    name: "a tap on one sign with another within the radius",
    candidates: [sign({id: "far", x: FAR_X_IN_REACH, isUnderTap: false}), sign({id: "near", x: TAP.x, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.list, items: ["near", "far"], count: 2}
  },
  {
    name: "a tap on one sign alone",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: true}), sign({id: "b", x: FAR_X, isUnderTap: false})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.one, item: "a"}
  },
  {
    name: "a tap on one sign with another at the radius, nearest first",
    candidates: [sign({id: "far", x: AT_EDGE_X, isUnderTap: false}), sign({id: "near", x: OVERLAPPING_X, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.list, items: ["near", "far"], count: 2}
  },
  {
    name: "a sign 1 px past the radius",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: true}), sign({id: "b", x: PAST_EDGE_X, isUnderTap: false})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.one, item: "a"}
  },
  {
    name: "one stop from two tiles",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: true}), sign({id: "a", x: TAP.x, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.one, item: "a"}
  },
  {
    name: "two signs at one distance, by identifier",
    candidates: [sign({id: "b", x: TAP.x, isUnderTap: true}), sign({id: "a", x: TAP.x, isUnderTap: true})],
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.list, items: ["a", "b"], count: 2}
  },
  {
    name: "a pointer on one sign beside another",
    candidates: [sign({id: "a", x: TAP.x, isUnderTap: true}), sign({id: "b", x: TOUCHING_X, isUnderTap: false})],
    radiusPixels: POINTER_RADIUS,
    outcome: {kind: StopTapKind.one, item: "a"}
  },
  {
    name: "a pointer on two overlapping signs",
    candidates: [
      sign({id: "a", x: TAP.x, isUnderTap: true}),
      sign({id: "b", x: OVERLAPPING_X, isUnderTap: true}),
      sign({id: "c", x: BESIDE_X, isUnderTap: false})
    ],
    radiusPixels: POINTER_RADIUS,
    outcome: {kind: StopTapKind.list, items: ["a", "b"], count: 2}
  },
  {
    name: "more signs than the list holds, counted whole",
    candidates: column.toReversed(),
    radiusPixels: TOUCH_RADIUS,
    outcome: {kind: StopTapKind.list, items: columnNearest, count: COLUMN_COUNT}
  }
]

for (const {name, candidates, radiusPixels, outcome} of stopCases) {
  deepStrictEqual(stopTapOutcome({candidates, point: TAP, radiusPixels, countMax: COUNT_MAX}), outcome, name)
}

function negativeRadius() {
  stopTapOutcome({candidates: [], point: TAP, radiusPixels: -1, countMax: COUNT_MAX})
}

function listOfOne() {
  stopTapOutcome({candidates: [], point: TAP, radiusPixels: TOUCH_RADIUS, countMax: 1})
}

throws(negativeRadius, "a negative radius")
throws(listOfOne, "a list that holds one stop")

const REFUSAL_COUNT = 2
console.log(`map selection: ${cases.length + stopCases.length + REFUSAL_COUNT} cases hold`)
