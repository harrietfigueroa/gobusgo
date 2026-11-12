// How a stop's arrivals count down between the server's events, as pure
// functions of the arrivals and a clock they are given. Nothing here reads
// the time, the document, or a timer, so a check replays any moment.

import {assertCondition, unreachable} from "./core/assert.js"

/** How often a page writes its arrivals again from the clock while it is visible. */
export const COUNTDOWN_INTERVAL_MS = 15 * 1000

const MINUTE_MS = 60 * 1000

/** The kinds of an arrival's time at a moment. */
export const ArrivalTimeKind = Object.freeze({passed: "passed", now: "now", minutes: "minutes"})

/**
 * An arrival at `timeMs` as seen at `nowMs`, both Unix milliseconds: passed
 * once its time is behind the clock, now inside its last minute, and
 * otherwise its whole minutes away, the part of a minute left out, as the
 * server counts them.
 */
export function arrivalTimeAt({timeMs, nowMs}) {
  assertCondition(Number.isSafeInteger(timeMs), "an arrival's time must be an integer, got: " + String(timeMs))
  assertCondition(Number.isSafeInteger(nowMs), "the clock must be an integer, got: " + String(nowMs))

  if (timeMs < nowMs) {
    return {kind: ArrivalTimeKind.passed}
  }

  const minutes = Math.floor((timeMs - nowMs) / MINUTE_MS)

  if (minutes === 0) {
    return {kind: ArrivalTimeKind.now}
  }

  return {kind: ArrivalTimeKind.minutes, minutes}
}

/**
 * `shown`, a stop's arrivals in the shape of the "stop-arrivals:arrivals"
 * event, as of `nowMs`: the arrivals whose time has not passed, in the
 * order given, at most `countMax` of them, each with its minutes counted
 * from its `time_ms`. Any other status is returned as it is.
 */
export function shownAt({shown, nowMs, countMax}) {
  assertCondition(Number.isSafeInteger(countMax), "the most arrivals shown must be an integer, got: " + String(countMax))
  assertCondition(countMax >= 1, "the most arrivals shown must be at least one, got: " + String(countMax))

  if (shown.status !== "arrivals") {
    return shown
  }

  const arrivals = []

  for (const arrival of shown.arrivals) {
    if (arrivals.length === countMax) {
      break
    }

    const time = arrivalTimeAt({timeMs: arrival.time_ms, nowMs})

    switch (time.kind) {
      case ArrivalTimeKind.passed:
        break
      case ArrivalTimeKind.now:
        arrivals.push({...arrival, minutes: 0})
        break
      case ArrivalTimeKind.minutes:
        arrivals.push({...arrival, minutes: time.minutes})
        break
      default:
        unreachable(time.kind, "arrival time kind")
    }
  }

  return {...shown, arrivals}
}
