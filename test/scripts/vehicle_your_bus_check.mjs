// Checks what a vehicle's details view says of the chosen journey as pure
// functions of a journey written out by hand in the router's shape: the
// vehicle of the first ride's trip and service date gets the line with the
// boarding stop and the time moved by the bus's lateness, and the vehicle
// of a later ride, of another trip of the same route, of another service
// date, and any vehicle while no journey is chosen get none. Run it with
// `node test/scripts/vehicle_your_bus_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {LegKind} from "../../assets/js/routing_engine.js"
import {ChosenKind} from "../../assets/js/chosen_journey.js"
import {LiveKind} from "../../assets/js/journey_cards.js"
import {YourBusLineKind, vehicleYourBusLine} from "../../assets/js/vehicle_your_bus.js"

const TIME_ZONE = "America/Los_Angeles"
const TODAY = "2026-11-08"
// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const TODAY_START_MS = 1794124800000
const DAY_MS = 86400000
const YESTERDAY_START_MS = TODAY_START_MS - DAY_MS
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS}
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const SECOND_MS = 1000
const MINUTE_MS = 60 * 1000
const LATE_MINUTES = 2

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

const journey = {
  serviceDate: TODAY,
  arrivalS: seconds("09:02"),
  changes: 1,
  isEarliest: false,
  legs: [
    {kind: LegKind.walk, fromStopId: "1_start", toStopId: "1_431", durationS: 170},
    ride({routeId: "1_e", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51"}),
    {kind: LegKind.walk, fromStopId: "1_1121", toStopId: "1_1500", durationS: 170},
    ride({routeId: "1_36", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02"}),
  ],
  stopPositions: {},
}

const names = {stops: {"1_431": {name: "8th Ave NW & NW 97th St"}}, routes: {}}
const SCHEDULED = {kind: LiveKind.scheduled, routeId: "1_e"}
const chosen = {kind: ChosenKind.journey, journey, live: SCHEDULED, leadText: "Leave in 4 min", arriveText: "arrive 9:02 am", serviceDayStartsMs, timeZone: TIME_ZONE, names, origin: null, nowMs: atMs("08:38")}
const NONE = {kind: YourBusLineKind.none}

// The first ride's vehicle, by trip and service date, says so with the
// boarding stop and the scheduled time.
deepStrictEqual(vehicleYourBusLine({chosen, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}), {
  kind: YourBusLineKind.line,
  text: "Your bus · Board at 8th Ave NW & NW 97th St · 8:42 am",
})

// A later ride's vehicle, another trip of the same route, and another
// service date are not the first bus.
deepStrictEqual(vehicleYourBusLine({chosen, tripId: "trip-1_36", serviceDateMs: TODAY_START_MS}), NONE)
deepStrictEqual(vehicleYourBusLine({chosen, tripId: "trip-1_e-later", serviceDateMs: TODAY_START_MS}), NONE)
deepStrictEqual(vehicleYourBusLine({chosen, tripId: "trip-1_e", serviceDateMs: YESTERDAY_START_MS}), NONE)

// No journey chosen says nothing.
deepStrictEqual(vehicleYourBusLine({chosen: {kind: ChosenKind.none}, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}), NONE)

// A bus running late moves the boarding time as it moves the strip's times,
// and one running early moves it earlier.
{
  const late = {...chosen, live: {kind: LiveKind.live, latenessS: LATE_MINUTES * MINUTE_SECONDS, routeId: "1_e"}}
  deepStrictEqual(vehicleYourBusLine({chosen: late, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}).text, "Your bus · Board at 8th Ave NW & NW 97th St · 8:44 am")
  const early = {...chosen, live: {kind: LiveKind.live, latenessS: -MINUTE_SECONDS, routeId: "1_e"}}
  deepStrictEqual(vehicleYourBusLine({chosen: early, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}).text, "Your bus · Board at 8th Ave NW & NW 97th St · 8:41 am")
}

// A stop the page has not named reads by its identifier.
deepStrictEqual(
  vehicleYourBusLine({chosen: {...chosen, names: {stops: {}, routes: {}}}, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}).text,
  "Your bus · Board at 1_431 · 8:42 am",
)

// A bus past its boarding stop gets none, as the map's label does.
deepStrictEqual(vehicleYourBusLine({chosen: {...chosen, nowMs: atMs("08:42") + MINUTE_MS}, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}), NONE)

// A journey that only walks has no first bus.
deepStrictEqual(vehicleYourBusLine({chosen: {...chosen, journey: {...journey, legs: [journey.legs[0]]}}, tripId: "trip-1_e", serviceDateMs: TODAY_START_MS}), NONE)

console.log("vehicle_your_bus_check: ok")
