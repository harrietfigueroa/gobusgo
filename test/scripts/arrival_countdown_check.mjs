// Checks how the page counts a stop's arrivals down between the server's
// events, as pure functions of arrivals and a clock written out by hand:
// the minutes, "now", and a passed arrival at a given time, the rounding of
// a part of a minute, and the most arrivals shown. Run it with
// `node test/scripts/arrival_countdown_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {ArrivalTimeKind, COUNTDOWN_INTERVAL_MS, arrivalTimeAt, shownAt} from "../../assets/js/arrival_countdown.js"
import {AssertionError} from "../../assets/js/assert.js"

const NOW_MS = 1_794_250_000_000
const FRACTIONAL_NOW_MS = 1_794_250_000_000.5
const MINUTE_MS = 60 * 1000
const LAST_SECOND_OF_MINUTE_MS = 59 * 1000
const THREE_MINUTES_MS = 3 * 60 * 1000
const TEN_MINUTES_MS = 10 * 60 * 1000
const SHORT_OF_THREE_MINUTES = 2

const timeCases = [
  {name: "an arrival at the time it is", timeMs: NOW_MS, expected: {kind: ArrivalTimeKind.now}},
  {name: "an arrival 59 seconds away", timeMs: NOW_MS + LAST_SECOND_OF_MINUTE_MS, expected: {kind: ArrivalTimeKind.now}},
  {name: "an arrival a minute away", timeMs: NOW_MS + MINUTE_MS, expected: {kind: ArrivalTimeKind.minutes, minutes: 1}},
  {
    name: "an arrival a millisecond short of three minutes",
    timeMs: NOW_MS + THREE_MINUTES_MS - 1,
    expected: {kind: ArrivalTimeKind.minutes, minutes: SHORT_OF_THREE_MINUTES}
  },
  {name: "an arrival a millisecond past", timeMs: NOW_MS - 1, expected: {kind: ArrivalTimeKind.passed}},
  {name: "an arrival ten minutes past", timeMs: NOW_MS - TEN_MINUTES_MS, expected: {kind: ArrivalTimeKind.passed}}
]

for (const {name, timeMs, expected} of timeCases) {
  deepStrictEqual(arrivalTimeAt({timeMs, nowMs: NOW_MS}), expected, name)
}

const invalidTimeCases = [
  {name: "a time that is no integer", timeMs: FRACTIONAL_NOW_MS, nowMs: NOW_MS},
  {name: "a missing time", timeMs: undefined, nowMs: NOW_MS},
  {name: "a clock that is no integer", timeMs: NOW_MS, nowMs: Number.NaN}
]

for (const {name, timeMs, nowMs} of invalidTimeCases) {
  throws(() => arrivalTimeAt({timeMs, nowMs}), AssertionError, name)
}

// Four arrivals as the server sends them, the soonest first, each with the
// minutes it had at NOW_MS: route 7 in 30 seconds, 70 in 2 minutes 10
// seconds, 36 in 5 minutes, and 4 in 9 minutes.
const FIRST_IN_MS = 30 * 1000
const SECOND_IN_MS = 130 * 1000
const THIRD_IN_MS = 5 * 60 * 1000
const FOURTH_IN_MS = 9 * 60 * 1000
const SECOND_MINUTES = 2
const THIRD_MINUTES = 5
const FOURTH_MINUTES = 9
const AFTER_FIRST_MS = 31 * 1000
const VIEW_COUNT_MAX = 8
const TAB_COUNT_MAX = 3

function arrival({route, inMs, predicted}) {
  return {route, headsign: "Downtown", minutes: Math.floor(inMs / MINUTE_MS), time_ms: NOW_MS + inMs, predicted}
}

const arrivals = [
  arrival({route: "7", inMs: FIRST_IN_MS, predicted: true}),
  arrival({route: "70", inMs: SECOND_IN_MS, predicted: true}),
  arrival({route: "36", inMs: THIRD_IN_MS, predicted: false}),
  arrival({route: "4", inMs: FOURTH_IN_MS, predicted: true})
]
const shown = {stop_id: "1_430", status: "arrivals", age_minutes: 0, arrivals}

function routeAndMinutes({route, minutes}) {
  return [route, minutes]
}

function routesAndMinutes(counted) {
  return Array.from(counted.arrivals, routeAndMinutes)
}

const atEvent = [["7", 0], ["70", SECOND_MINUTES], ["36", THIRD_MINUTES], ["4", FOURTH_MINUTES]]
const aMinuteSooner = [["70", SECOND_MINUTES - 1], ["36", THIRD_MINUTES - 1], ["4", FOURTH_MINUTES - 1]]

const countdownCases = [
  {name: "at the time of the event", elapsedMs: 0, countMax: VIEW_COUNT_MAX, expected: atEvent},
  {name: "a tick later", elapsedMs: COUNTDOWN_INTERVAL_MS, countMax: VIEW_COUNT_MAX, expected: [["7", 0], ...aMinuteSooner]},
  {name: "after the first has passed", elapsedMs: AFTER_FIRST_MS, countMax: VIEW_COUNT_MAX, expected: aMinuteSooner},
  {name: "the most a list shows", elapsedMs: 0, countMax: TAB_COUNT_MAX, expected: atEvent.slice(0, TAB_COUNT_MAX)},
  {name: "the most a list shows once one has passed", elapsedMs: AFTER_FIRST_MS, countMax: TAB_COUNT_MAX, expected: aMinuteSooner},
  {name: "after every arrival has passed", elapsedMs: TEN_MINUTES_MS, countMax: VIEW_COUNT_MAX, expected: []}
]

for (const {name, elapsedMs, countMax, expected} of countdownCases) {
  const counted = shownAt({shown, nowMs: NOW_MS + elapsedMs, countMax})
  deepStrictEqual(routesAndMinutes(counted), expected, name)
}

const kept = shownAt({shown, nowMs: NOW_MS + MINUTE_MS, countMax: VIEW_COUNT_MAX})
deepStrictEqual(kept.arrivals[0], {...arrivals[1], minutes: 1}, "keeps an arrival's route, headsign, time, and kind")
deepStrictEqual({...kept, arrivals: []}, {...shown, arrivals: []}, "keeps the stop, the status, and the fetch's age")
deepStrictEqual(shown.arrivals, arrivals, "leaves the arrivals it is given unchanged")
const KEPT_CASE_COUNT = 3

const otherShownCases = [
  {name: "waiting", shown: {stop_id: "1_430", status: "waiting"}},
  {name: "refused", shown: {stop_id: "1_430", status: "refused"}},
  {name: "busy", shown: {stop_id: "1_430", status: "busy"}}
]

for (const {name, shown: other} of otherShownCases) {
  deepStrictEqual(shownAt({shown: other, nowMs: NOW_MS, countMax: TAB_COUNT_MAX}), other, name)
}

const FRACTIONAL_COUNT_MAX = 1.5

const invalidCountCases = [
  {name: "no arrival", countMax: 0},
  {name: "a part of an arrival", countMax: FRACTIONAL_COUNT_MAX}
]

for (const {name, countMax} of invalidCountCases) {
  throws(() => shownAt({shown, nowMs: NOW_MS, countMax}), AssertionError, name)
}

const caseCount = timeCases.length + invalidTimeCases.length + countdownCases.length + KEPT_CASE_COUNT + otherShownCases.length + invalidCountCases.length
console.log(`${caseCount} arrival countdown cases passed`)
