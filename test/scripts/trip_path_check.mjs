// Checks the vehicle page's trip path decoder and cache as pure functions:
// the decoder reads the shared fixture the Elixir tests pin to the server's
// builder, the stored loop trip 1_1137791 of route 1_7994, and must find
// its points and each stop's distance and times; the cache and the request
// are fed paths and trips written out by hand. Run it with
// `node test/scripts/trip_path_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {AssertionError} from "../../assets/js/assert.js"
import {distanceMeters} from "../../assets/js/marker_glide.js"
import {
  TRIP_PATH_COUNT_MAX,
  TRIP_PATH_REQUEST_COUNT_MAX,
  decodeTripPath,
  tripPathKey,
  tripPathRequest,
  withTripPaths
} from "../../assets/js/trip_path.js"

const fixtureUrl = new URL("../fixtures/one_bus_away/trip_path/encoded_loop.json", import.meta.url)
const {event, expected} = JSON.parse(readFileSync(fixtureUrl, "utf8"))
const DISTANCE_TOLERANCE_M = 1

const decoded = decodeTripPath(event)

deepStrictEqual(decoded.points.length, expected.pointCount, "the point count")
deepStrictEqual(decoded.points[0], expected.firstPoint, "the first point")
deepStrictEqual(decoded.points[decoded.points.length - 1], expected.lastPoint, "the last point")
deepStrictEqual(decoded.stops.map((stop) => stop.distanceMeters), expected.stopDistancesM, "the stop distances")
deepStrictEqual(decoded.stops.map((stop) => stop.arrivalSeconds), expected.arrivalS, "the arrivals")
deepStrictEqual(decoded.stops.map((stop) => stop.departureSeconds), expected.departureS, "the departures")
deepStrictEqual(decoded.key, tripPathKey({tripId: event.trip_id, serviceDateMs: event.service_date_ms}), "the key")

// The server measures a stop's distance over the same rounded points by the
// same formula, so the length of the decoded points is the last stop's
// distance.
let lengthMeters = 0
for (let index = 1; index < decoded.points.length; index += 1) {
  lengthMeters += distanceMeters(decoded.points[index - 1], decoded.points[index])
}
ok(Math.abs(lengthMeters - expected.lengthM) <= DISTANCE_TOLERANCE_M, "the length along the points: " + lengthMeters)
ok(Object.isFrozen(decoded) && Object.isFrozen(decoded.stops[0]), "the decoded path is frozen")

const refusedCases = [
  {name: "a character outside the format", path: {...event, points: event.points + " "}},
  {name: "text that ends inside a number", path: {...event, stops: event.stops + "_"}},
  {name: "a stop of two numbers", path: {...event, stops: "??"}},
  {name: "no point", path: {...event, points: ""}},
  // A second stop at -1 m: the number -1 is written as "@".
  {name: "a stop before the stop before it", path: {...event, stops: "???" + "@??"}}
]

for (const {name, path} of refusedCases) {
  throws(() => decodeTripPath(path), AssertionError, name)
}

function heldPath(index) {
  return {key: tripPathKey({tripId: "trip_" + index, serviceDateMs: event.service_date_ms})}
}

const filled = withTripPaths(new Map(), Array.from({length: TRIP_PATH_COUNT_MAX + 1}, (_value, index) => heldPath(index)))
deepStrictEqual(filled.size, TRIP_PATH_COUNT_MAX, "the cache holds no more paths than its bound")
ok(!filled.has(heldPath(0).key), "the cache evicts the path put earliest")
ok(filled.has(heldPath(TRIP_PATH_COUNT_MAX).key), "the cache keeps the path put last")

const empty = new Map()
withTripPaths(empty, [heldPath(1)])
deepStrictEqual(empty.size, 0, "the cache given is left as it was")

const moved = withTripPaths(withTripPaths(new Map(), [heldPath(1), heldPath(2)]), [heldPath(1)])
deepStrictEqual(Array.from(moved.keys()), [heldPath(2).key, heldPath(1).key], "a path put again moves to the back")

function trip(index) {
  return {tripId: "trip_" + index, routeId: "1_7994", serviceDateMs: event.service_date_ms}
}

const held = withTripPaths(new Map(), [heldPath(1)])
deepStrictEqual(
  tripPathRequest(held, [trip(1), trip(2), trip(2)]),
  [{trip_id: "trip_2", route_id: "1_7994", service_date_ms: event.service_date_ms}],
  "a request names each trip the cache lacks once"
)

const manyTrips = Array.from({length: TRIP_PATH_REQUEST_COUNT_MAX + 1}, (_value, index) => trip(index))
deepStrictEqual(tripPathRequest(new Map(), manyTrips).length, TRIP_PATH_REQUEST_COUNT_MAX, "a request names at most its bound")

console.log("trip path checks passed")
