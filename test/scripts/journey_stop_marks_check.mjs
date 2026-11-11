// Checks what a stop's details view says of the chosen journey as pure
// functions of a journey written out by hand in the router's shape: the
// boarding stop of the first ride, the boarding stop of a later ride, a
// stop where a ride ends, a stop a ride passes without stopping there, and
// a stop the journey does not use, with the line's text; and which arrival
// row is the first ride's trip: a matching trip and time, the same trip at
// another time, another trip at the same time, an arrival within the
// tolerance, and an arrival list without the trip. Run it with
// `node test/scripts/journey_stop_marks_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {LegKind} from "../../assets/js/routing_engine.js"
import {StopMarkKind, YourBusKind, stopMark, yourBusRow} from "../../assets/js/journey_stop_marks.js"
import {LiveKind} from "../../assets/js/journey_cards.js"

const TIME_ZONE = "America/Los_Angeles"
const TODAY = "2026-11-08"
// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const TODAY_START_MS = 1794124800000
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS}
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const SECOND_MS = 1000
const MINUTE_MS = 60 * 1000
const WALK_SECONDS = 170
const LATE_MINUTES = 2
const TOLERANCE_MINUTES = 5
const BEYOND_TOLERANCE_MINUTES = 6

function seconds(clock) {
  const [hours, minutes] = clock.split(":")
  return Number(hours) * HOUR_SECONDS + Number(minutes) * MINUTE_SECONDS
}

function atMs(clock) {
  return TODAY_START_MS + seconds(clock) * SECOND_MS
}

function ride({routeId, from, departs, to, arrives, stopIds}) {
  return {kind: LegKind.ride, tripId: `trip-${routeId}`, routeId, serviceDayOffset: 0, fromStopId: from, departureS: seconds(departs), toStopId: to, arrivalS: seconds(arrives), stopIds}
}

const journey = {
  serviceDate: TODAY,
  arrivalS: seconds("09:02"),
  changes: 1,
  isEarliest: false,
  legs: [
    {kind: LegKind.walk, fromStopId: "1_start", toStopId: "1_431", durationS: WALK_SECONDS},
    ride({routeId: "1_e", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51", stopIds: ["1_431", "1_500", "1_1121"]}),
    {kind: LegKind.walk, fromStopId: "1_1121", toStopId: "1_1500", durationS: WALK_SECONDS},
    ride({routeId: "1_36", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02", stopIds: ["1_1500", "1_11920"]}),
  ],
  stopPositions: {},
}

const SCHEDULED = {kind: LiveKind.scheduled, routeId: "1_e"}
const chosen = {journey, live: SCHEDULED, leadText: "Leave in 4 min", arriveText: "Arrive 9:02 am", serviceDayStartsMs, timeZone: TIME_ZONE}

// The first ride's boarding stop says the trip boards there, with when to
// leave and the arrival, and names the trip and time its bus is found by.
deepStrictEqual(stopMark({chosen, stopId: "1_431"}), {
  kind: StopMarkKind.boardsFirst,
  text: "Your trip boards here · Leave in 4 min · Arrive 9:02 am",
  tripId: "trip-1_e",
  departureMs: atMs("08:42"),
})

// A later ride's boarding stop says when that ride leaves, and names no bus.
deepStrictEqual(stopMark({chosen, stopId: "1_1500"}), {kind: StopMarkKind.boards, text: "Your trip boards here · 8:56 am"})

// A stop where a ride ends says when the ride gets there.
deepStrictEqual(stopMark({chosen, stopId: "1_1121"}), {kind: StopMarkKind.getsOff, text: "Your trip gets off here · 8:51 am"})
deepStrictEqual(stopMark({chosen, stopId: "1_11920"}), {kind: StopMarkKind.getsOff, text: "Your trip gets off here · 9:02 am"})

// A stop a ride passes without stopping there, a stop only walked to, and a
// stop the journey does not use say nothing.
for (const stopId of ["1_500", "1_start", "1_other"]) {
  deepStrictEqual(stopMark({chosen, stopId}), {kind: StopMarkKind.none}, stopId)
}

// A stop where one ride ends and the next begins says it boards.
// Where the first ride's bus is live, the time it gets off moves by the
// bus's lateness, as the strip moves the times it writes; the second ride's
// time stays scheduled, and a bus that runs early moves it earlier.
{
  const lateChosen = {...chosen, live: {kind: LiveKind.live, latenessS: LATE_MINUTES * MINUTE_SECONDS, routeId: "1_e"}}
  deepStrictEqual(stopMark({chosen: lateChosen, stopId: "1_1121"}), {kind: StopMarkKind.getsOff, text: "Your trip gets off here · 8:53 am"})
  deepStrictEqual(stopMark({chosen: lateChosen, stopId: "1_11920"}), {kind: StopMarkKind.getsOff, text: "Your trip gets off here · 9:02 am"})
  const earlyChosen = {...chosen, live: {kind: LiveKind.live, latenessS: -MINUTE_SECONDS, routeId: "1_e"}}
  deepStrictEqual(stopMark({chosen: earlyChosen, stopId: "1_1121"}), {kind: StopMarkKind.getsOff, text: "Your trip gets off here · 8:50 am"})
}

// A stop where one ride ends and the next begins says it boards.
{
  const transfer = {...journey, legs: [journey.legs[1], ride({routeId: "1_36", from: "1_1121", departs: "08:55", to: "1_11920", arrives: "09:02", stopIds: ["1_1121", "1_11920"]})]}
  const mark = stopMark({chosen: {...chosen, journey: transfer}, stopId: "1_1121"})
  deepStrictEqual(mark, {kind: StopMarkKind.boards, text: "Your trip boards here · 8:55 am"})
}

// No journey says nothing at any stop.
deepStrictEqual(stopMark({chosen: {...chosen, journey: {...journey, legs: [journey.legs[0]]}}, stopId: "1_431"}), {kind: StopMarkKind.none})

function arrival({tripId, scheduledMs}) {
  return {route: "E", color: "#1D4ED8", headsign: "Aurora Village", minutes: 3, time_ms: scheduledMs, predicted: false, trip_id: tripId, scheduled_ms: scheduledMs}
}

const boardsFirst = stopMark({chosen, stopId: "1_431"})
const other = arrival({tripId: "trip-other", scheduledMs: atMs("08:42")})
const mine = arrival({tripId: "trip-1_e", scheduledMs: atMs("08:42")})
function arrivals(list) {
  return {stop_id: "1_431", status: "arrivals", age_minutes: 0, arrivals: list}
}

// The row of the first ride's trip is found by its trip and its time, a
// scheduled arrival as well as a predicted one.
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: arrivals([other, mine])}), {kind: YourBusKind.row, index: 1})
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: arrivals([{...mine, predicted: true, time_ms: mine.time_ms + LATE_MINUTES * MINUTE_MS}])}), {kind: YourBusKind.row, index: 0})

// An arrival within the tolerance of the ride's departure is the ride; one
// beyond it, another run of the same trip, is not.
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: arrivals([arrival({tripId: "trip-1_e", scheduledMs: atMs("08:42") + TOLERANCE_MINUTES * MINUTE_MS})])}), {kind: YourBusKind.row, index: 0})
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: arrivals([arrival({tripId: "trip-1_e", scheduledMs: atMs("08:42") + BEYOND_TOLERANCE_MINUTES * MINUTE_MS})])}), {kind: YourBusKind.absent})

// A list without the trip, an empty list, an answer that is not arrivals, and
// a mark that names no bus have no row.
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: arrivals([other])}), {kind: YourBusKind.absent})
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: arrivals([])}), {kind: YourBusKind.absent})
deepStrictEqual(yourBusRow({mark: boardsFirst, shown: {stop_id: "1_431", status: "waiting"}}), {kind: YourBusKind.absent})
deepStrictEqual(yourBusRow({mark: stopMark({chosen, stopId: "1_1500"}), shown: arrivals([mine])}), {kind: YourBusKind.absent})
deepStrictEqual(yourBusRow({mark: {kind: StopMarkKind.none}, shown: arrivals([mine])}), {kind: YourBusKind.absent})

console.log("journey_stop_marks_check: every case passed")
