// Checks what the page answers for itself while it is offline, as pure
// functions of saved snapshot tables written out by hand: which answer each
// event the hooks push gets, a stop's position, the names of a trip's stops
// and routes with and without a names file, the routes of a trip's filter
// and the summary line it shows, the order the saved snapshots are read in,
// and the closes kept for the server. Run it with
// `node test/scripts/offline_answers_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {ROUTE_COLOR_DEFAULT} from "../../assets/js/trip_plan.js"
import {
  DEFERRED_CLOSE_COUNT_MAX,
  FILTER_RESTORE_REPLY,
  LocalAnswerKind,
  PageEventName,
  REFUSED_REPLY,
  TableKind,
  TripFilterKind,
  localAnswerOf,
  namesReply,
  positionReply,
  snapshotOrder,
  tripFilterOf,
  tripSummaryText,
  withClose,
  withoutClose
} from "../../assets/js/offline_answers.js"

const NAME_COUNT_MAX = 3
const ROUTE_COUNT_MAX = 2
const HOUR_MS = 60 * 60 * 1000
const THREE_HOURS_MS = 3 * 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const DAY_START_MS = Date.parse("2026-11-08T08:00:00.000Z")
const NEXT_DAY_START_MS = DAY_START_MS + DAY_MS
// The last departure of a date is past midnight, 26 hours after its start.
const LAST_DEPARTURE_SECONDS = 26 * 60 * 60
const UNKNOWN_MICRODEGREES = -2147483648
const PIKE_LAT_MICRODEGREES = 47608000
const PIKE_LON_MICRODEGREES = -122335000
const SECOND_STOP_LAT_MICRODEGREES = 47620500
const SECOND_STOP_LON_MICRODEGREES = -122349250
const LATER_STOP_LAT_MICRODEGREES = 47500000
const LATER_STOP_LON_MICRODEGREES = -122300000

function missing() {
  return {kind: TableKind.missing}
}

function found(table) {
  return {kind: TableKind.found, table}
}

function namesOf({stopNames, stopCodes, routes}) {
  return found({stopNames, stopCodes, tripHeadsigns: [], routes, agencyNames: {}})
}

// The stops file's identifiers by index, as the page keys them.
function indexesOf(stopIds) {
  const indexes = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    indexes.set(stopId, index)
  }

  return indexes
}

// Stops 1_10 and 1_20 with known positions and 1_30 with none; a names
// file for all three and for routes 100479 and 100512, the second with no
// short name and no color.
const today = {
  serviceDate: "2026-11-08",
  stopIndexes: indexesOf(["1_10", "1_20", "1_30"]),
  positions: found({
    latMicrodegrees: Int32Array.from([PIKE_LAT_MICRODEGREES, SECOND_STOP_LAT_MICRODEGREES, UNKNOWN_MICRODEGREES]),
    lonMicrodegrees: Int32Array.from([PIKE_LON_MICRODEGREES, SECOND_STOP_LON_MICRODEGREES, UNKNOWN_MICRODEGREES])
  }),
  names: namesOf({
    stopNames: ["3rd Ave & Pike St", null, "Westlake Station"],
    stopCodes: ["10", "20", null],
    routes: {
      "1_100479": {shortName: "E", longName: "E Line", color: "B3282D", agencyId: "1"},
      "1_100512": {shortName: null, longName: "Link light rail", color: null, agencyId: "40"}
    }
  })
}

// A later date that holds 1_40 alone, with no names file.
const tomorrow = {
  serviceDate: "2026-11-09",
  stopIndexes: indexesOf(["1_40"]),
  positions: found({latMicrodegrees: Int32Array.of(LATER_STOP_LAT_MICRODEGREES), lonMicrodegrees: Int32Array.of(LATER_STOP_LON_MICRODEGREES)}),
  names: missing()
}

const answerCases = [
  [PageEventName.stopPosition, LocalAnswerKind.position, "a stop's position is read from the saved positions"],
  [PageEventName.tripNames, LocalAnswerKind.names, "a trip's names are read from the saved names file"],
  [PageEventName.tripFilter, LocalAnswerKind.tripFilter, "a trip's filter is applied in the page"],
  [PageEventName.tripClear, LocalAnswerKind.tripClear, "clearing a trip ends its filter in the page"],
  [PageEventName.filterRestore, LocalAnswerKind.filterRestore, "the stored filter is kept, read-only"],
  [PageEventName.arrivalsOpen, LocalAnswerKind.cancelClose, "a stop opened again is no longer closed for the server"],
  [PageEventName.arrivalsClose, LocalAnswerKind.deferClose, "a closed stop is closed for the server once live"],
  [PageEventName.markersReady, LocalAnswerKind.scheduledMarkers, "the vehicle markers come from the schedule while offline"],
  [PageEventName.sharedVehiclesShow, LocalAnswerKind.unanswered, "scooters are not shown while offline"],
  [PageEventName.sharedVehiclesHide, LocalAnswerKind.unanswered, "scooters are not hidden while offline"]
]

for (const [name, kind, message] of answerCases) {
  deepStrictEqual(localAnswerOf(name), kind, message)
}

deepStrictEqual(Object.keys(PageEventName).length, answerCases.length, "every event a hook pushes has a case")
function answerOfUnpushedEvent() {
  localAnswerOf("vehicle-filter:query")
}

throws(answerOfUnpushedEvent, AssertionError, "an event no hook pushes is a programmer error")
deepStrictEqual(FILTER_RESTORE_REPLY, {accepted: true}, "the stored filter is accepted, so the browser keeps it")

const positionCases = [
  [{stop_id: "1_10"}, {lat: 47.608, lon: -122.335}, "a stop's position in degrees"],
  [{stop_id: "1_20"}, {lat: 47.6205, lon: -122.34925}, "microdegrees convert exactly"],
  [{stop_id: "1_40"}, {lat: 47.5, lon: -122.3}, "a stop of the later date alone is found there"],
  [{stop_id: "1_30"}, REFUSED_REPLY, "a stop with no known position is refused"],
  [{stop_id: "1_99"}, REFUSED_REPLY, "a stop no snapshot holds is refused"],
  [{}, REFUSED_REPLY, "a request that names no stop is refused"],
  [{stop_id: 10}, REFUSED_REPLY, "a stop identifier that is not text is refused"]
]

for (const [payload, expected, message] of positionCases) {
  deepStrictEqual(positionReply({snapshots: [today, tomorrow], payload}), expected, message)
}

const unpositioned = {...today, positions: missing()}
deepStrictEqual(positionReply({snapshots: [unpositioned], payload: {stop_id: "1_10"}}), REFUSED_REPLY, "a snapshot with no saved positions knows no position")
deepStrictEqual(positionReply({snapshots: [], payload: {stop_id: "1_10"}}), REFUSED_REPLY, "with nothing saved every stop is refused")

deepStrictEqual(
  namesReply({snapshots: [today, tomorrow], payload: {stop_ids: ["1_10", "1_20", "1_40"], route_ids: ["1_100479", "1_100512", "1_999"]}, countMax: NAME_COUNT_MAX}),
  {
    stops: {
      "1_10": {name: "3rd Ave & Pike St", code: "10"},
      "1_20": {name: null, code: "20"}
    },
    routes: {
      "1_100479": {name: "E", color: "#B3282D"},
      "1_100512": {name: "Link light rail", color: ROUTE_COLOR_DEFAULT}
    }
  },
  "names come from the names file; a stop or route it lacks is left to its identifier"
)

deepStrictEqual(
  namesReply({snapshots: [tomorrow], payload: {stop_ids: ["1_40"], route_ids: ["1_100479"]}, countMax: NAME_COUNT_MAX}),
  {stops: {}, routes: {}},
  "with no names file every stop and route keeps its identifier"
)

const refusedNameCases = [
  [{stop_ids: ["1_10"]}, "a request with no routes"],
  [{stop_ids: "1_10", route_ids: []}, "stops that are not a list"],
  [{stop_ids: ["1_10", true], route_ids: []}, "a stop identifier that is not text"],
  [{stop_ids: ["a", "b", "c", "d"], route_ids: []}, "more stops than the bound"],
  [{stop_ids: [], route_ids: ["a", "b", "c", "d"]}, "more routes than the bound"]
]

for (const [payload, message] of refusedNameCases) {
  deepStrictEqual(namesReply({snapshots: [today], payload, countMax: NAME_COUNT_MAX}), REFUSED_REPLY, `${message} is refused`)
}

const tripFilterCases = [
  [{route_ids: ["1_100479", "1_100512"]}, {kind: TripFilterKind.accepted, routeIds: ["1_100479", "1_100512"]}, "a trip's routes are its filter"],
  [{route_ids: ["1_100479", "1_100479"]}, {kind: TripFilterKind.accepted, routeIds: ["1_100479"]}, "a route ridden twice is kept once"],
  [{route_ids: []}, {kind: TripFilterKind.refused}, "a trip with no route is refused"],
  [{route_ids: ["a", "b", "c"]}, {kind: TripFilterKind.refused}, "more routes than the bound are refused"],
  [{route_ids: [true]}, {kind: TripFilterKind.refused}, "a route identifier that is not text is refused"],
  [{}, {kind: TripFilterKind.refused}, "a request that names no routes is refused"]
]

for (const [payload, expected, message] of tripFilterCases) {
  deepStrictEqual(tripFilterOf({payload, countMax: ROUTE_COUNT_MAX}), expected, message)
}

deepStrictEqual(
  tripSummaryText({snapshots: [today], routeIds: ["1_100479", "1_100512", "1_999"]}),
  "Showing the trip's routes: E, Link light rail, 1_999",
  "the summary names the trip's routes in riding order, by identifier where the names file lacks one"
)
deepStrictEqual(tripSummaryText({snapshots: [tomorrow], routeIds: ["1_100479"]}), "Showing the trip's routes: 1_100479", "with no names file the summary names identifiers")

function entry({serviceDate, serviceDayStartMs}) {
  return {serviceDate, serviceDayStartMs, connectionChunks: [{departureSMin: 0, departureSMax: LAST_DEPARTURE_SECONDS}]}
}

const manifest = {
  snapshots: [
    entry({serviceDate: "2026-11-08", serviceDayStartMs: DAY_START_MS}),
    entry({serviceDate: "2026-11-09", serviceDayStartMs: NEXT_DAY_START_MS})
  ]
}

function serviceDateOf(chosen) {
  return chosen.serviceDate
}

// The service dates in the order the page reads them at `nowMs`.
function serviceDatesAt(nowMs) {
  const entries = snapshotOrder({manifest, nowMs})
  return Array.from(entries, serviceDateOf)
}

const orderCases = [
  [DAY_START_MS + HOUR_MS, ["2026-11-08", "2026-11-09"], "the date running now is read first"],
  [NEXT_DAY_START_MS + THREE_HOURS_MS, ["2026-11-09", "2026-11-08"], "once the next date runs it is read first"],
  [DAY_START_MS - HOUR_MS, ["2026-11-08", "2026-11-09"], "before any date runs the manifest's order stands"]
]

for (const [nowMs, expected, message] of orderCases) {
  deepStrictEqual(serviceDatesAt(nowMs), expected, message)
}

deepStrictEqual(withClose({closes: [], stopId: "1_10"}), ["1_10"], "a close is kept")
deepStrictEqual(withClose({closes: ["1_10"], stopId: "1_10"}), ["1_10"], "a stop is closed once")
deepStrictEqual(withoutClose({closes: ["1_10", "1_20"], stopId: "1_10"}), ["1_20"], "a stop opened again is not closed")
deepStrictEqual(withoutClose({closes: ["1_20"], stopId: "1_10"}), ["1_20"], "opening a stop that was not closed changes nothing")

function stopIdOf(_value, index) {
  return `stop_${index}`
}

const full = Array.from({length: DEFERRED_CLOSE_COUNT_MAX}, stopIdOf)
const overfull = withClose({closes: full, stopId: "stop_new"})
deepStrictEqual(overfull.length, DEFERRED_CLOSE_COUNT_MAX, "the closes kept are bounded")
deepStrictEqual([overfull[0], overfull[overfull.length - 1]], ["stop_1", "stop_new"], "past the bound the oldest close is dropped")

console.log("offline answers: every case passed")
