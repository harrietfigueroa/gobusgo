// Checks the journey the trip planner app hands the model, as pure functions
// over a journey written out by hand: the version 1 object for a journey of
// each kind of leg, its instants, names, and minutes, the sentence that
// follows it, and each refusal of the object's check, which names the field.
// Run it with `node test/scripts/mcp_trip_journey_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {LegKind} from "../../assets/js/routing_engine.js"
import {JOURNEY_LEG_COUNT_MAX, JOURNEY_SCHEMA_NAME, JOURNEY_SCHEMA_VERSION, ProblemKind, chosenMessage, journeyContext, journeyProblem} from "../../assets/js/mcp_trip_journey.js"
import {LEG_KIND_TO_POINT} from "../../assets/js/point_journeys.js"
import {journeyRows} from "../../assets/js/trip_plan.js"
import {seconds} from "./routing_timetable.js"

const TIME_ZONE = "America/Los_Angeles"
const SERVICE_DATE = "2026-11-08"
// Midnight on 2026-11-08 in Los Angeles, which is 07:00 UTC: the clocks go back at 02:00.
const SERVICE_DAY_START_MS = Date.parse("2026-11-08T00:00:00-07:00")
const serviceDayStartsMs = {[SERVICE_DATE]: SERVICE_DAY_START_MS}
const MS_PER_SECOND = 1000
const FIRST_RIDE_DEPARTURE_S = seconds("08:05")
const WALK_FROM_START_S = 90
const WALK_BETWEEN_STOPS_S = 61
const WALK_TO_POINT_S = 120
const WALK_FROM_START_MINUTES = 2
const WALK_BETWEEN_STOPS_MINUTES = 2
const WALK_TO_POINT_MINUTES = 2
const NOW_MS = SERVICE_DAY_START_MS + seconds("07:00") * MS_PER_SECOND
const ONE_CHANGE = 1
const FRACTIONAL_MINUTES = 1.5

// The indexes of the legs of the journey below.
const WALK_FROM_START = 0
const FIRST_RIDE = 1
const WALK_BETWEEN_STOPS = 2
const WALK_TO_POINT = 4

const names = {
  stops: {"1_100": {name: "Pine St & 3rd Ave", code: "100"}, "1_200": {name: "Westlake Station", code: "200"}, "1_300": {name: "Ballard Locks", code: "300"}},
  routes: {"1_40": {name: "40", color: "#3366aa"}},
}

function ride({fromStopId, toStopId, departureS, arrivalS}) {
  return {kind: LegKind.ride, tripId: "1_trip", routeId: "1_40", serviceDayOffset: 0, stopIds: [fromStopId, toStopId], fromStopId, toStopId, departureS, arrivalS}
}

// A start from the rider's position, a ride, a walk between two stops, a
// second ride, and a walk to a point that is no stop.
const journey = {
  serviceDate: SERVICE_DATE,
  changes: ONE_CHANGE,
  isEarliest: true,
  arrivalS: seconds("08:40"),
  destination: {name: "Ballard Locks", lat: 47.6654, lon: -122.3977},
  legs: [
    {kind: LegKind.walkFromPosition, toStopId: "1_100", durationS: WALK_FROM_START_S},
    ride({fromStopId: "1_100", toStopId: "1_200", departureS: FIRST_RIDE_DEPARTURE_S, arrivalS: seconds("08:15")}),
    {kind: LegKind.walk, fromStopId: "1_200", toStopId: "1_200", durationS: WALK_BETWEEN_STOPS_S},
    ride({fromStopId: "1_200", toStopId: "1_300", departureS: seconds("08:20"), arrivalS: seconds("08:38")}),
    {kind: LEG_KIND_TO_POINT, fromStopId: "1_300", durationS: WALK_TO_POINT_S},
  ],
}

function contextOf(overrides) {
  return journeyContext({journey, names, serviceDayStartsMs, timeZone: TIME_ZONE, from: "My location", to: "Ballard Locks", ...overrides})
}

function instantAt(secondsOfDay) {
  return new Date(SERVICE_DAY_START_MS + secondsOfDay * MS_PER_SECOND).toISOString()
}

function kindOf(leg) {
  return leg.kind
}

const context = contextOf({})

deepStrictEqual(context.schema, JOURNEY_SCHEMA_NAME, "the schema's name")
deepStrictEqual(context.version, JOURNEY_SCHEMA_VERSION, "the schema's version")
deepStrictEqual(context.serviceDate, SERVICE_DATE, "the service date")
deepStrictEqual(context.timeZone, TIME_ZONE, "the time zone")
deepStrictEqual([context.from, context.to], ["My location", "Ballard Locks"], "the ends")
deepStrictEqual(context.changes, ONE_CHANGE, "the changes")
// The journey leaves the walk before its first ride, at 08:05 less 90 s, and arrives at 08:40.
deepStrictEqual(context.departsAt, instantAt(FIRST_RIDE_DEPARTURE_S - WALK_FROM_START_S), "the journey leaves before its first ride by the walk")
deepStrictEqual(context.arrivesAt, instantAt(journey.arrivalS), "the journey arrives")
const kinds = Array.from(context.legs, kindOf)
deepStrictEqual(kinds, ["walk", "ride", "walk", "ride", "walk"], "the legs' kinds")

deepStrictEqual(context.legs[WALK_FROM_START], {kind: "walk", minutes: WALK_FROM_START_MINUTES, from: {name: "My location"}, to: {id: "1_100", name: "Pine St & 3rd Ave"}}, "a walk from the rider's position")
deepStrictEqual(
  context.legs[FIRST_RIDE],
  {
    kind: "ride",
    route: {id: "1_40", name: "40"},
    from: {id: "1_100", name: "Pine St & 3rd Ave"},
    to: {id: "1_200", name: "Westlake Station"},
    departsAt: "2026-11-08T15:05:00.000Z",
    arrivesAt: "2026-11-08T15:15:00.000Z",
  },
  "a ride, its instants in UTC"
)
deepStrictEqual(context.legs[WALK_BETWEEN_STOPS], {kind: "walk", minutes: WALK_BETWEEN_STOPS_MINUTES, from: {id: "1_200", name: "Westlake Station"}, to: {id: "1_200", name: "Westlake Station"}}, "a walk between stops rounds its minutes up")
deepStrictEqual(context.legs[WALK_TO_POINT], {kind: "walk", minutes: WALK_TO_POINT_MINUTES, from: {id: "1_300", name: "Ballard Locks"}, to: {name: "Ballard Locks"}}, "a walk to a point")

// A stop the names do not hold shows its identifier, as the Trip tab does.
const unnamed = contextOf({names: {stops: {}, routes: {}}})
deepStrictEqual(unnamed.legs[FIRST_RIDE].route, {id: "1_40", name: "1_40"}, "a route no names hold shows its identifier")
deepStrictEqual(unnamed.legs[FIRST_RIDE].from, {id: "1_100", name: "1_100"}, "a stop no names hold shows its identifier")

// The object passes its own check, and survives a round trip through JSON.
const text = JSON.stringify(context)
const decoded = JSON.parse(text)
deepStrictEqual(journeyProblem(context), {kind: ProblemKind.valid}, "the object is valid")
deepStrictEqual(journeyProblem(decoded), {kind: ProblemKind.valid}, "the object is valid after a JSON round trip")
deepStrictEqual(journeyProblem({...context, extra: "kept"}), {kind: ProblemKind.valid}, "a field the version does not name is left alone")

// The sentence that follows the object reads the Trip tab's row.
const [row] = journeyRows({journeys: [journey], nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
const message = chosenMessage({row, from: "My location", to: "Ballard Locks"})
deepStrictEqual(message, `I chose the journey from My location to Ballard Locks: ${row.timesText}, ${row.changesText}.`, "the message")
deepStrictEqual(row.changesText, "1 change", "the row's changes")

const OTHER_VERSION = JOURNEY_SCHEMA_VERSION + 1
const NEGATIVE_CHANGES = -1
const NOT_TEXT = 8
const NOT_AN_INSTANT = 5

function tooManyLegs() {
  return Array.from({length: JOURNEY_LEG_COUNT_MAX + 1}, () => context.legs[WALK_FROM_START])
}

const refusals = [
  {name: "a value that is no object", value: "text", path: "root"},
  {name: "another schema", value: {...context, schema: "other"}, path: "schema"},
  {name: "another version", value: {...context, version: OTHER_VERSION}, path: "version"},
  {name: "a blank service date", value: {...context, serviceDate: ""}, path: "serviceDate"},
  {name: "a time zone that is no text", value: {...context, timeZone: NOT_TEXT}, path: "timeZone"},
  {name: "an instant with no zone", value: {...context, departsAt: "2026-11-08T08:00:00"}, path: "departsAt"},
  {name: "an instant that is no time", value: {...context, arrivesAt: "soon"}, path: "arrivesAt"},
  {name: "a negative count of changes", value: {...context, changes: NEGATIVE_CHANGES}, path: "changes"},
  {name: "legs that are no list", value: {...context, legs: {}}, path: "legs"},
  {name: "no leg", value: {...context, legs: []}, path: "legs"},
  {name: "more legs than the bound", value: {...context, legs: tooManyLegs()}, path: "legs"},
  {name: "a leg of unknown kind", value: {...context, legs: [{...context.legs[WALK_FROM_START], kind: "fly"}]}, path: "legs.0.kind"},
  {name: "a ride with no route name", value: {...context, legs: [{...context.legs[FIRST_RIDE], route: {id: "1_40"}}]}, path: "legs.0.route.name"},
  {name: "a ride whose stop has no id", value: {...context, legs: [{...context.legs[FIRST_RIDE], from: {name: "A"}}]}, path: "legs.0.from.id"},
  {name: "a ride that leaves at no instant", value: {...context, legs: [{...context.legs[FIRST_RIDE], departsAt: NOT_AN_INSTANT}]}, path: "legs.0.departsAt"},
  {name: "a walk of fractional minutes", value: {...context, legs: [{...context.legs[WALK_FROM_START], minutes: FRACTIONAL_MINUTES}]}, path: "legs.0.minutes"},
  {name: "a walk to no place", value: {...context, legs: [{...context.legs[WALK_FROM_START], to: null}]}, path: "legs.0.to"},
]

for (const {name, value, path} of refusals) {
  deepStrictEqual(journeyProblem(value), {kind: ProblemKind.invalid, path}, name)
}

// A journey with no leg, or more legs than the bound, is a programmer error.
const longJourney = {...journey, legs: Array.from({length: JOURNEY_LEG_COUNT_MAX + 1}, () => journey.legs[WALK_FROM_START])}
throws(() => contextOf({journey: {...journey, legs: []}}), AssertionError)
throws(() => contextOf({journey: longJourney}), AssertionError)
throws(() => contextOf({serviceDayStartsMs: {}}), AssertionError)

console.log(`mcp_trip_journey_check: ${refusals.length} refusals and the legs of a journey passed`)
