// Checks which vehicles dim while a route's line is emphasized, as pure
// functions of values written out by hand: nothing dims without an emphasized
// route, only the vehicles of other routes dim, a vehicle with no route
// dims, and the paint expression keeps a status's own opacity under the
// dimming. Run it with `node test/scripts/route_emphasis_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  VEHICLE_DIM_FACTOR,
  dimmedOpacity,
  emphasizedRouteOf,
  markerAlpha
} from "../../assets/js/route_emphasis.js"

const alphaCases = [
  {name: "no route emphasized", given: {emphasizedRouteId: null, routeId: "1_40"}, alpha: 1},
  {name: "the emphasized route's vehicle", given: {emphasizedRouteId: "1_40", routeId: "1_40"}, alpha: 1},
  {name: "another route's vehicle", given: {emphasizedRouteId: "1_40", routeId: "1_41"}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a vehicle with no route", given: {emphasizedRouteId: "1_40", routeId: null}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a vehicle with no route field", given: {emphasizedRouteId: "1_40", routeId: undefined}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a route whose id differs only in case", given: {emphasizedRouteId: "1_40a", routeId: "1_40A"}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a vehicle with no route and no emphasis", given: {emphasizedRouteId: null, routeId: null}, alpha: 1}
]

for (const {name, given, alpha} of alphaCases) {
  deepStrictEqual(markerAlpha(given), alpha, name)
}

const statusOpacity = ["match", ["get", "status"], "live", 1, "stale", 0.6, 1]

const expressionCases = [
  {name: "a number with no emphasis", given: {emphasizedRouteId: null, opacity: 1}, expected: 1},
  {name: "an expression with no emphasis", given: {emphasizedRouteId: null, opacity: statusOpacity}, expected: statusOpacity},
  {
    name: "a number under emphasis",
    given: {emphasizedRouteId: "1_40", opacity: 1},
    expected: ["case", ["==", ["get", "routeId"], "1_40"], 1, ["*", 1, VEHICLE_DIM_FACTOR]]
  },
  {
    name: "an expression under emphasis",
    given: {emphasizedRouteId: "1_40", opacity: statusOpacity},
    expected: ["case", ["==", ["get", "routeId"], "1_40"], statusOpacity, ["*", statusOpacity, VEHICLE_DIM_FACTOR]]
  }
]

for (const {name, given, expected} of expressionCases) {
  deepStrictEqual(dimmedOpacity(given), expected, name)
}

const eventCases = [
  {name: "a route", detail: {routeId: "1_40"}, routeId: "1_40"},
  {name: "a cleared emphasis", detail: {routeId: null}, routeId: null}
]

for (const {name, detail, routeId} of eventCases) {
  deepStrictEqual(emphasizedRouteOf(detail), routeId, name)
}

const refusedDetails = [
  {name: "an empty id", detail: {routeId: ""}},
  {name: "a number", detail: {routeId: 40}},
  {name: "no field", detail: {}}
]

for (const {name, detail} of refusedDetails) {
  throws(() => emphasizedRouteOf(detail), name)
}

console.log(`route emphasis: ${alphaCases.length + expressionCases.length + eventCases.length + refusedDetails.length} cases hold`)
