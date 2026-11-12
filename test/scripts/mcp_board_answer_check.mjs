// Checks what the arrivals board reads from the answers of the `arrivals`
// tool, as pure functions of a tool result written out by hand: each status,
// a result the tool flagged as an error, a result that is no answer, the
// arrivals as the page's rows take them, the stop's name kept across answers
// that carry none, the arrivals kept across answers that carry none, and the
// texts of the status line and the fetch time. Run it with
// `node test/scripts/mcp_board_answer_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {OutcomeKind} from "../../assets/js/mcp_host.js"
import {AnswerKind, InputStopKind, answerOf, answerOfOutcome, boardAfter, fetchedText, inputStopOf, shownOf, statusText} from "../../assets/js/mcp_board_answer.js"

const FETCHED_AT = "2026-11-11T23:04:00Z"
const FETCHED_AT_MS = Date.parse(FETCHED_AT)
const MINUTE_MS = 60 * 1000
const SOON_MINUTES = 4
const LATER_MINUTES = 14
const SOON_MS = FETCHED_AT_MS + SOON_MINUTES * MINUTE_MS
const LATER_MS = FETCHED_AT_MS + LATER_MINUTES * MINUTE_MS
const COUNT_MAX = 100
const RETRY_AFTER_SECONDS = 5

function minutesOf(arrival) {
  return arrival.minutes
}

function timeMsOf(arrival) {
  return arrival.time_ms
}

function arrivalJson({route, minutes, time, predicted}) {
  return {route, color: "#336699", headsign: "Capitol Hill", minutes, time, predicted, tripId: "1_trip", scheduledTime: time}
}

function resultOf(data, fetchedAt) {
  return {content: [{type: "text", text: "{}"}], structuredContent: {data, meta: {fetchedAt, requestId: "r", count: 0}}}
}

const SOON = arrivalJson({route: "8", minutes: 4, time: new Date(SOON_MS).toISOString(), predicted: true})
const LATER = arrivalJson({route: null, minutes: 14, time: new Date(LATER_MS).toISOString(), predicted: false})

const arrivalsResult = resultOf({status: "arrivals", stopId: "1_1", stopName: "Westlake Station", arrivals: [SOON, LATER]}, FETCHED_AT)
const arrivalsAnswer = answerOf(arrivalsResult)

deepStrictEqual(
  arrivalsAnswer,
  {
    kind: AnswerKind.arrivals,
    stopId: "1_1",
    stopName: "Westlake Station",
    fetchedAtMs: FETCHED_AT_MS,
    arrivals: [
      {route: "8", color: "#336699", headsign: "Capitol Hill", minutes: 4, time_ms: SOON_MS, predicted: true},
      {route: null, color: "#336699", headsign: "Capitol Hill", minutes: 14, time_ms: LATER_MS, predicted: false}
    ]
  },
  "an arrivals answer"
)

const answerCases = [
  {
    name: "an arrivals answer with no stop name",
    result: resultOf({status: "arrivals", stopId: "1_1", arrivals: []}, FETCHED_AT),
    expected: {kind: AnswerKind.arrivals, stopId: "1_1", stopName: null, fetchedAtMs: FETCHED_AT_MS, arrivals: []}
  },
  {
    name: "a fetching answer",
    result: resultOf({status: "fetching", stopId: "1_1", retryAfterSeconds: RETRY_AFTER_SECONDS}, null),
    expected: {kind: AnswerKind.fetching, stopId: "1_1", retryAfterSeconds: RETRY_AFTER_SECONDS}
  },
  {
    name: "a capacity_reached answer",
    result: resultOf({status: "capacity_reached", stopId: "1_1", retryAfterSeconds: 60}, null),
    expected: {kind: AnswerKind.capacityReached, stopId: "1_1", retryAfterSeconds: 60}
  },
  {
    name: "an unknown_stop answer",
    result: resultOf({status: "unknown_stop", stopId: "9_9"}, null),
    expected: {kind: AnswerKind.unknownStop, stopId: "9_9"}
  },
  {
    name: "a result flagged as an error",
    result: {isError: true, content: [{type: "text", text: "The demand registry is not answering."}]},
    expected: {kind: AnswerKind.refused, text: "The demand registry is not answering."}
  },
  {name: "a result flagged as an error with no text", result: {isError: true, content: []}, expected: {kind: AnswerKind.refused, text: ""}},
  {name: "a result with no structured content", result: {content: []}, expected: {kind: AnswerKind.invalid}},
  {name: "no result", result: undefined, expected: {kind: AnswerKind.invalid}},
  {name: "an unknown status", result: resultOf({status: "lost", stopId: "1_1"}, null), expected: {kind: AnswerKind.invalid}},
  {name: "a fetching answer with no wait", result: resultOf({status: "fetching", stopId: "1_1"}, null), expected: {kind: AnswerKind.invalid}},
  {name: "a fetching answer with a fractional wait", result: resultOf({status: "fetching", stopId: "1_1", retryAfterSeconds: 1.5}, null), expected: {kind: AnswerKind.invalid}},
  {name: "an arrivals answer with no fetch time", result: resultOf({status: "arrivals", stopId: "1_1", arrivals: []}, null), expected: {kind: AnswerKind.invalid}},
  {name: "an arrivals answer with a time that is no instant", result: resultOf({status: "arrivals", stopId: "1_1", arrivals: [{...SOON, time: "soon"}]}, FETCHED_AT), expected: {kind: AnswerKind.invalid}},
  {name: "an arrivals answer whose arrival has no minutes", result: resultOf({status: "arrivals", stopId: "1_1", arrivals: [{...SOON, minutes: undefined}]}, FETCHED_AT), expected: {kind: AnswerKind.invalid}},
  {name: "an arrivals answer with no stop", result: resultOf({status: "arrivals", arrivals: []}, FETCHED_AT), expected: {kind: AnswerKind.invalid}}
]

for (const {name, result, expected} of answerCases) {
  deepStrictEqual(answerOf(result), expected, name)
}

// The stop the tool's arguments name.
deepStrictEqual(inputStopOf({arguments: {stopId: "1_1"}}), {kind: InputStopKind.found, stopId: "1_1"}, "a stop in the arguments")
deepStrictEqual(inputStopOf({arguments: {stopId: ""}}), {kind: InputStopKind.missing}, "an empty stop")
deepStrictEqual(inputStopOf({arguments: {stopId: 7}}), {kind: InputStopKind.missing}, "a stop that is no text")
deepStrictEqual(inputStopOf({arguments: {}}), {kind: InputStopKind.missing}, "no stop")
deepStrictEqual(inputStopOf({}), {kind: InputStopKind.missing}, "no arguments")
deepStrictEqual(inputStopOf(undefined), {kind: InputStopKind.missing}, "no params")

// A call through the host ends in the tool's result, or in the host's refusal or timeout.
deepStrictEqual(answerOfOutcome({kind: OutcomeKind.answered, result: arrivalsResult}), arrivalsAnswer, "an answered call")
deepStrictEqual(answerOfOutcome({kind: OutcomeKind.refused, message: "no"}), {kind: AnswerKind.refused, text: ""}, "a refused call")
deepStrictEqual(answerOfOutcome({kind: OutcomeKind.timedOut}), {kind: AnswerKind.refused, text: ""}, "a call that timed out")

// The rows the page draws, counted from the clock, with a passed arrival gone.
const shownBefore = shownOf({answer: arrivalsAnswer, nowMs: FETCHED_AT_MS + MINUTE_MS, countMax: COUNT_MAX})
deepStrictEqual(shownBefore.status, "arrivals", "the shown status")
deepStrictEqual(shownBefore.age_minutes, 1, "the age of the fetch")
const minutesShown = Array.from(shownBefore.arrivals, minutesOf)
deepStrictEqual(minutesShown, [SOON_MINUTES - 1, LATER_MINUTES - 1], "the minutes counted from the clock")

const shownAfter = shownOf({answer: arrivalsAnswer, nowMs: SOON_MS + MINUTE_MS, countMax: COUNT_MAX})
const timesShown = Array.from(shownAfter.arrivals, timeMsOf)
deepStrictEqual(timesShown, [LATER_MS], "an arrival that has passed leaves the rows")

// The board keeps the stop's name and the last arrivals across answers that carry neither.
const fetching = answerOf(resultOf({status: "fetching", stopId: "1_1", retryAfterSeconds: RETRY_AFTER_SECONDS}, null))
const unknown = answerOf(resultOf({status: "unknown_stop", stopId: "1_1"}, null))
const refresh = answerOf(resultOf({status: "arrivals", stopId: "1_1", arrivals: [SOON]}, FETCHED_AT))
const first = boardAfter({board: {stopName: null, arrivals: null, latest: null}, answer: arrivalsAnswer})
deepStrictEqual(first, {stopName: "Westlake Station", arrivals: arrivalsAnswer, latest: arrivalsAnswer}, "the first answer")

const kept = boardAfter({board: first, answer: fetching})
deepStrictEqual(kept, {stopName: "Westlake Station", arrivals: arrivalsAnswer, latest: fetching}, "a fetching answer keeps the arrivals")

const refreshed = boardAfter({board: kept, answer: refresh})
deepStrictEqual(refreshed, {stopName: "Westlake Station", arrivals: refresh, latest: refresh}, "a refresh with no name keeps the name")

const cleared = boardAfter({board: refreshed, answer: unknown})
deepStrictEqual(cleared, {stopName: "Westlake Station", arrivals: null, latest: unknown}, "an unknown stop leaves no arrivals")

// The status line.
const statusCases = [
  {name: "arrivals", answer: arrivalsAnswer, isRefreshing: true, expected: ""},
  {name: "fetching while refreshing", answer: fetching, isRefreshing: true, expected: "Fetching this stop's arrivals. Trying again in 5 seconds."},
  {name: "fetching with no refresh", answer: fetching, isRefreshing: false, expected: "This stop's arrivals are being fetched. Ask again in 5 seconds."},
  {
    name: "one second",
    answer: {kind: AnswerKind.fetching, stopId: "1_1", retryAfterSeconds: 1},
    isRefreshing: true,
    expected: "Fetching this stop's arrivals. Trying again in 1 second."
  },
  {
    name: "capacity_reached while refreshing",
    answer: {kind: AnswerKind.capacityReached, stopId: "1_1", retryAfterSeconds: 60},
    isRefreshing: true,
    expected: "Too many stops are held to show this one. Trying again in 60 seconds."
  },
  {
    name: "capacity_reached with no refresh",
    answer: {kind: AnswerKind.capacityReached, stopId: "1_1", retryAfterSeconds: 60},
    isRefreshing: false,
    expected: "Too many stops are held to show this one. Ask again in 60 seconds."
  },
  {name: "an unknown stop", answer: unknown, isRefreshing: true, expected: "This stop is not known."},
  {name: "a refusal while refreshing", answer: {kind: AnswerKind.refused, text: ""}, isRefreshing: true, expected: "The arrivals could not be fetched. Trying again soon."},
  {name: "a refusal with no refresh", answer: {kind: AnswerKind.refused, text: ""}, isRefreshing: false, expected: "The arrivals could not be fetched."},
  {name: "an answer that is none", answer: {kind: AnswerKind.invalid}, isRefreshing: true, expected: "The arrivals could not be fetched. Trying again soon."}
]

for (const {name, answer, isRefreshing, expected} of statusCases) {
  deepStrictEqual(statusText({answer, isRefreshing}), expected, "the status line of " + name)
}

// The fetch time on the rider's clock.
deepStrictEqual(fetchedText({fetchedAtMs: FETCHED_AT_MS, timeZone: "America/Los_Angeles"}), "Fetched at 3:04 PM", "the fetch time in Pacific time")
deepStrictEqual(fetchedText({fetchedAtMs: FETCHED_AT_MS, timeZone: "UTC"}), "Fetched at 11:04 PM", "the fetch time in UTC")

console.log("mcp_board_answer_check: all cases passed")
