// Checks what the trip strip says of a chosen journey as a pure function of
// journeys written out by hand in the router's shape: a journey whose first
// bus is live, one whose first bus is scheduled, a journey that only walks,
// one that leaves tomorrow, and one that changes, with its strip's leave
// and arrival texts, status, first step, next two steps, and sentence. Run
// it with `node test/scripts/trip_strip_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {LegKind} from "../../assets/js/routing_engine.js"
import {LEG_KIND_TO_POINT} from "../../assets/js/point_journeys.js"
import {LiveKind, firstRideLive, journeyCard} from "../../assets/js/journey_cards.js"
import {journeyRows} from "../../assets/js/trip_plan.js"
import {tripStrip} from "../../assets/js/trip_strip.js"

const TIME_ZONE = "America/Los_Angeles"
const TODAY = "2026-11-08"
const TOMORROW = "2026-11-09"
// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const TODAY_START_MS = 1794124800000
const DAY_MS = 24 * 60 * 60 * 1000
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS, [TOMORROW]: TODAY_START_MS + DAY_MS}
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const SECOND_MS = 1000
const MINUTE_MS = 60 * 1000
const WALK_SECONDS = 170
const LATE_MINUTES = 2
const NEXT_STEP_COUNT_MAX = 2

function seconds(clock) {
  const [hours, minutes] = clock.split(":")
  return Number(hours) * HOUR_SECONDS + Number(minutes) * MINUTE_SECONDS
}

function atMs(clock) {
  return TODAY_START_MS + seconds(clock) * SECOND_MS
}

function ride({routeId, from, departs, to, arrives}) {
  return {kind: LegKind.ride, tripId: `trip-${routeId}`, routeId, serviceDayOffset: 0, fromStopId: from, departureS: seconds(departs), toStopId: to, arrivalS: seconds(arrives), stopIds: [from, to]}
}

function walk({from, to, durationS}) {
  return {kind: LegKind.walk, fromStopId: from, toStopId: to, durationS}
}

const direct = {
  serviceDate: TODAY,
  arrivalS: seconds("09:14"),
  changes: 0,
  isEarliest: true,
  legs: [walk({from: "1_400", to: "1_7", durationS: WALK_SECONDS}), ride({routeId: "1_7", from: "1_7", departs: "08:46", to: "1_11920", arrives: "09:14"})],
  stopPositions: {},
}

const changing = {
  serviceDate: TODAY,
  arrivalS: seconds("09:02"),
  changes: 1,
  isEarliest: false,
  legs: [
    ride({routeId: "1_e", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51"}),
    walk({from: "1_1121", to: "1_1500", durationS: WALK_SECONDS}),
    ride({routeId: "1_36", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02"}),
  ],
  stopPositions: {},
}

const walkOnly = {
  serviceDate: TODAY,
  arrivalS: seconds("08:50"),
  changes: 0,
  isEarliest: false,
  legs: [{kind: LegKind.walkFromPosition, toStopId: "1_9", durationS: WALK_SECONDS}, {kind: LEG_KIND_TO_POINT, fromStopId: "1_9", durationS: WALK_SECONDS}],
  stopPositions: {},
  destination: {name: "Pike Place Market", lat: 47.6, lon: -122.3},
}

const tomorrowDirect = {...direct, serviceDate: TOMORROW}

const names = {
  stops: {"1_400": {name: "3rd Ave & Pike St"}, "1_7": {name: "3rd Ave & Pike St"}, "1_431": {name: "Pine St & 5th Ave"}, "1_1121": {name: "Westlake Hub"}, "1_1500": {name: "Westlake Stn"}, "1_11920": {name: "S Jackson St & 20th Pl S"}, "1_9": {name: "Pike Place Stop"}},
  routes: {"1_e": {name: "E", color: "#1D4ED8"}, "1_36": {name: "36", color: "#EA580C"}, "1_7": {name: "7", color: "#0F766E"}},
}
const NOW_MS = atMs("08:38")

function stripOf({journey, live}) {
  const [row] = journeyRows({journeys: [journey], nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
  const card = journeyCard({row, order: 0, live, nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
  return tripStrip({card, live, names, serviceDayStartsMs, timeZone: TIME_ZONE})
}

function lateArrival({tripId, scheduledClock}) {
  const scheduledMs = atMs(scheduledClock)
  return {route: "E", color: "#1D4ED8", headsign: "Aurora Village", minutes: 0, time_ms: scheduledMs + LATE_MINUTES * MINUTE_MS, predicted: true, trip_id: tripId, scheduled_ms: scheduledMs}
}

// A live first bus: the strip leads with the leave time moved by the
// lateness, reads the bus as late with the live dot, and names the first
// step, a walk to where the bus is boarded.
{
  const shownByStop = {"1_7": {stop_id: "1_7", status: "arrivals", age_minutes: 0, arrivals: [lateArrival({tripId: "trip-1_7", scheduledClock: "08:46"})]}}
  const live = firstRideLive({journey: direct, shownByStop, serviceDayStartsMs})
  const strip = stripOf({journey: direct, live})
  deepStrictEqual(strip.leadText, "Leave in 7 min")
  deepStrictEqual(strip.arriveText, "Arrive 9:16 am")
  deepStrictEqual(strip.statusText, "7 2 min late")
  deepStrictEqual(strip.isLive, true)
  deepStrictEqual(strip.firstStepText, "Walk to 3rd Ave & Pike St")
  deepStrictEqual(strip.nextStepTexts, ["Board 7 at 3rd Ave & Pike St, 8:48 am, 2 min late", "Arrive at S Jackson St & 20th Pl S"])
  deepStrictEqual(strip.sentence, "Trip: Leave in 7 min, Arrive 9:16 am. 7 2 min late. Walk to 3rd Ave & Pike St.")
  deepStrictEqual(strip.segments.length, 2)
}

// A scheduled first bus reads as scheduled, with no live dot and the
// schedule's times.
{
  const strip = stripOf({journey: direct, live: {kind: LiveKind.scheduled, routeId: "1_7"}})
  deepStrictEqual(strip.leadText, "Leave in 5 min")
  deepStrictEqual(strip.arriveText, "Arrive 9:14 am")
  deepStrictEqual(strip.statusText, "7 scheduled")
  deepStrictEqual(strip.isLive, false)
  deepStrictEqual(strip.nextStepTexts[0], "Board 7 at 3rd Ave & Pike St, 8:46 am")
}

// A journey that changes names its getting off and the walk between rides
// within the next two steps, and bounds the steps at two.
{
  const strip = stripOf({journey: changing, live: {kind: LiveKind.scheduled, routeId: "1_e"}})
  deepStrictEqual(strip.firstStepText, "Board E at Pine St & 5th Ave")
  deepStrictEqual(strip.nextStepTexts, ["Get off at Westlake Hub", "Walk 3 min to Westlake Stn"])
  deepStrictEqual(strip.nextStepTexts.length <= NEXT_STEP_COUNT_MAX, true)
}

// A journey that only walks has no bus: its status says so, and its steps
// are the walks and the arrival.
{
  const strip = stripOf({journey: walkOnly, live: {kind: LiveKind.noRide}})
  deepStrictEqual(strip.statusText, "Walk only")
  deepStrictEqual(strip.isLive, false)
  deepStrictEqual(strip.firstStepText, "Walk to Pike Place Stop")
  deepStrictEqual(strip.nextStepTexts, ["Walk 3 min to Pike Place Market", "Arrive at Pike Place Market"])
}

// A journey that leaves tomorrow leads with its day and clock time, which
// no countdown moves.
{
  const strip = stripOf({journey: tomorrowDirect, live: {kind: LiveKind.scheduled, routeId: "1_7"}})
  deepStrictEqual(strip.leadText, "Leave tomorrow at 8:43 am")
  deepStrictEqual(strip.arriveText, "Arrive 9:14 am")
  deepStrictEqual(strip.sentence.startsWith("Trip: Leave tomorrow at 8:43 am, Arrive 9:14 am."), true)
}

console.log("trip_strip_check: every case passed")
