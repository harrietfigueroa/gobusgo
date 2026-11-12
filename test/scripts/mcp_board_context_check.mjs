// Checks the object the arrivals board hands the model for a list of
// scheduled departures, as pure functions of values written out by hand: the
// fields of version 1 of "gobusgo.departures", a list that is bounded, empty,
// or of a date no snapshot holds, the note on a departure within the live
// window, the reads that offer nothing, and the check each field fails. Run
// it with `node test/scripts/mcp_board_context_check.mjs`; it exits non-zero
// on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {DepartureLoadKind} from "../../assets/js/departure_files.js"
import {LIVE_NOTE} from "../../assets/js/mcp_board_departures.js"
import {
  DEPARTURES_SCHEMA_NAME,
  DEPARTURES_SCHEMA_VERSION,
  DeparturesStatus,
  departuresContext,
  departuresProblem,
  isOffered
} from "../../assets/js/mcp_board_context.js"
import {ProblemKind} from "../../assets/js/mcp_trip_journey.js"
import {DEPARTURE_COUNT_MAX} from "../../assets/js/core/scheduled_service.js"

const TIME_ZONE = "America/Los_Angeles"
const MINUTE_MS = 60 * 1000
const SOON_OFFSET_MS = 10 * 60 * 1000
const LAST_OFFSET_MS = 20 * 60 * 1000
const NOT_TEXT = 7
const NOW_MS = Date.parse("2026-11-09T04:00:00Z")
const FROM_MS = Date.parse("2026-11-09T07:00:00Z")

function departure({timeMs, route, headsign}) {
  return {timeMs, tripId: `trip-${timeMs}`, routeId: `1_${route}`, route, color: "#112233", headsign}
}

const SOON = departure({timeMs: NOW_MS + SOON_OFFSET_MS, route: "44", headsign: "Ballard"})
const LAST = departure({timeMs: FROM_MS + LAST_OFFSET_MS, route: "44", headsign: null})

function contextOf({loaded, routeIds = []}) {
  return departuresContext({loaded, stopId: "1_100", fromMs: FROM_MS, routeIds, nowMs: NOW_MS, timeZone: TIME_ZONE})
}

const listed = {kind: DepartureLoadKind.listed, stopName: "Pine St & 3rd Ave", departures: [SOON, LAST], isBounded: false}
const context = contextOf({loaded: listed, routeIds: ["1_44"]})

deepStrictEqual(
  context,
  {
    schema: "gobusgo.departures",
    version: 1,
    status: DeparturesStatus.listed,
    timeZone: TIME_ZONE,
    stop: {id: "1_100", name: "Pine St & 3rd Ave"},
    from: "2026-11-09T07:00:00.000Z",
    listedAt: "2026-11-09T04:00:00.000Z",
    routeIds: ["1_44"],
    isBounded: false,
    departures: [
      {departsAt: "2026-11-09T04:10:00.000Z", route: {id: "1_44", name: "44"}, headsign: "Ballard", note: LIVE_NOTE},
      {departsAt: "2026-11-09T07:20:00.000Z", route: {id: "1_44", name: "44"}, headsign: null}
    ]
  },
  "the departures from a time at a stop, each with its route, its headsign, and a note where the live answer comes from arrivals"
)

deepStrictEqual([DEPARTURES_SCHEMA_NAME, DEPARTURES_SCHEMA_VERSION], ["gobusgo.departures", 1], "the schema's name and version")
deepStrictEqual(departuresProblem(context), {kind: ProblemKind.valid}, "the object passes its own check")
const serialized = JSON.stringify(context)
deepStrictEqual(JSON.parse(serialized), context, "the object is JSON")

const bounded = contextOf({loaded: {...listed, isBounded: true}})
deepStrictEqual([bounded.isBounded, bounded.routeIds], [true, []], "a bounded list says so, and no route asked for is every route")

const empty = contextOf({loaded: {...listed, departures: []}})
deepStrictEqual([empty.status, empty.departures, departuresProblem(empty)], [DeparturesStatus.listed, [], {kind: ProblemKind.valid}], "a list of none is the model's answer that the schedule holds none")

const unnamed = contextOf({loaded: {...listed, stopName: null}})
deepStrictEqual(unnamed.stop, {id: "1_100", name: null}, "a stop with no name in the files has a null name")
deepStrictEqual(departuresProblem(unnamed), {kind: ProblemKind.valid}, "and passes")

const noSchedule = contextOf({loaded: {kind: DepartureLoadKind.noSchedule}})
deepStrictEqual([noSchedule.status, noSchedule.stop, noSchedule.departures, noSchedule.isBounded, departuresProblem(noSchedule)], [DeparturesStatus.noSchedule, {id: "1_100", name: null}, [], false, {kind: ProblemKind.valid}], "a date no snapshot holds says so and lists nothing")

const offeredCases = [
  [listed, true, "a list is offered"],
  [{kind: DepartureLoadKind.noSchedule}, true, "a date no snapshot holds is offered"],
  [{kind: DepartureLoadKind.unknownStop}, false, "a stop no snapshot holds is not"],
  [{kind: DepartureLoadKind.failed, reason: "fetchFailed", path: "/routing/x"}, false, "a failed read is not"]
]

for (const [loaded, expected, message] of offeredCases) {
  deepStrictEqual(isOffered(loaded), expected, message)
}

function offerUnknownStop() {
  return contextOf({loaded: {kind: DepartureLoadKind.unknownStop}})
}

function tooManyDepartureAt(_value, index) {
  return departure({timeMs: FROM_MS + index * MINUTE_MS, route: "44", headsign: null})
}

function offerTooMany() {
  const many = Array.from({length: DEPARTURE_COUNT_MAX + 1}, tooManyDepartureAt)
  return contextOf({loaded: {...listed, departures: many}})
}

throws(offerUnknownStop, AssertionError, "a read that offers nothing writes no object")
throws(offerTooMany, AssertionError, "a list over the bound writes no object")

// Each field fails by its path, and a field the version does not name passes.
const [firstDeparture] = context.departures

function firstDepartureAgain() {
  return firstDeparture
}

const tooManyWritten = Array.from({length: DEPARTURE_COUNT_MAX + 1}, firstDepartureAgain)
const invalidCases = [
  ["root", null],
  ["schema", {...context, schema: "gobusgo.journey"}],
  ["version", {...context, version: 2}],
  ["status", {...context, status: "found"}],
  ["timeZone", {...context, timeZone: ""}],
  ["stop", {...context, stop: "1_100"}],
  ["stop.id", {...context, stop: {id: "", name: "x"}}],
  ["stop.name", {...context, stop: {id: "1_100", name: 4}}],
  ["from", {...context, from: "2026-11-09T07:00:00"}],
  ["listedAt", {...context, listedAt: "tonight"}],
  ["routeIds", {...context, routeIds: "1_44"}],
  ["routeIds.0", {...context, routeIds: [NOT_TEXT]}],
  ["isBounded", {...context, isBounded: "no"}],
  ["departures", {...context, departures: {}}],
  ["departures", {...context, departures: tooManyWritten}],
  ["departures.0", {...context, departures: [null]}],
  ["departures.0.departsAt", {...context, departures: [{...firstDeparture, departsAt: "10 pm"}]}],
  ["departures.0.route", {...context, departures: [{...firstDeparture, route: "44"}]}],
  ["departures.0.route.id", {...context, departures: [{...firstDeparture, route: {id: "", name: "44"}}]}],
  ["departures.0.route.name", {...context, departures: [{...firstDeparture, route: {id: "1_44", name: 44}}]}],
  ["departures.0.headsign", {...context, departures: [{...firstDeparture, headsign: 7}]}],
  ["departures.0.note", {...context, departures: [{...firstDeparture, note: 7}]}],
  ["departures.1.departsAt", {...context, departures: [firstDeparture, {...firstDeparture, departsAt: ""}]}]
]

for (const [path, value] of invalidCases) {
  deepStrictEqual(departuresProblem(value), {kind: ProblemKind.invalid, path}, `invalid at ${path}`)
}

deepStrictEqual(departuresProblem({...context, later: "a field a later version adds"}), {kind: ProblemKind.valid}, "a field the version does not name passes")

console.log("mcp board context: every case passed")
