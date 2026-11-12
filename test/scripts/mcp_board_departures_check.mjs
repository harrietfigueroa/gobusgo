// Checks what the arrivals board shows of a list of scheduled departures, as
// pure functions of values written out by hand: the instant the time asked
// for names, the rows with their clock times, their days, and the note on a
// departure within the live window, the line that says what the list is from,
// and the status line of each way a read ends. Run it with
// `node test/scripts/mcp_board_departures_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {ARRIVAL_HORIZON_SECONDS} from "../../assets/js/scheduled_service.js"
import {DepartureLoadKind} from "../../assets/js/departure_files.js"
import {
  FromKind,
  LIVE_NOTE,
  departureRows,
  fromMsOf,
  fromText,
  isInLiveWindow,
  loadStatusText,
  refusalText
} from "../../assets/js/mcp_board_departures.js"

const TIME_ZONE = "America/Los_Angeles"
const SECOND_MS = 1000
const LIVE_WINDOW_EXPECTED_MS = 35 * 60 * 1000
const SOON_OFFSET_MS = 10 * 60 * 1000
const LATER_OFFSET_MS = 2 * 60 * 60 * 1000
const LIVE_WINDOW_MS = ARRIVAL_HORIZON_SECONDS * SECOND_MS

// Sunday 2026-11-08 at 20:00 in Seattle, which is Monday 04:00 UTC, so the clock is on Pacific standard time.
const NOW_MS = Date.parse("2026-11-09T04:00:00Z")
const TODAY_2300_MS = Date.parse("2026-11-09T07:00:00Z")
const TOMORROW_0500_MS = Date.parse("2026-11-09T13:00:00Z")

deepStrictEqual(LIVE_WINDOW_MS, LIVE_WINDOW_EXPECTED_MS, "the live window is the one arrivals answers")

function fromOf(when) {
  return fromMsOf({when, nowMs: NOW_MS, timeZone: TIME_ZONE})
}

const fromCases = [
  {name: "leaving now is the clock's instant", when: {mode: "now", day: "today", clockText: ""}, expected: {kind: FromKind.found, ms: NOW_MS}},
  {name: "a time today", when: {mode: "departAt", day: "today", clockText: "23:00"}, expected: {kind: FromKind.found, ms: TODAY_2300_MS}},
  {name: "a time tomorrow", when: {mode: "departAt", day: "tomorrow", clockText: "05:00"}, expected: {kind: FromKind.found, ms: TOMORROW_0500_MS}},
  {name: "a mode the board does not take, such as a time to arrive by, is refused", when: {mode: "arriveBy", day: "today", clockText: "23:00"}, expected: {kind: FromKind.invalid}},
  {name: "a mode of no kind is refused", when: {mode: "teleport", day: "today", clockText: "23:00"}, expected: {kind: FromKind.invalid}},
  {name: "a clock that is none", when: {mode: "departAt", day: "today", clockText: "25:99"}, expected: {kind: FromKind.invalid}}
]

for (const {name, when, expected} of fromCases) {
  deepStrictEqual(fromOf(when), expected, name)
}

// The live window runs from now to the horizon, both ends in.
const windowCases = [
  [NOW_MS - SECOND_MS, false, "a departure that has gone is outside the window"],
  [NOW_MS, true, "a departure now is inside"],
  [NOW_MS + LIVE_WINDOW_MS, true, "a departure at the horizon is inside"],
  [NOW_MS + LIVE_WINDOW_MS + SECOND_MS, false, "a departure past the horizon is outside"]
]

for (const [timeMs, expected, message] of windowCases) {
  deepStrictEqual(isInLiveWindow({timeMs, nowMs: NOW_MS}), expected, message)
}

function departure({timeMs, route = "44", color = "#112233", headsign = "Ballard"}) {
  return {timeMs, tripId: `trip-${timeMs}`, routeId: `1_${route}`, route, color, headsign}
}

const SOON = departure({timeMs: NOW_MS + SOON_OFFSET_MS})
const TONIGHT = departure({timeMs: TODAY_2300_MS, headsign: "Montlake"})
const NEXT_MORNING = departure({timeMs: TOMORROW_0500_MS, route: "8", color: null, headsign: null})

const rows = departureRows({departures: [SOON, TONIGHT, NEXT_MORNING], fromMs: NOW_MS, nowMs: NOW_MS, timeZone: TIME_ZONE})

deepStrictEqual(
  rows,
  [
    {key: `${SOON.tripId}/${SOON.timeMs}`, time: "8:10 pm", day: "", route: "44", color: "#112233", headsign: "Ballard", note: LIVE_NOTE},
    {key: `${TONIGHT.tripId}/${TONIGHT.timeMs}`, time: "11:00 pm", day: "", route: "44", color: "#112233", headsign: "Montlake", note: ""},
    {key: `${NEXT_MORNING.tripId}/${NEXT_MORNING.timeMs}`, time: "5:00 am", day: "Mon", route: "8", color: null, headsign: null, note: ""}
  ],
  "a row's clock time on the rider's clock, its day where it is not the day the list starts, and a note only within the live window"
)

const laterRows = departureRows({departures: [SOON], fromMs: NOW_MS + LATER_OFFSET_MS, nowMs: NOW_MS, timeZone: TIME_ZONE})
deepStrictEqual(laterRows[0].note, LIVE_NOTE, "the live window counts from now, not from the time asked for")

// The line under the heading says what the list is from, with the day where it is not today.
const fromTextCases = [
  [NOW_MS, "Scheduled departures from 8:00 pm"],
  [TODAY_2300_MS, "Scheduled departures from 11:00 pm"],
  [TOMORROW_0500_MS, "Scheduled departures from 5:00 am on Mon"]
]

for (const [fromMs, expected] of fromTextCases) {
  deepStrictEqual(fromText({fromMs, nowMs: NOW_MS, timeZone: TIME_ZONE}), expected, `from ${expected}`)
}

const loadCases = [
  {name: "a list", loaded: {kind: DepartureLoadKind.listed, stopName: "Pine", departures: [SOON], isBounded: false}, expected: ""},
  {name: "a list at the bound", loaded: {kind: DepartureLoadKind.listed, stopName: "Pine", departures: [SOON, TONIGHT], isBounded: true}, expected: "The list stops at 2 departures. Ask your assistant for a later time to see more."},
  {name: "a list of none", loaded: {kind: DepartureLoadKind.listed, stopName: "Pine", departures: [], isBounded: false}, expected: "No scheduled departures from this time."},
  {name: "a date no snapshot holds", loaded: {kind: DepartureLoadKind.noSchedule}, expected: "The schedules do not hold that day."},
  {name: "a stop no snapshot holds", loaded: {kind: DepartureLoadKind.unknownStop}, expected: "This stop is not in the schedules."},
  {name: "a read that failed", loaded: {kind: DepartureLoadKind.failed, reason: "fetchFailed", path: "/routing/x"}, expected: "The schedules could not be read. Ask your assistant to show the board again."}
]

for (const {name, loaded, expected} of loadCases) {
  deepStrictEqual(loadStatusText(loaded), expected, name)
}

deepStrictEqual(refusalText("when"), "The time asked for is not one the board can show.", "a refused time")
deepStrictEqual(refusalText("route"), "The routes asked for are not ones the board can show.", "refused routes")
console.log("mcp board departures: every case passed")
