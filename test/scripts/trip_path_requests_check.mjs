// Checks how the vehicle page asks for trip paths: one request at a time,
// at most 100 trips, never a trip the cache holds, a trip the server named
// missing left out until its retry time, a busy or failed answer backed
// off, and a request with no answer given up after its wait. Each case runs
// one pure function over requests, replies, and events written here, with
// times as plain numbers. Run it with
// `node test/scripts/trip_path_requests_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {AssertionError} from "../../assets/js/assert.js"
import {TRIP_PATH_REQUEST_COUNT_MAX, decodeTripPath, tripPathKey, withTripPaths} from "../../assets/js/trip_path.js"
import {
  BUSY_RETRY_MS,
  FAILED_RETRY_MS,
  MISSING_PATH_RETRY_MS,
  MISSING_TRIP_COUNT_MAX,
  PENDING_WAIT_MS,
  PathRequestKind,
  emptyPathRequests,
  nextPathRequest,
  pathRequestReplied,
  pathsReceived
} from "../../assets/js/trip_path_requests.js"

const fixtureUrl = new URL("../fixtures/one_bus_away/trip_path/encoded_loop.json", import.meta.url)
const {event: fixturePath} = JSON.parse(readFileSync(fixtureUrl, "utf8"))
const SERVICE_DATE_MS = 1794038400000
const START_MS = 1000
const STEP_MS = 1

function trip(index) {
  return {tripId: `1_${index}`, routeId: "1_100", serviceDateMs: SERVICE_DATE_MS}
}

function wire({tripId, routeId, serviceDateMs}) {
  return {trip_id: tripId, route_id: routeId, service_date_ms: serviceDateMs}
}

function missingOf(index) {
  return {...wire(trip(index)), reason: "schedule_missing"}
}

const twoTrips = [trip("a"), trip("b")]
const empty = new Map()
// Past each bound by this many trips.
const EXTRA_TRIP_COUNT = 20

// The trip at `index` of a list made with `Array.from`.
function tripAt(_unused, index) {
  return trip(index)
}

function missingAt(_unused, index) {
  return missingOf(index)
}

function refusedReply() {
  return pathRequestReplied({requests: first.requests, reply: {refused: true}, nowMs: START_MS})
}

function requestAtNoTime() {
  return nextPathRequest({requests: emptyPathRequests(), cache: empty, trips: twoTrips, nowMs: Number.NaN})
}

// A first request names every trip the cache lacks, in order.
const first = nextPathRequest({requests: emptyPathRequests(), cache: empty, trips: twoTrips, nowMs: START_MS})
deepStrictEqual(first.kind, PathRequestKind.request, "a first request is sent")
deepStrictEqual(first.trips, [wire(trip("a")), wire(trip("b"))], "a first request names both trips")

// Nothing more is sent while it runs.
const whilePending = nextPathRequest({requests: first.requests, cache: empty, trips: twoTrips, nowMs: START_MS + STEP_MS})
deepStrictEqual(whilePending.kind, PathRequestKind.none, "no request while one runs")

// A trip the cache holds is never asked for.
const fixtureDecoded = decodeTripPath(fixturePath)
const cached = withTripPaths(empty, [fixtureDecoded])
const cachedTrip = {tripId: fixturePath.trip_id, routeId: fixturePath.route_id, serviceDateMs: fixturePath.service_date_ms}
const withCached = nextPathRequest({requests: emptyPathRequests(), cache: cached, trips: [cachedTrip, trip("c")], nowMs: START_MS})
deepStrictEqual(withCached.trips, [wire(trip("c"))], "a cached trip is left out")
const onlyCached = nextPathRequest({requests: emptyPathRequests(), cache: cached, trips: [cachedTrip], nowMs: START_MS})
deepStrictEqual(onlyCached.kind, PathRequestKind.none, "nothing is sent when the cache holds every trip")
deepStrictEqual(nextPathRequest({requests: emptyPathRequests(), cache: empty, trips: [], nowMs: START_MS}).kind, PathRequestKind.none, "nothing is sent for no trip")

// At most 100 trips go in one request.
const manyTrips = Array.from({length: TRIP_PATH_REQUEST_COUNT_MAX + EXTRA_TRIP_COUNT}, tripAt)
const many = nextPathRequest({requests: emptyPathRequests(), cache: empty, trips: manyTrips, nowMs: START_MS})
deepStrictEqual(many.trips.length, TRIP_PATH_REQUEST_COUNT_MAX, "a request names at most 100 trips")

// An accepted request stays pending until its paths arrive.
const accepted = pathRequestReplied({requests: first.requests, reply: {accepted: true}, nowMs: START_MS + STEP_MS})
deepStrictEqual(nextPathRequest({requests: accepted, cache: empty, trips: twoTrips, nowMs: START_MS + STEP_MS}).kind, PathRequestKind.none, "an accepted request still runs")

// Its paths decode, and a trip the server names missing waits its retry time.
const received = pathsReceived({requests: accepted, event: {paths: [fixturePath], missing: [missingOf("b")]}, nowMs: START_MS + STEP_MS})
deepStrictEqual(received.paths.length, 1, "the event's path decodes")
deepStrictEqual(received.paths[0].key, fixtureDecoded.key, "the decoded path keeps its key")
const afterPaths = received.requests
const missingSoon = nextPathRequest({requests: afterPaths, cache: empty, trips: [trip("b")], nowMs: START_MS + MISSING_PATH_RETRY_MS})
deepStrictEqual(missingSoon.kind, PathRequestKind.none, "a missing trip is not asked for before its retry time")
const missingLater = nextPathRequest({requests: afterPaths, cache: empty, trips: [trip("b")], nowMs: START_MS + STEP_MS + MISSING_PATH_RETRY_MS})
deepStrictEqual(missingLater.trips, [wire(trip("b"))], "a missing trip is asked for again at its retry time")
const otherTrip = nextPathRequest({requests: afterPaths, cache: empty, trips: [trip("b"), trip("e")], nowMs: START_MS + STEP_MS})
deepStrictEqual(otherTrip.trips, [wire(trip("e"))], "a missing trip leaves the other trips asked for")

// A path the prediction cannot use, with one stop, counts as missing.
const oneStop = {...fixturePath, trip_id: "1_one_stop", stops: "??A"}
const unusable = pathsReceived({requests: accepted, event: {paths: [oneStop], missing: []}, nowMs: START_MS})
deepStrictEqual(unusable.paths, [], "a path of one stop is not kept")
const unusableTrip = {tripId: "1_one_stop", routeId: fixturePath.route_id, serviceDateMs: fixturePath.service_date_ms}
deepStrictEqual(nextPathRequest({requests: unusable.requests, cache: empty, trips: [unusableTrip], nowMs: START_MS + STEP_MS}).kind, PathRequestKind.none, "a path of one stop waits its retry time")

// A busy answer backs off, and the next request goes at its retry time.
const busy = pathRequestReplied({requests: first.requests, reply: {busy: true}, nowMs: START_MS})
deepStrictEqual(nextPathRequest({requests: busy, cache: empty, trips: twoTrips, nowMs: START_MS + BUSY_RETRY_MS - STEP_MS}).kind, PathRequestKind.none, "a busy answer waits")
deepStrictEqual(nextPathRequest({requests: busy, cache: empty, trips: twoTrips, nowMs: START_MS + BUSY_RETRY_MS}).kind, PathRequestKind.request, "a busy answer retries at its time")

// A failed build backs off longer.
const failed = pathsReceived({requests: accepted, event: {paths: [], missing: [], failed: "timeout"}, nowMs: START_MS})
deepStrictEqual(failed.paths, [], "a failed event holds no path")
deepStrictEqual(nextPathRequest({requests: failed.requests, cache: empty, trips: twoTrips, nowMs: START_MS + FAILED_RETRY_MS - STEP_MS}).kind, PathRequestKind.none, "a failed build waits")
deepStrictEqual(nextPathRequest({requests: failed.requests, cache: empty, trips: twoTrips, nowMs: START_MS + FAILED_RETRY_MS}).kind, PathRequestKind.request, "a failed build retries at its time")

// A request with no answer is given up after its wait.
deepStrictEqual(nextPathRequest({requests: first.requests, cache: empty, trips: twoTrips, nowMs: START_MS + PENDING_WAIT_MS - STEP_MS}).kind, PathRequestKind.none, "an unanswered request is waited for")
deepStrictEqual(nextPathRequest({requests: first.requests, cache: empty, trips: twoTrips, nowMs: START_MS + PENDING_WAIT_MS}).kind, PathRequestKind.request, "an unanswered request is given up after its wait")

// The missing trips held are bounded, the earliest leaving first.
const manyMissing = Array.from({length: MISSING_TRIP_COUNT_MAX + EXTRA_TRIP_COUNT}, missingAt)
const bounded = pathsReceived({requests: accepted, event: {paths: [], missing: manyMissing}, nowMs: START_MS})
ok(bounded.requests.missingUntilMs.size === MISSING_TRIP_COUNT_MAX, "the missing trips are bounded")
const earliestMissingKey = tripPathKey(tripAt(null, 0))
ok(!bounded.requests.missingUntilMs.has(earliestMissingKey), "the earliest missing trip leaves first")

// A refused request is a programmer error: the page sent what it must not.
throws(refusedReply, AssertionError, "a refused request")
throws(requestAtNoTime, AssertionError, "a time that is not a number")

console.log("trip path requests check passed")
