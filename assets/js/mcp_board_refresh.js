// When the arrivals board asks for its arrivals again, as pure functions of
// the answer it holds and a clock it is given: an interval that is never
// under a floor, no request while the document is hidden, a request that is
// due the moment the document is shown again, and a lifetime after which the
// board stops. Nothing here reads the document, the clock, or a timer.

import {AnswerKind} from "./mcp_board_answer.js"
import {unreachable} from "./assert.js"

const SECOND_MS = 1000

/** The shortest time between two requests of the board, whatever an answer says. */
export const REFRESH_INTERVAL_MS_MIN = 10 * 1000

/** The wait after an answer that names none: the arrival source's interval. */
export const ARRIVAL_SOURCE_INTERVAL_MS = 5 * 1000

/** How long the board refreshes after it opens, which bounds the holds it renews. */
export const BOARD_LIFETIME_MS = 30 * 60 * 1000

const EXPIRED_TEXT = "This board stopped updating. Ask your assistant for the stop again."

/** The kinds of what the board does next. */
export const StepKind = Object.freeze({refresh: "refresh", wait: "wait", pause: "pause", expired: "expired", settled: "settled"})

/** The text the board shows once its lifetime has passed. */
export function expiredText() {
  return EXPIRED_TEXT
}

/**
 * How long after `answer` the board asks again: the wait the answer gives,
 * or the arrival source's interval where it gives none, and never less than
 * REFRESH_INTERVAL_MS_MIN.
 */
export function refreshIntervalMs(answer) {
  switch (answer.kind) {
    case AnswerKind.fetching:
    case AnswerKind.capacityReached:
      return Math.max(REFRESH_INTERVAL_MS_MIN, answer.retryAfterSeconds * SECOND_MS)
    case AnswerKind.arrivals:
    case AnswerKind.unknownStop:
    case AnswerKind.refused:
    case AnswerKind.invalid:
      return Math.max(REFRESH_INTERVAL_MS_MIN, ARRIVAL_SOURCE_INTERVAL_MS)
    default:
      return unreachable(answer.kind, "board refresh: an answer of unknown kind")
  }
}

/**
 * What the board does at `nowMs`, Unix milliseconds, holding `answer`, which
 * came at `answeredAtMs`, for a board opened at `openedAtMs`: `expired` once
 * BOARD_LIFETIME_MS has passed, `settled` for a stop the server does not
 * know, `pause` while the document is hidden, `refresh` once the interval
 * is up, and otherwise `wait` for `delayMs`, never past the lifetime.
 */
export function stepOf({answer, answeredAtMs, openedAtMs, nowMs, isVisible}) {
  const expiresAtMs = openedAtMs + BOARD_LIFETIME_MS

  if (nowMs >= expiresAtMs) {
    return {kind: StepKind.expired}
  }

  if (answer.kind === AnswerKind.unknownStop) {
    return {kind: StepKind.settled}
  }

  if (isVisible === false) {
    return {kind: StepKind.pause}
  }

  const dueAtMs = answeredAtMs + refreshIntervalMs(answer)

  if (nowMs >= dueAtMs) {
    return {kind: StepKind.refresh}
  }

  return {kind: StepKind.wait, delayMs: Math.min(dueAtMs, expiresAtMs) - nowMs}
}
