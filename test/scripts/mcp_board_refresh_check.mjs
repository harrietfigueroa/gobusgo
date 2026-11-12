// Checks when the arrivals board asks for its arrivals again, as pure
// functions of the answer it holds and a clock written out by hand: the
// interval floor, the wait the tool gives, the interval of the arrival
// source, no request while the document is hidden, the request that is due
// on showing it again, the lifetime after which the board stops, and a stop
// the server does not know. Run it with
// `node test/scripts/mcp_board_refresh_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {AnswerKind} from "../../assets/js/mcp_board_answer.js"
import {ARRIVAL_SOURCE_INTERVAL_MS, BOARD_LIFETIME_MS, REFRESH_INTERVAL_MS_MIN, StepKind, expiredText, refreshIntervalMs, stepOf} from "../../assets/js/mcp_board_refresh.js"

const OPENED_AT_MS = 1_794_250_000_000
const SECOND_MS = 1000
const arrivals = {kind: AnswerKind.arrivals, stopId: "1_1", stopName: null, fetchedAtMs: OPENED_AT_MS, arrivals: []}

function fetching(retryAfterSeconds) {
  return {kind: AnswerKind.fetching, stopId: "1_1", retryAfterSeconds}
}

function capacity(retryAfterSeconds) {
  return {kind: AnswerKind.capacityReached, stopId: "1_1", retryAfterSeconds}
}

// The interval never goes under the floor, and the answer's wait sets it above.
deepStrictEqual(REFRESH_INTERVAL_MS_MIN > ARRIVAL_SOURCE_INTERVAL_MS, true, "the floor is above the source's interval, so an arrivals answer waits the floor")
deepStrictEqual(refreshIntervalMs(arrivals), REFRESH_INTERVAL_MS_MIN, "an arrivals answer")
deepStrictEqual(refreshIntervalMs(fetching(5)), REFRESH_INTERVAL_MS_MIN, "a wait under the floor")
deepStrictEqual(refreshIntervalMs(fetching(30)), 30 * SECOND_MS, "a wait over the floor")
deepStrictEqual(refreshIntervalMs(capacity(60)), 60 * SECOND_MS, "a capacity_reached wait")
deepStrictEqual(refreshIntervalMs({kind: AnswerKind.refused, text: ""}), REFRESH_INTERVAL_MS_MIN, "a refusal")
deepStrictEqual(refreshIntervalMs({kind: AnswerKind.invalid}), REFRESH_INTERVAL_MS_MIN, "an answer that is none")

function step({answer, answeredAfterMs, nowAfterMs, isVisible}) {
  return stepOf({answer, answeredAtMs: OPENED_AT_MS + answeredAfterMs, openedAtMs: OPENED_AT_MS, nowMs: OPENED_AT_MS + nowAfterMs, isVisible})
}

const stepCases = [
  {name: "just answered", answer: arrivals, answeredAfterMs: 0, nowAfterMs: 0, isVisible: true, expected: {kind: StepKind.wait, delayMs: REFRESH_INTERVAL_MS_MIN}},
  {name: "partway through the interval", answer: arrivals, answeredAfterMs: 0, nowAfterMs: 4 * SECOND_MS, isVisible: true, expected: {kind: StepKind.wait, delayMs: REFRESH_INTERVAL_MS_MIN - 4 * SECOND_MS}},
  {name: "the interval gone", answer: arrivals, answeredAfterMs: 0, nowAfterMs: REFRESH_INTERVAL_MS_MIN, isVisible: true, expected: {kind: StepKind.refresh}},
  {name: "the interval long gone", answer: arrivals, answeredAfterMs: 0, nowAfterMs: 5 * REFRESH_INTERVAL_MS_MIN, isVisible: true, expected: {kind: StepKind.refresh}},
  {name: "a wait the answer gives", answer: fetching(30), answeredAfterMs: 0, nowAfterMs: 0, isVisible: true, expected: {kind: StepKind.wait, delayMs: 30 * SECOND_MS}},
  {name: "hidden while waiting", answer: arrivals, answeredAfterMs: 0, nowAfterMs: 4 * SECOND_MS, isVisible: false, expected: {kind: StepKind.pause}},
  {name: "hidden with a request due", answer: arrivals, answeredAfterMs: 0, nowAfterMs: REFRESH_INTERVAL_MS_MIN, isVisible: false, expected: {kind: StepKind.pause}},
  {
    name: "the wait ends at the lifetime",
    answer: fetching(60),
    answeredAfterMs: BOARD_LIFETIME_MS - 20 * SECOND_MS,
    nowAfterMs: BOARD_LIFETIME_MS - 20 * SECOND_MS,
    isVisible: true,
    expected: {kind: StepKind.wait, delayMs: 20 * SECOND_MS}
  },
  {name: "the lifetime gone", answer: arrivals, answeredAfterMs: 0, nowAfterMs: BOARD_LIFETIME_MS, isVisible: true, expected: {kind: StepKind.expired}},
  {name: "the lifetime gone while hidden", answer: arrivals, answeredAfterMs: 0, nowAfterMs: BOARD_LIFETIME_MS + SECOND_MS, isVisible: false, expected: {kind: StepKind.expired}},
  {name: "a stop the server does not know", answer: {kind: AnswerKind.unknownStop, stopId: "9_9"}, answeredAfterMs: 0, nowAfterMs: REFRESH_INTERVAL_MS_MIN, isVisible: true, expected: {kind: StepKind.settled}}
]

for (const {name, answer, answeredAfterMs, nowAfterMs, isVisible, expected} of stepCases) {
  deepStrictEqual(step({answer, answeredAfterMs, nowAfterMs, isVisible}), expected, name)
}

deepStrictEqual(expiredText().length > 0, true, "the board says it stopped")

console.log("mcp_board_refresh_check: all cases passed")
