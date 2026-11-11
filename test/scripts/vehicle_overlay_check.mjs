// Checks where the canvas over the map draws the vehicles it is handed: which
// vehicles a canvas shows, which one a click opens, which stand inside a
// box, where a dot's status badge and a glyph's route badge and chevron
// stand, which way a chevron turns on a turned map, and which route badges
// are drawn among crowded vehicles, with the inputs each function refuses.
// Each case runs one pure function over
// points written here. Run it with `node test/scripts/vehicle_overlay_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {
  badgeCorner,
  chevronCenter,
  drawnVehicles,
  HIT_RADIUS_PIXELS,
  HitKind,
  MarkerKind,
  nearestVehicle,
  placedBadges,
  routeBadgeCorner,
  screenAngleRadians,
  VEHICLE_COUNT_MAX,
  vehiclesInBox,
  YourBusSide,
  yourBusPlacement
} from "../../assets/js/vehicle_overlay_layout.js"

const WIDTH = 390
const HEIGHT = 844
const BADGE_WIDTH = 14
const WIDE_BADGE_WIDTH = 40
const HALVING_DIVISOR = 2
const QUARTER_TURN = Math.PI / HALVING_DIVISOR
// Past the margin a canvas draws outside its edges.
const OFF_CANVAS_PIXELS = 60
const BOX_NEAR = 90
const BOX_FAR = 150
const INSIDE_OUT_EDGE = 10
const ROUND_REACH_PIXELS = 7.5
// A glyph's image of 26 px reaches 13 px, and its icon's padding 2 px more.
const GLYPH_REACH_PIXELS = 15
// Between the round vehicles above and the glyph below.
const MIDDLE = 400

function idOf(vehicle) {
  return vehicle.id
}

function ids(vehicles) {
  return Array.from(vehicles, idOf)
}

function vehicleAt({id, x, y}) {
  return {id, x, y, marker: {kind: MarkerKind.round}}
}

const drawnCases = [
  {case: "a vehicle inside the canvas is drawn", vehicle: vehicleAt({id: "a", x: 100, y: 100}), drawn: ["a"]},
  {case: "a vehicle whose badge reaches into the canvas is drawn", vehicle: vehicleAt({id: "a", x: -40, y: 100}), drawn: ["a"]},
  {case: "a vehicle far left of the canvas is not drawn", vehicle: vehicleAt({id: "a", x: -OFF_CANVAS_PIXELS, y: 100}), drawn: []},
  {case: "a vehicle far below the canvas is not drawn", vehicle: vehicleAt({id: "a", x: 100, y: HEIGHT + OFF_CANVAS_PIXELS}), drawn: []}
]

for (const {case: caseName, vehicle, drawn} of drawnCases) {
  const result = drawnVehicles({vehicles: [vehicle], width: WIDTH, height: HEIGHT})
  deepStrictEqual(ids(result), drawn, caseName)
}

const crowd = [vehicleAt({id: "a", x: 100, y: 100}), vehicleAt({id: "b", x: 108, y: 100}), vehicleAt({id: "c", x: 200, y: 200})]
// A glyph, below the round ones.
const glyph = {id: "d", x: 200, y: 600, marker: {kind: MarkerKind.glyph}}
const boxed = [...crowd, glyph]

const hitCases = [
  {case: "a click on a marker opens it", point: {x: 200, y: 200}, hit: "c"},
  {case: "a click at the reach's edge opens the marker", point: {x: 200 + HIT_RADIUS_PIXELS, y: 200}, hit: "c"},
  {case: "a click past the reach opens nothing", point: {x: 200 + HIT_RADIUS_PIXELS + 1, y: 200}, hit: null},
  {case: "a click between two markers opens the nearer", point: {x: 106, y: 100}, hit: "b"},
  {case: "a click as near two markers opens the first given", point: {x: 104, y: 100}, hit: "a"}
]

for (const {case: caseName, point, hit} of hitCases) {
  const result = nearestVehicle({drawn: crowd, point})

  if (hit === null) {
    deepStrictEqual(result, {kind: HitKind.missing}, caseName)
  } else {
    deepStrictEqual(result.kind, HitKind.found, caseName)
    deepStrictEqual(result.vehicle.id, hit, caseName)
  }
}

const boxCases = [
  {case: "a box holds the vehicles inside it", box: [[BOX_NEAR, BOX_NEAR], [BOX_FAR, BOX_FAR]], inside: ["a", "b"]},
  {case: "a box's edge holds a vehicle on it", box: [[200, 200], [300, 300]], inside: ["c"]},
  {case: "a box holds a round vehicle whose outline reaches into it", box: [[200 + ROUND_REACH_PIXELS, 0], [WIDTH, MIDDLE]], inside: ["c"]},
  {case: "a box holds no round vehicle beyond its outline", box: [[200 + ROUND_REACH_PIXELS + 1, 0], [WIDTH, MIDDLE]], inside: []},
  {case: "a box holds a glyph whose image reaches into it", box: [[200 + GLYPH_REACH_PIXELS, MIDDLE], [WIDTH, HEIGHT]], inside: ["d"]},
  {case: "a box holds no glyph beyond its image", box: [[200 + GLYPH_REACH_PIXELS + 1, MIDDLE], [WIDTH, HEIGHT]], inside: []},
  {case: "a box beside the panel holds none left of it", box: [[BOX_FAR, 0], [WIDTH, HEIGHT]], inside: ["c", "d"]}
]

for (const {case: caseName, box, inside} of boxCases) {
  const result = vehiclesInBox({drawn: boxed, box})
  deepStrictEqual(ids(result), inside, caseName)
}

deepStrictEqual(badgeCorner({x: 100, y: 100}), {x: 104, y: 82}, "a badge's lower left corner stands 4 px right of and above the center")
deepStrictEqual(routeBadgeCorner({x: 100, y: 100}), {x: 106, y: 79}, "a route badge's lower left corner stands 6 px right of and above the glyph's center")
deepStrictEqual(chevronCenter({x: 100, y: 100, angleRadians: 0}), {x: 100, y: 81}, "a chevron heading up stands 19 px above the glyph's center")
deepStrictEqual(chevronCenter({x: 100, y: 100, angleRadians: QUARTER_TURN}), {x: 119, y: 100}, "a chevron heading right stands 19 px right of it")

const angleCases = [
  {case: "a heading north on a north-up map points up", headingDegrees: 0, bearingDegrees: 0, angle: 0},
  {case: "a heading east on a north-up map points right", headingDegrees: 90, bearingDegrees: 0, angle: QUARTER_TURN},
  {case: "a heading east on a map turned to face east points up", headingDegrees: 90, bearingDegrees: 90, angle: 0},
  {case: "a heading north on a map turned to face east points left", headingDegrees: 0, bearingDegrees: 90, angle: -QUARTER_TURN}
]

for (const {case: caseName, headingDegrees, bearingDegrees, angle} of angleCases) {
  deepStrictEqual(screenAngleRadians({headingDegrees, bearingDegrees}), angle, caseName)
}

function badged({id, x, y}) {
  return {id, x, y, badgeWidth: BADGE_WIDTH}
}

function wideBadged({id, x, y}) {
  return {id, x, y, badgeWidth: WIDE_BADGE_WIDTH}
}

const badgeCases = [
  {
    case: "a lone vehicle's badge is drawn on its own glyph",
    vehicles: [badged({id: "a", x: 100, y: 100})],
    placed: ["a"]
  },
  {
    case: "of two badges that would cross, the first given is drawn",
    vehicles: [wideBadged({id: "a", x: 100, y: 100}), wideBadged({id: "b", x: 80, y: 85})],
    placed: ["a"]
  },
  {
    case: "a badge that would cover another vehicle's glyph is left out",
    vehicles: [badged({id: "a", x: 100, y: 100}), badged({id: "b", x: 115, y: 85})],
    placed: ["b"]
  },
  {
    case: "badges apart are both drawn",
    vehicles: [badged({id: "a", x: 100, y: 100}), badged({id: "b", x: 200, y: 100})],
    placed: ["a", "b"]
  },
  {
    case: "a vehicle with no badge blocks with its glyph alone",
    vehicles: [{id: "a", x: 115, y: 85, badgeWidth: null}, badged({id: "b", x: 100, y: 100})],
    placed: []
  }
]

for (const {case: caseName, vehicles, placed} of badgeCases) {
  deepStrictEqual([...placedBadges(vehicles)], placed, caseName)
}

function vehicleAtOrigin(_, index) {
  return vehicleAt({id: String(index), x: 0, y: 0})
}

const tooMany = Array.from({length: VEHICLE_COUNT_MAX + 1}, vehicleAtOrigin)

const LABEL_WIDTH = 130
const GLYPH_LABEL_OFFSET = 17
const ROUND_LABEL_OFFSET = 12
const NEAR_RIGHT_EDGE = 300
const NEAR_LEFT_EDGE = 20
const LABEL_AT = 150

// The first bus's label stands to the right of its marker, past the
// marker's edge, level with its center; a dot is smaller, so its label
// stands nearer.
deepStrictEqual(yourBusPlacement({x: LABEL_AT, y: LABEL_AT, kind: MarkerKind.glyph, textWidth: LABEL_WIDTH, width: WIDTH}), {side: YourBusSide.right, textX: LABEL_AT + GLYPH_LABEL_OFFSET, textY: LABEL_AT})
deepStrictEqual(yourBusPlacement({x: LABEL_AT, y: LABEL_AT, kind: MarkerKind.round, textWidth: LABEL_WIDTH, width: WIDTH}), {side: YourBusSide.right, textX: LABEL_AT + ROUND_LABEL_OFFSET, textY: LABEL_AT})

// Where the right side would leave the canvas, the label stands to the left.
deepStrictEqual(yourBusPlacement({x: NEAR_RIGHT_EDGE, y: LABEL_AT, kind: MarkerKind.glyph, textWidth: LABEL_WIDTH, width: WIDTH}), {side: YourBusSide.left, textX: NEAR_RIGHT_EDGE - GLYPH_LABEL_OFFSET, textY: LABEL_AT})

// Where neither side fits, it stands to the right and the canvas clips it.
deepStrictEqual(yourBusPlacement({x: NEAR_LEFT_EDGE, y: LABEL_AT, kind: MarkerKind.glyph, textWidth: WIDTH, width: WIDTH}).side, YourBusSide.right)

const refusedCases = [
  {case: "more vehicles than the canvas takes are refused", run: () => drawnVehicles({vehicles: tooMany, width: WIDTH, height: HEIGHT})},
  {case: "a vehicle at no point is refused", run: () => drawnVehicles({vehicles: [vehicleAt({id: "a", x: Number.NaN, y: 0})], width: WIDTH, height: HEIGHT})},
  {case: "a negative width is refused", run: () => drawnVehicles({vehicles: [], width: -1, height: HEIGHT})},
  {case: "a click at no point is refused", run: () => nearestVehicle({drawn: crowd, point: {x: Number.NaN, y: 0}})},
  {case: "a box turned inside out is refused", run: () => vehiclesInBox({drawn: crowd, box: [[INSIDE_OUT_EDGE, 0], [0, INSIDE_OUT_EDGE]]})},
  {case: "a heading that is no number is refused", run: () => screenAngleRadians({headingDegrees: Number.NaN, bearingDegrees: 0})},
  {case: "a negative badge width is refused", run: () => placedBadges([{id: "a", x: 0, y: 0, badgeWidth: -1}])}
]

for (const {case: caseName, run} of refusedCases) {
  throws(run, AssertionError, caseName)
}

console.log("vehicle overlay: every case passed")
