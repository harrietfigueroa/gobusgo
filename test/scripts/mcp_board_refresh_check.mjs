// Checks when the arrivals board asks for its arrivals again, as pure
// functions of the answer it holds and a clock written out by hand: the
// interval floor, the wait the tool gives, the lifetime of the board, no request while the document is hidden, the request that is due
// on showing it again, the lifetime after which the board stops, and a stop
// the server does not know. Run it with
// `node test/scripts/mcp_board_refresh_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {AnswerKind} from "../../assets/js/mcp_board_answer.js"
import {BOARD_LIFETIME_MS, REFRESH_INTERVAL_MS_MIN, StepKind, expiredText, refreshIntervalMs, stepOf} from "../../assets/js/mcp_board_refresh.js"

const OPENED_AT_MS = 1_794_250_000_000
const SECOND_MS = 1000
const WAIT_UNDER_FLOOR_SECONDS = 5
const WAIT_OVER_FLOOR_SECONDS = 30
const CAPACITY_WAIT_SECONDS = 60
const PARTWAY_MS = 4 * 1000
const LONG_AFTER_MS = 50 * 1000
const LIFETIME_REMAINING_MS = 20 * 1000
const arrivals = {kind: AnswerKind.arrivals, stopId: "1_1", stopName: null, fetchedAtMs: OPENED_AT_MS, arrivals: []}
const refused = {kind: AnswerKind.refused, text: ""}
const invalid = {kind: AnswerKind.invalid}
const unknownStop = {kind: AnswerKind.unknownStop, stopId: "9_9"}
const fetchingUnderFloor = {kind: AnswerKind.fetching, stopId: "1_1", retryAfterSeconds: WAIT_UNDER_FLOOR_SECONDS}
const fetchingOverFloor = {kind: AnswerKind.fetching, stopId: "1_1", retryAfterSeconds: WAIT_OVER_FLOOR_SECONDS}
const capacityReached = {kind: AnswerKind.capacityReached, stopId: "1_1", retryAfterSeconds: CAPACITY_WAIT_SECONDS}
const fetchingNearEnd = {kind: AnswerKind.fetching, stopId: "1_1", retryAfterSeconds: CAPACITY_WAIT_SECONDS}

// An open board holds a stop for ten minutes.
const TEN_MINUTES_MS = 10 * 60 * 1000
deepStrictEqual(BOARD_LIFETIME_MS, TEN_MINUTES_MS, "the board's lifetime")

// The interval never goes under the floor, and the answer's wait sets it above.
deepStrictEqual(refreshIntervalMs(arrivals), REFRESH_INTERVAL_MS_MIN, "an arrivals answer")
deepStrictEqual(refreshIntervalMs(fetchingUnderFloor), REFRESH_INTERVAL_MS_MIN, "a wait under the floor")
deepStrictEqual(refreshIntervalMs(fetchingOverFloor), WAIT_OVER_FLOOR_SECONDS * SECOND_MS, "a wait over the floor")
deepStrictEqual(refreshIntervalMs(capacityReached), CAPACITY_WAIT_SECONDS * SECOND_MS, "a capacity_reached wait")
deepStrictEqual(refreshIntervalMs(refused), REFRESH_INTERVAL_MS_MIN, "a refusal")
deepStrictEqual(refreshIntervalMs(invalid), REFRESH_INTERVAL_MS_MIN, "an answer that is none")

function step({answer, answeredAfterMs, nowAfterMs, isVisible}) {
  return stepOf({answer, answeredAtMs: OPENED_AT_MS + answeredAfterMs, openedAtMs: OPENED_AT_MS, nowMs: OPENED_AT_MS + nowAfterMs, isVisible})
}

const NEAR_END_AFTER_MS = BOARD_LIFETIME_MS - LIFETIME_REMAINING_MS

const stepCases = [
  {name: "just answered", answer: arrivals, answeredAfterMs: 0, nowAfterMs: 0, isVisible: true, expected: {kind: StepKind.wait, delayMs: REFRESH_INTERVAL_MS_MIN}},
  {name: "partway through the interval", answer: arrivals, answeredAfterMs: 0, nowAfterMs: PARTWAY_MS, isVisible: true, expected: {kind: StepKind.wait, delayMs: REFRESH_INTERVAL_MS_MIN - PARTWAY_MS}},
  {name: "the interval gone", answer: arrivals, answeredAfterMs: 0, nowAfterMs: REFRESH_INTERVAL_MS_MIN, isVisible: true, expected: {kind: StepKind.refresh}},
  {name: "the interval long gone", answer: arrivals, answeredAfterMs: 0, nowAfterMs: LONG_AFTER_MS, isVisible: true, expected: {kind: StepKind.refresh}},
  {name: "a wait the answer gives", answer: fetchingOverFloor, answeredAfterMs: 0, nowAfterMs: 0, isVisible: true, expected: {kind: StepKind.wait, delayMs: WAIT_OVER_FLOOR_SECONDS * SECOND_MS}},
  {name: "hidden while waiting", answer: arrivals, answeredAfterMs: 0, nowAfterMs: PARTWAY_MS, isVisible: false, expected: {kind: StepKind.pause}},
  {name: "hidden with a request due", answer: arrivals, answeredAfterMs: 0, nowAfterMs: REFRESH_INTERVAL_MS_MIN, isVisible: false, expected: {kind: StepKind.pause}},
  {name: "the wait ends at the lifetime", answer: fetchingNearEnd, answeredAfterMs: NEAR_END_AFTER_MS, nowAfterMs: NEAR_END_AFTER_MS, isVisible: true, expected: {kind: StepKind.wait, delayMs: LIFETIME_REMAINING_MS}},
  {name: "the lifetime gone", answer: arrivals, answeredAfterMs: 0, nowAfterMs: BOARD_LIFETIME_MS, isVisible: true, expected: {kind: StepKind.expired}},
  {name: "the lifetime gone while hidden", answer: arrivals, answeredAfterMs: 0, nowAfterMs: BOARD_LIFETIME_MS + SECOND_MS, isVisible: false, expected: {kind: StepKind.expired}},
  {name: "a stop the server does not know", answer: unknownStop, answeredAfterMs: 0, nowAfterMs: REFRESH_INTERVAL_MS_MIN, isVisible: true, expected: {kind: StepKind.settled}}
]

for (const {name, answer, answeredAfterMs, nowAfterMs, isVisible, expected} of stepCases) {
  deepStrictEqual(step({answer, answeredAfterMs, nowAfterMs, isVisible}), expected, name)
}

deepStrictEqual(expiredText().length > 0, true, "the board says it stopped")

console.log("mcp_board_refresh_check: all cases passed")
