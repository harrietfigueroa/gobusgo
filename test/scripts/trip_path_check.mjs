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
import {distanceMeters} from "../../assets/js/math/geodesy.js"
import {
  TRIP_PATH_COUNT_MAX,
  TRIP_PATH_REQUEST_COUNT_MAX,
  decodeTripPath,
  tripPathKey,
  tripPathRequest,
  withTripPaths
} from "../../assets/js/trip_path.js"

const fixtureUrl = new URL("../fixtures/one_bus_away/trip_path/encoded_loop.json", import.meta.url)
const fixtureText = readFileSync(fixtureUrl, "utf8")
const {event, expected} = JSON.parse(fixtureText)
const DISTANCE_TOLERANCE_M = 1
const ROUTE_ID = "1_7994"

function stopDistance(stop) {
  return stop.distanceMeters
}

function stopArrival(stop) {
  return stop.arrivalSeconds
}

function stopDeparture(stop) {
  return stop.departureSeconds
}

const decoded = decodeTripPath(event)
const lastPoint = decoded.points[decoded.points.length - 1]
const stopDistances = Array.from(decoded.stops, stopDistance)
const stopArrivals = Array.from(decoded.stops, stopArrival)
const stopDepartures = Array.from(decoded.stops, stopDeparture)
const eventKey = tripPathKey({tripId: event.trip_id, serviceDateMs: event.service_date_ms})

deepStrictEqual(decoded.points.length, expected.pointCount, "the point count")
deepStrictEqual(decoded.points[0], expected.firstPoint, "the first point")
deepStrictEqual(lastPoint, expected.lastPoint, "the last point")
deepStrictEqual(stopDistances, expected.stopDistancesM, "the stop distances")
deepStrictEqual(stopArrivals, expected.arrivalS, "the arrivals")
deepStrictEqual(stopDepartures, expected.departureS, "the departures")
deepStrictEqual(decoded.key, eventKey, "the key")

// The server measures a stop's distance over the same rounded points by the
// same formula, so the length of the decoded points is the last stop's
// distance.
let lengthMeters = 0
for (let index = 1; index < decoded.points.length; index += 1) {
  lengthMeters += distanceMeters(decoded.points[index - 1], decoded.points[index])
}
const lengthErrorMeters = Math.abs(lengthMeters - expected.lengthM)
ok(lengthErrorMeters <= DISTANCE_TOLERANCE_M, "the length along the points: " + lengthMeters)
ok(Object.isFrozen(decoded), "the decoded path is frozen")
ok(Object.isFrozen(decoded.stops[0]), "a decoded stop is frozen")

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

function heldPath(name) {
  return {key: tripPathKey({tripId: "trip_" + name, serviceDateMs: event.service_date_ms})}
}

function trip(name) {
  return {tripId: "trip_" + name, routeId: ROUTE_ID, serviceDateMs: event.service_date_ms}
}

const overflowing = []
for (let index = 0; index <= TRIP_PATH_COUNT_MAX; index += 1) {
  overflowing.push(heldPath(index))
}
const filled = withTripPaths(new Map(), overflowing)
const firstKey = heldPath(0).key
const lastKey = heldPath(TRIP_PATH_COUNT_MAX).key
deepStrictEqual(filled.size, TRIP_PATH_COUNT_MAX, "the cache holds no more paths than its bound")
ok(!filled.has(firstKey), "the cache evicts the path put earliest")
ok(filled.has(lastKey), "the cache keeps the path put last")

const empty = new Map()
const firstPath = heldPath("first")
const secondPath = heldPath("second")
withTripPaths(empty, [firstPath])
deepStrictEqual(empty.size, 0, "the cache given is left as it was")

const both = withTripPaths(new Map(), [firstPath, secondPath])
const moved = withTripPaths(both, [firstPath])
const movedKeys = Array.from(moved.keys())
deepStrictEqual(movedKeys, [secondPath.key, firstPath.key], "a path put again moves to the back")

const held = withTripPaths(new Map(), [firstPath])
const requested = tripPathRequest(held, [trip("first"), trip("second"), trip("second")])
deepStrictEqual(
  requested,
  [{trip_id: "trip_second", route_id: ROUTE_ID, service_date_ms: event.service_date_ms}],
  "a request names each trip the cache lacks once"
)

const manyTrips = []
for (let index = 0; index <= TRIP_PATH_REQUEST_COUNT_MAX; index += 1) {
  manyTrips.push(trip(index))
}
const bounded = tripPathRequest(new Map(), manyTrips)
deepStrictEqual(bounded.length, TRIP_PATH_REQUEST_COUNT_MAX, "a request names at most its bound")

console.log("trip path checks passed")
