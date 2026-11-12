// Checks the rows of the Trip tab's timeline of a chosen journey as pure
// functions of journeys written out by hand in the router's shape: a
// journey with walks and a change, a journey from a stop, a journey past
// midnight, the walk's minutes and meters, a boarding's code, a ride's
// headsign, live lateness, and passed stops, and each row's sentence. Run
// it with `node test/scripts/journey_timeline_check.mjs`; it exits non-zero
// on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {LegKind} from "../../assets/js/core/routing_engine.js"
import {LEG_KIND_TO_POINT} from "../../assets/js/core/point_journeys.js"
import {LiveKind} from "../../assets/js/journey_cards.js"
import {TimelineRowKind, headsignsByTrip, timelineRows} from "../../assets/js/journey_timeline.js"

const TIME_ZONE = "America/Los_Angeles"
const TODAY = "2026-11-08"
// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const TODAY_START_MS = 1794124800000
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS}
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const WALK_SPEED_M_PER_S = 1.2
const FIRST_WALK_S = 240
const CHANGE_WALK_S = 170
const LAST_WALK_S = 95
const LATE_MINUTES = 2
const NO_OFFSET = 0
const PREVIOUS_DAY_OFFSET = 1

function seconds(clock) {
  const [hours, minutes] = clock.split(":")
  return Number(hours) * HOUR_SECONDS + Number(minutes) * MINUTE_SECONDS
}

function ride({routeId, tripId, from, departs, to, arrives, passing = [], serviceDayOffset = NO_OFFSET}) {
  return {kind: LegKind.ride, tripId, routeId, serviceDayOffset, fromStopId: from, departureS: seconds(departs), toStopId: to, arrivalS: seconds(arrives), stopIds: [from, ...passing, to]}
}

const names = {
  stops: {
    "1_431": {name: "3rd Ave & Pike St", code: "575"},
    "1_440": {name: "3rd Ave & Union St", code: null},
    "1_450": {name: "3rd Ave & University St", code: null},
    "1_1121": {name: "3rd Ave & Pine St", code: "430"},
    "1_1500": {name: "Westlake Station", code: null},
    "1_9000": {name: "Capitol Hill Station", code: "99"},
  },
  routes: {"1_e": {name: "E", color: "#B91C1C"}, "1_line1": {name: "1 Line", color: "#1D4ED8"}},
}

const headsigns = new Map([["trip-e:0", "Aurora Village"], ["trip-1:0", "Lynnwood"], ["trip-owl:1", "Northgate"]])

// From the rider's position: a walk, the E past two stops, a walk to
// change, the 1 Line, and a walk to a point.
const changing = {
  serviceDate: TODAY,
  arrivalS: seconds("17:33"),
  changes: 1,
  isEarliest: true,
  legs: [
    {kind: LegKind.walkFromPosition, toStopId: "1_431", durationS: FIRST_WALK_S},
    ride({routeId: "1_e", tripId: "trip-e", from: "1_431", departs: "17:13", to: "1_1121", arrives: "17:21", passing: ["1_440", "1_450"]}),
    {kind: LegKind.walk, fromStopId: "1_1121", toStopId: "1_1500", durationS: CHANGE_WALK_S},
    ride({routeId: "1_line1", tripId: "trip-1", from: "1_1500", departs: "17:25", to: "1_9000", arrives: "17:31"}),
    {kind: LEG_KIND_TO_POINT, fromStopId: "1_9000", durationS: LAST_WALK_S},
  ],
  stopPositions: {},
  destination: {name: "Cal Anderson Park", lat: 47.617, lon: -122.319},
}

function rowsOf({journey, live = {kind: LiveKind.scheduled, routeId: "1_e"}, originName = "My location"}) {
  return timelineRows({journey, names, headsigns, live, originName, serviceDayStartsMs, timeZone: TIME_ZONE, walkSpeedMPerS: WALK_SPEED_M_PER_S})
}

function kindOf(row) {
  return row.kind
}

function sentenceOf(row) {
  return row.sentence
}

// A journey with walks and a change: the rows in the order taken, each
// boarding, change, and arrival with its time, and each row's sentence.
{
  const rows = rowsOf({journey: changing})
  const kinds = Array.from(rows, kindOf)
  const sentences = Array.from(rows, sentenceOf)
  deepStrictEqual(kinds, [
    TimelineRowKind.origin, TimelineRowKind.walk, TimelineRowKind.board, TimelineRowKind.ride, TimelineRowKind.alight,
    TimelineRowKind.walk, TimelineRowKind.board, TimelineRowKind.ride, TimelineRowKind.alight, TimelineRowKind.walk, TimelineRowKind.arrive,
  ])
  deepStrictEqual(sentences, [
    "5:09 pm leave My location",
    "walk 4 min, 290 m, to 3rd Ave & Pike St",
    "5:13 pm board E to Aurora Village at 3rd Ave & Pike St, stop 575",
    "ride 3 stops",
    "5:21 pm get off at 3rd Ave & Pine St and change",
    "walk 3 min, 200 m, to Westlake Station",
    "5:25 pm board 1 Line to Lynnwood at Westlake Station",
    "ride 1 stop",
    "5:31 pm get off at Capitol Hill Station",
    "walk 2 min, 110 m, to Cal Anderson Park",
    "5:33 pm arrive at Cal Anderson Park",
  ])
}

// A boarding names its stop, its code, and its time; a ride its route's
// chip, headsign, and the stops it passes; a change says so.
{
  const rows = rowsOf({journey: changing})
  const [, , board, eRide, change] = rows
  deepStrictEqual(board, {kind: TimelineRowKind.board, timeText: "5:13 pm", name: "3rd Ave & Pike St", detail: "Stop #575", color: "#B91C1C", sentence: "5:13 pm board E to Aurora Village at 3rd Ave & Pike St, stop 575"})
  deepStrictEqual(eRide.chip, {name: "E", color: "#B91C1C"})
  deepStrictEqual(eRide.headsign, "Aurora Village")
  deepStrictEqual(eRide.stopCountText, "Ride 3 stops")
  deepStrictEqual(eRide.passedStops, ["3rd Ave & Union St", "3rd Ave & University St"])
  deepStrictEqual(eRide.lateText, "")
  deepStrictEqual(change.detail, "Get off · change")
}

// The first ride carries its bus's live lateness where the card has it,
// and no later ride does.
{
  const live = {kind: LiveKind.live, latenessS: LATE_MINUTES * MINUTE_SECONDS, routeId: "1_e"}
  const rows = rowsOf({journey: changing, live})
  const rides = rows.filter(isRide)
  deepStrictEqual(rides[0].lateText, "2 min late")
  deepStrictEqual(rides[0].sentence, "ride 3 stops, 2 min late")
  deepStrictEqual(rides[1].lateText, "")
}

function isRide(row) {
  return row.kind === TimelineRowKind.ride
}

// A journey from a stop starts at its boarding; one whose last leg is a
// ride ends with its arrival at that ride's stop; a ride with no
// headsign names none.
{
  const fromStop = {...changing, legs: [ride({routeId: "1_e", tripId: "trip-unknown", from: "1_431", departs: "17:13", to: "1_1121", arrives: "17:21"})], arrivalS: seconds("17:21"), destination: undefined}
  const rows = rowsOf({journey: fromStop, originName: "3rd Ave & Pike St"})
  const kinds = Array.from(rows, kindOf)
  const sentences = Array.from(rows, sentenceOf)
  deepStrictEqual(kinds, [TimelineRowKind.board, TimelineRowKind.ride, TimelineRowKind.arrive])
  deepStrictEqual(sentences, ["5:13 pm board E at 3rd Ave & Pike St, stop 575", "ride 1 stop", "5:21 pm arrive at 3rd Ave & Pine St"])
}

// A ride past midnight reads its times on the clock after midnight and
// finds its headsign by its trip and its service day.
{
  const owl = {
    serviceDate: TODAY,
    arrivalS: seconds("24:40"),
    changes: 0,
    isEarliest: true,
    legs: [ride({routeId: "1_e", tripId: "trip-owl", from: "1_431", departs: "24:10", to: "1_1121", arrives: "24:40", serviceDayOffset: PREVIOUS_DAY_OFFSET})],
    stopPositions: {},
  }
  const rows = rowsOf({journey: owl, originName: "3rd Ave & Pike St"})
  const sentences = Array.from(rows, sentenceOf)
  deepStrictEqual(sentences, ["12:10 am board E to Northgate at 3rd Ave & Pike St, stop 575", "ride 1 stop", "12:40 am arrive at 3rd Ave & Pine St"])
}

// The headsigns are keyed by trip and service day, and a trip with none is
// left out.
{
  const trips = [{id: "t1", routeId: "r", serviceDayOffset: NO_OFFSET}, {id: "t1", routeId: "r", serviceDayOffset: PREVIOUS_DAY_OFFSET}, {id: "t2", routeId: "r", serviceDayOffset: NO_OFFSET}]
  const map = headsignsByTrip({trips, tripHeadsigns: ["Downtown", "Uptown", null]})
  const entries = Array.from(map)
  deepStrictEqual(entries, [["t1:0", "Downtown"], ["t1:1", "Uptown"]])
  throws(() => headsignsByTrip({trips, tripHeadsigns: ["Downtown"]}), AssertionError)
}

console.log("journey_timeline_check: every case passed")
