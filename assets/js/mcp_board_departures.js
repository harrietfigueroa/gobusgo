// What the arrivals board shows of a list of scheduled departures, as pure
// functions: the instant the time asked for names, the live window a
// departure may fall in, the rows with their clock times and days, the line
// that says what the list is from, and the status line of each way a read
// ends. Nothing here reads the document, the network, or a clock.

import {assertCondition, unreachable} from "./assert.js"
import {DepartureLoadKind} from "./departure_files.js"
import {ARRIVAL_HORIZON_SECONDS} from "./scheduled_service.js"
import {ClockKind, TimeMode, clockText, wallClockMs} from "./trip_plan.js"

/** The kinds of the instant a time asked for names. */
export const FromKind = Object.freeze({found: "found", arriveBy: "arriveBy", invalid: "invalid"})

/** The note on a departure within the live window. */
export const LIVE_NOTE = "Live time: ask the arrivals tool."

const SECOND_MS = 1000
const LIVE_WINDOW_MS = ARRIVAL_HORIZON_SECONDS * SECOND_MS
const ARRIVE_BY_TEXT = "This board lists departures from a time. Ask your assistant for a departure time."
const NO_DEPARTURES_TEXT = "No scheduled departures from this time."
const NO_SCHEDULE_TEXT = "The schedules do not hold that day."
const UNKNOWN_STOP_TEXT = "This stop is not in the schedules."
const FAILED_TEXT = "The schedules could not be read. Ask your assistant to show the board again."
const REFUSED_WHEN_TEXT = "The time asked for is not one the board can show."
const REFUSED_ROUTE_TEXT = "The routes asked for are not ones the board can show."

/**
 * The instant `when`, `{mode, day, clockText}`, names at `nowMs` on the
 * clock of `timeZone`: a FromKind member, found with `ms`, the instant the
 * list starts at; `arriveBy` for a time to arrive by, which a list of
 * departures cannot answer; or `invalid` for a clock that names no time. A
 * time already past is kept, since the list is what the schedule held.
 */
export function fromMsOf({when, nowMs, timeZone}) {
  if (when.mode === TimeMode.now) {
    return {kind: FromKind.found, ms: nowMs}
  }

  if (when.mode === TimeMode.arriveBy) {
    return {kind: FromKind.arriveBy}
  }

  assertCondition(when.mode === TimeMode.departAt, "board departures: a time mode of unknown kind " + when.mode)
  const clock = wallClockMs({nowMs, day: when.day, clockText: when.clockText, timeZone})

  if (clock.kind === ClockKind.invalid) {
    return {kind: FromKind.invalid}
  }

  return {kind: FromKind.found, ms: clock.ms}
}

/** Whether a departure at `timeMs` falls in the window `arrivals` answers live, from `nowMs` to its horizon. */
export function isInLiveWindow({timeMs, nowMs}) {
  return timeMs >= nowMs && timeMs <= nowMs + LIVE_WINDOW_MS
}

// The day of `ms` on the calendar of `timeZone`, as "YYYY-MM-DD".
function dayKey({ms, timeZone}) {
  return new Intl.DateTimeFormat("en-CA", {year: "numeric", month: "2-digit", day: "2-digit", timeZone}).format(new Date(ms))
}

function weekdayText({ms, timeZone}) {
  return new Intl.DateTimeFormat("en-US", {weekday: "short", timeZone}).format(new Date(ms))
}

// The weekday of `ms` where its day is not the day of `referenceMs`, and an empty text on that day.
function dayText({ms, referenceMs, timeZone}) {
  if (dayKey({ms, timeZone}) === dayKey({ms: referenceMs, timeZone})) {
    return ""
  }

  return weekdayText({ms, timeZone})
}

/**
 * The rows of `departures`, as `scheduledDepartures` lists them: each row's
 * `key`, its clock `time` on `timeZone`, its `day` where it is not the day
 * of `fromMs`, its route and color, its headsign, and a `note` that the live
 * answer comes from the arrivals tool where the departure falls in the live
 * window counted from `nowMs`, or an empty text.
 */
export function departureRows({departures, fromMs, nowMs, timeZone}) {
  const rows = []

  for (const departure of departures) {
    let note = ""

    if (isInLiveWindow({timeMs: departure.timeMs, nowMs})) {
      note = LIVE_NOTE
    }

    rows.push({
      key: `${departure.tripId}/${departure.timeMs}`,
      time: clockText({ms: departure.timeMs, timeZone}),
      day: dayText({ms: departure.timeMs, referenceMs: fromMs, timeZone}),
      route: departure.route,
      color: departure.color,
      headsign: departure.headsign,
      note
    })
  }

  return rows
}

/** The line under the heading: what the list is from, with the weekday where `fromMs` is not today on the clock of `timeZone`. */
export function fromText({fromMs, nowMs, timeZone}) {
  const day = dayText({ms: fromMs, referenceMs: nowMs, timeZone})
  const clock = clockText({ms: fromMs, timeZone})

  if (day === "") {
    return `Scheduled departures from ${clock}`
  }

  return `Scheduled departures from ${clock} on ${day}`
}

/** What the board says of a time to arrive by. */
export function arriveByText() {
  return ARRIVE_BY_TEXT
}

/** What the board says of `field`, `when` or `route`, a tool argument that is not what the schema says. */
export function refusalText(field) {
  if (field === "when") {
    return REFUSED_WHEN_TEXT
  }

  assertCondition(field === "route", "board departures: a refused field of unknown name " + field)
  return REFUSED_ROUTE_TEXT
}

/**
 * The status line for `loaded`, what a read of the departures ended in, a
 * DepartureLoadKind member: empty for a list that is whole.
 */
export function loadStatusText(loaded) {
  switch (loaded.kind) {
    case DepartureLoadKind.listed:
      if (loaded.departures.length === 0) {
        return NO_DEPARTURES_TEXT
      }

      if (loaded.isBounded) {
        return `The list stops at ${loaded.departures.length} departures. Ask your assistant for a later time to see more.`
      }

      return ""
    case DepartureLoadKind.noSchedule:
      return NO_SCHEDULE_TEXT
    case DepartureLoadKind.unknownStop:
      return UNKNOWN_STOP_TEXT
    case DepartureLoadKind.failed:
      return FAILED_TEXT
    default:
      return unreachable(loaded.kind, "board departures: a read that ended in a kind unknown")
  }
}
