// Checks where the canvas over the map draws the vehicles it is handed: which
// vehicles a canvas shows, which one a click opens, which stand inside a
// box, where a badge stands, which way a pointed marker turns on a turned
// map, and which route labels are drawn among crowded vehicles, with the
// inputs each function refuses. Each case runs one pure function over
// points written here. Run it with `node test/scripts/vehicle_overlay_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {
  badgeCorner,
  drawnVehicles,
  HIT_RADIUS_PIXELS,
  HitKind,
  MarkerKind,
  nearestVehicle,
  placedLabels,
  screenAngleRadians,
  VEHICLE_COUNT_MAX,
  vehiclesInBox
} from "../../assets/js/vehicle_overlay_layout.js"

const WIDTH = 390
const HEIGHT = 844
const LABEL_WIDTH = 14
const WIDE_LABEL_WIDTH = 40
const HALVING_DIVISOR = 2
const QUARTER_TURN = Math.PI / HALVING_DIVISOR
// Past the margin a canvas draws outside its edges.
const OFF_CANVAS_PIXELS = 60
const BOX_NEAR = 90
const BOX_FAR = 150
const INSIDE_OUT_EDGE = 10
const ROUND_REACH_PIXELS = 7.5
// A pointed image of 28 px turned an eighth of a turn reaches 14 √2 px, and
// its icon's padding 2 px more.
const TURNED_REACH_PIXELS = 21.7
const EIGHTHS_PER_TURN_HALVED = 4
// Between the round vehicles above and the pointed one below.
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
  {case: "a vehicle whose label reaches into the canvas is drawn", vehicle: vehicleAt({id: "a", x: -40, y: 100}), drawn: ["a"]},
  {case: "a vehicle far left of the canvas is not drawn", vehicle: vehicleAt({id: "a", x: -OFF_CANVAS_PIXELS, y: 100}), drawn: []},
  {case: "a vehicle far below the canvas is not drawn", vehicle: vehicleAt({id: "a", x: 100, y: HEIGHT + OFF_CANVAS_PIXELS}), drawn: []}
]

for (const {case: caseName, vehicle, drawn} of drawnCases) {
  const result = drawnVehicles({vehicles: [vehicle], width: WIDTH, height: HEIGHT})
  deepStrictEqual(ids(result), drawn, caseName)
}

const crowd = [vehicleAt({id: "a", x: 100, y: 100}), vehicleAt({id: "b", x: 108, y: 100}), vehicleAt({id: "c", x: 200, y: 200})]
// A pointed vehicle turned an eighth of a turn, below the round ones.
const turned = {id: "d", x: 200, y: 600, marker: {kind: MarkerKind.pointed, angleRadians: Math.PI / EIGHTHS_PER_TURN_HALVED}}
const boxed = [...crowd, turned]

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
  {case: "a box holds a pointed vehicle turned an eighth whose image reaches into it", box: [[200 + TURNED_REACH_PIXELS, MIDDLE], [WIDTH, HEIGHT]], inside: ["d"]},
  {case: "a box holds no pointed vehicle beyond its turned image", box: [[200 + TURNED_REACH_PIXELS + 1, MIDDLE], [WIDTH, HEIGHT]], inside: []},
  {case: "a box beside the panel holds none left of it", box: [[BOX_FAR, 0], [WIDTH, HEIGHT]], inside: ["c", "d"]}
]

for (const {case: caseName, box, inside} of boxCases) {
  const result = vehiclesInBox({drawn: boxed, box})
  deepStrictEqual(ids(result), inside, caseName)
}

deepStrictEqual(badgeCorner({x: 100, y: 100}), {x: 104, y: 82}, "a badge's lower left corner stands 4 px right of and above the center")

const angleCases = [
  {case: "a heading north on a north-up map points up", headingDegrees: 0, bearingDegrees: 0, angle: 0},
  {case: "a heading east on a north-up map points right", headingDegrees: 90, bearingDegrees: 0, angle: QUARTER_TURN},
  {case: "a heading east on a map turned to face east points up", headingDegrees: 90, bearingDegrees: 90, angle: 0},
  {case: "a heading north on a map turned to face east points left", headingDegrees: 0, bearingDegrees: 90, angle: -QUARTER_TURN}
]

for (const {case: caseName, headingDegrees, bearingDegrees, angle} of angleCases) {
  deepStrictEqual(screenAngleRadians({headingDegrees, bearingDegrees}), angle, caseName)
}

function labeled({id, x, y, hasBadge}) {
  return {id, x, y, labelWidth: LABEL_WIDTH, hasBadge}
}

function wideLabeled({id, x, y}) {
  return {id, x, y, labelWidth: WIDE_LABEL_WIDTH, hasBadge: false}
}

const labelCases = [
  {
    case: "a lone vehicle's label is drawn under its own marker",
    vehicles: [labeled({id: "a", x: 100, y: 100, hasBadge: true})],
    placed: ["a"]
  },
  {
    case: "of two labels that would cross, the first given is drawn",
    vehicles: [wideLabeled({id: "a", x: 100, y: 100}), wideLabeled({id: "b", x: 135, y: 100})],
    placed: ["a"]
  },
  {
    case: "a label that would cover another vehicle's marker is left out",
    vehicles: [labeled({id: "a", x: 100, y: 100, hasBadge: false}), labeled({id: "b", x: 100, y: 125, hasBadge: false})],
    placed: ["b"]
  },
  {
    case: "a label that would cover another vehicle's badge is left out",
    vehicles: [labeled({id: "a", x: 100, y: 100, hasBadge: false}), labeled({id: "b", x: 85, y: 140, hasBadge: true})],
    placed: ["b"]
  },
  {
    case: "labels apart are both drawn",
    vehicles: [labeled({id: "a", x: 100, y: 100, hasBadge: true}), labeled({id: "b", x: 200, y: 100, hasBadge: true})],
    placed: ["a", "b"]
  },
  {
    case: "a vehicle with no route has no label and blocks with its marker alone",
    vehicles: [{id: "a", x: 100, y: 100, labelWidth: null, hasBadge: false}, labeled({id: "b", x: 100, y: 80, hasBadge: false})],
    placed: []
  }
]

for (const {case: caseName, vehicles, placed} of labelCases) {
  deepStrictEqual([...placedLabels(vehicles)], placed, caseName)
}

function vehicleAtOrigin(_, index) {
  return vehicleAt({id: String(index), x: 0, y: 0})
}

const tooMany = Array.from({length: VEHICLE_COUNT_MAX + 1}, vehicleAtOrigin)

const refusedCases = [
  {case: "more vehicles than the canvas takes are refused", run: () => drawnVehicles({vehicles: tooMany, width: WIDTH, height: HEIGHT})},
  {case: "a vehicle at no point is refused", run: () => drawnVehicles({vehicles: [vehicleAt({id: "a", x: Number.NaN, y: 0})], width: WIDTH, height: HEIGHT})},
  {case: "a negative width is refused", run: () => drawnVehicles({vehicles: [], width: -1, height: HEIGHT})},
  {case: "a click at no point is refused", run: () => nearestVehicle({drawn: crowd, point: {x: Number.NaN, y: 0}})},
  {case: "a box turned inside out is refused", run: () => vehiclesInBox({drawn: crowd, box: [[INSIDE_OUT_EDGE, 0], [0, INSIDE_OUT_EDGE]]})},
  {case: "a heading that is no number is refused", run: () => screenAngleRadians({headingDegrees: Number.NaN, bearingDegrees: 0})},
  {case: "a negative label width is refused", run: () => placedLabels([{id: "a", x: 0, y: 0, labelWidth: -1, hasBadge: false}])}
]

for (const {case: caseName, run} of refusedCases) {
  throws(run, AssertionError, caseName)
}

console.log("vehicle overlay: every case passed")
