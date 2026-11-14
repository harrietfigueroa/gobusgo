// What the Trip tab decides, as pure functions: whether two ends make a
// query, the time it leaves at or arrives by, what the journeys of a query
// read as, which stops and routes the page is asked to name, which routes a
// selected journey's filter names, and what the map draws of it. Nothing
// here reads the document, the clock, storage, or the network: the time,
// the time zone, the names, and the positions arrive as arguments.

import {assertCondition, unreachable} from "./assert.js"
import {assertPosition} from "./math/geodesy.js"
import {LegKind} from "./routing_engine.js"
import {FailureReason, JourneysKind, ServiceDateKind, WINDOW_SECONDS, serviceDateAt} from "./routing_journeys.js"
import {LEG_KIND_TO_POINT} from "./point_journeys.js"
import {RideLineKind, ridePathLine} from "./ride_path.js"
import {PREVIOUS_DATE_OFFSET, previousDate} from "./routing_snapshot.js"
import {tripPathKey} from "./trip_path.js"

/** The two ends of a trip. */
export const TripEnd = Object.freeze({from: "from", to: "to"})

/** The kinds of an end: none chosen, the rider's location, a stop, or a point such as a place, an address, or an intersection. */
export const EndKind = Object.freeze({none: "none", location: "location", stop: "stop", point: "point"})

/** The kinds of what two ends make. */
export const QueryKind = Object.freeze({ready: "ready", incomplete: "incomplete", sameStop: "sameStop", samePoint: "samePoint"})

/** The outcomes the Trip tab states in place of journeys, beside the router's own. */
export const StateKind = Object.freeze({
  loading: "loading",
  noServiceDate: "noServiceDate",
  locationDenied: "locationDenied",
  locationUnavailable: "locationUnavailable",
  sameStop: "sameStop",
  samePoint: "samePoint",
  noEndStop: "noEndStop",
  notSaved: "notSaved",
  outsideSchedules: "outsideSchedules",
  chooseTime: "chooseTime",
  noneInTime: "noneInTime",
})

/** When a trip is planned for: leaving now, leaving at a time, or arriving by one. */
export const TimeMode = Object.freeze({now: "now", departAt: "departAt", arriveBy: "arriveBy"})

/** The days a chosen time can fall on. */
export const DayChoice = Object.freeze({today: "today", tomorrow: "tomorrow"})

/** The kinds of the time a query is planned for: leaving at it, arriving by it, or refused. */
export const PlannedKind = Object.freeze({leaving: "leaving", arrivingBy: "arrivingBy", refused: "refused"})

/** The kinds of a time read from the page's clock: a valid instant, or text that names none. */
export const ClockKind = Object.freeze({valid: "valid", invalid: "invalid"})

/** The kinds of a feature the map draws of a journey. */
export const FeatureKind = Object.freeze({ride: "ride", walk: "walk", origin: "origin", destination: "destination"})

/** The kinds of the bounds of what the map draws: none, or a box. */
export const BoundsKind = Object.freeze({none: "none", bounds: "bounds"})

/** The end that names no place. */
export const NO_END = Object.freeze({kind: EndKind.none})

/** The end of the rider's location, which a From field alone offers. */
export const LOCATION_END = Object.freeze({kind: EndKind.location})

/** The color of a route the page has named no color for. */
export const ROUTE_COLOR_DEFAULT = "#6b7280"

const SECOND_MS = 1000
const MINUTE_S = 60
const ARROW = " → "
const LINE_POINT_COUNT_MIN = 2
const TOMORROW_PREFIX = "Tomorrow "
const DAY_MS = 24 * 60 * 60 * 1000
const DEFAULT_STEP_MINUTES = 5
const CLOCK_DIGITS = 2
// A time input's value: two-digit hours and minutes.
const CLOCK_PATTERN = /^(?<hours>[01]\d|2[0-3]):(?<minutes>[0-5]\d)$/
const DAY_SHIFTS = Object.freeze({[DayChoice.today]: 0, [DayChoice.tomorrow]: 1})

const stateMessages = Object.freeze({
  [StateKind.loading]: {headline: "Finding journeys…", caption: "Searching today's and tomorrow's schedules."},
  [StateKind.noServiceDate]: {headline: "No schedule for this time yet", caption: "Try again later."},
  [StateKind.locationDenied]: {headline: "Location is off", caption: "Start from a stop instead, or allow location in your browser's settings."},
  [StateKind.locationUnavailable]: {headline: "Can't find your location", caption: "Start from a stop instead, or try again."},
  [StateKind.sameStop]: {headline: "From and To are the same stop", caption: "Choose another stop for one of them."},
  [StateKind.samePoint]: {headline: "From and To are the same place", caption: "Choose another place for one of them."},
  [StateKind.noEndStop]: {headline: "No stop within a walk of there", caption: "Choose a place nearer a stop."},
  [StateKind.notSaved]: {headline: "Not saved for offline", caption: "Connect to plan this trip."},
  [StateKind.outsideSchedules]: {headline: "No schedule for that time", caption: "Schedules cover today and tomorrow. Choose another time."},
  [StateKind.chooseTime]: {headline: "Choose a time", caption: "Set the time to plan this trip."},
  [StateKind.noneInTime]: {headline: "No journeys arrive in time", caption: "Nothing reaches this stop by then. Choose a later time."},
  [JourneysKind.none]: {headline: "No journeys found", caption: "Nothing runs between these two today or tomorrow."},
  [JourneysKind.unknownStop]: {headline: "Stop not in the schedules", caption: "Choose another stop nearby."},
  [JourneysKind.noStartStop]: {headline: "No stop within a walk", caption: "Start from a stop instead."},
  [JourneysKind.failed]: {headline: "Journeys didn't load", caption: "Check your connection and try again."},
})

/** The message the Trip tab shows while the rider picks the stop of `fieldLabel` on the map. */
export function pickingMessage(fieldLabel) {
  return {headline: `Pick a stop for ${fieldLabel}`, caption: "Tap a stop on the map. Stops show once the map is zoomed in."}
}

/** The end of the stop `stopId`, named `name` until the page names it. */
export function stopEnd({stopId, name}) {
  assertCondition(typeof stopId === "string", "trip plan: a stop end's identifier is not text: " + stopId)
  assertCondition(stopId !== "", "trip plan: a stop end has an empty identifier")
  return {kind: EndKind.stop, stopId, name}
}

/**
 * The end at the point `lat`, `lon` in degrees, named `name`: a place, an
 * address, or an intersection, which a journey walks to or from the stops
 * near it.
 */
export function pointEnd({name, lat, lon}) {
  assertCondition(typeof name === "string", "trip plan: a point end's name is not text: " + name)
  assertPosition([lon, lat], "trip plan: a point end")
  return {kind: EndKind.point, name, lat, lon}
}

/**
 * The ends with From and To swapped. The rider's location is a From end
 * alone, so a location that would become the To end leaves it empty.
 */
export function swappedEnds({from, to}) {
  if (from.kind === EndKind.location) {
    return {from: to, to: NO_END}
  }

  return {from: to, to: from}
}

/**
 * What the ends `from` and `to` make: a query from the From end to the To
 * end, a stop or a point, nothing while an end is missing, or a refusal
 * for one stop or one point at both ends.
 */
export function queryOf({from, to}) {
  const isFromSet = from.kind !== EndKind.none
  const isToPlaced = to.kind === EndKind.stop || to.kind === EndKind.point
  const isComplete = isFromSet && isToPlaced

  if (!isComplete) {
    return {kind: QueryKind.incomplete}
  }

  const isBothStops = from.kind === EndKind.stop && to.kind === EndKind.stop
  const isSameStop = isBothStops && from.stopId === to.stopId
  const isBothPoints = from.kind === EndKind.point && to.kind === EndKind.point
  const isSamePosition = isBothPoints && from.lat === to.lat
  const isSamePoint = isSamePosition && from.lon === to.lon

  if (isSameStop) {
    return {kind: QueryKind.sameStop}
  } else if (isSamePoint) {
    return {kind: QueryKind.samePoint}
  }

  return {kind: QueryKind.ready, from, to}
}

/** The message the Trip tab shows for `kind`, a state of its own or a router outcome. */
export function stateMessage(kind) {
  const isKnown = Object.hasOwn(stateMessages, kind)
  assertCondition(isKnown, "trip plan: no message for the state " + kind)
  return stateMessages[kind]
}

/** Whether a failure is worth trying again: every failure but a format the page cannot read. */
export function isRetryable(failure) {
  return failure.reason !== FailureReason.unsupportedVersion
}

/** The state the Trip tab shows for a failed query: that its schedules are not saved, or that it failed. */
export function failureState(failure) {
  if (failure.reason === FailureReason.notSaved) {
    return StateKind.notSaved
  }

  return JourneysKind.failed
}

/** `ms`, milliseconds since the Unix epoch, as a clock time in `timeZone`, such as "8:42 am". */
export function clockText({ms, timeZone}) {
  const format = new Intl.DateTimeFormat("en-US", {hour: "numeric", minute: "2-digit", hour12: true, timeZone})
  const parts = format.formatToParts(new Date(ms))
  let text = ""

  // ICU separates the day period with a narrow no-break space, which reads
  // as a plain space and is written as one.
  for (const part of parts) {
    const isSpace = part.type === "literal" && part.value.trim() === ""

    if (part.type === "dayPeriod") {
      text += part.value.toLowerCase()
    } else if (isSpace) {
      text += " "
    } else {
      text += part.value
    }
  }

  return text
}

function byChangesThenArrival(left, right) {
  if (left.journey.changes !== right.journey.changes) {
    return left.journey.changes - right.journey.changes
  }

  return left.arrivalMs - right.arrivalMs
}

// The milliseconds since the Unix epoch of `seconds` from the start of the
// service day `serviceDate`.
function absoluteMs({serviceDayStartsMs, serviceDate, seconds}) {
  const startMs = serviceDayStartsMs[serviceDate]
  assertCondition(Number.isInteger(startMs), "trip plan: no start for the service date " + serviceDate)
  return startMs + seconds * SECOND_MS
}

/**
 * The seconds from its service day's start a journey leaves at: the time a
 * journey arriving by a time was found to leave at, or else its first
 * ride's departure less the walks before it, or its arrival less its walks
 * for a journey with no ride.
 */
export function journeyLeaveS(journey) {
  if (journey.departureS !== undefined) {
    return journey.departureS
  }

  let walkS = 0

  for (const leg of journey.legs) {
    if (leg.kind === LegKind.ride) {
      return leg.departureS - walkS
    }

    walkS += leg.durationS
  }

  return journey.arrivalS - walkS
}

// The fields of `ms` on the clock of `timeZone`, as numbers.
function zonedParts({ms, timeZone}) {
  const format = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  })
  const parts = {}

  for (const part of format.formatToParts(new Date(ms))) {
    if (part.type !== "literal") {
      parts[part.type] = Number(part.value)
    }
  }

  return parts
}

// How far the clock of `timeZone` stands ahead of UTC at `ms`.
function zoneOffsetMs({ms, timeZone}) {
  const parts = zonedParts({ms, timeZone})
  const asUtcMs = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second)
  const wholeMs = Math.floor(ms / SECOND_MS) * SECOND_MS
  return asUtcMs - wholeMs
}

// The day of `ms` on the calendar of `timeZone`, counted in whole days.
function dayNumber({ms, timeZone}) {
  const parts = zonedParts({ms, timeZone})
  const dayMs = Date.UTC(parts.year, parts.month - 1, parts.day)
  return Math.round(dayMs / DAY_MS)
}

// The words that place `ms` on a day relative to `nowMs`: none for today,
// "tomorrow", or the weekday.
function dayWords({ms, nowMs, timeZone}) {
  const offset = dayNumber({ms, timeZone}) - dayNumber({ms: nowMs, timeZone})

  if (offset === 0) {
    return {prefix: "", phrase: ""}
  } else if (offset === 1) {
    return {prefix: TOMORROW_PREFIX, phrase: "tomorrow "}
  }

  const weekday = new Intl.DateTimeFormat("en-US", {weekday: "short", timeZone}).format(new Date(ms))
  return {prefix: `${weekday} `, phrase: `on ${weekday} `}
}

/**
 * The instant a time on the page's clock names: `day`, a DayChoice member
 * counted from `nowMs`, at `clockText`, "HH:MM" as a time input gives it,
 * on the clock of `timeZone`. A ClockKind member: valid with `ms`, or
 * invalid for text that names no time.
 */
export function wallClockMs({nowMs, day, clockText, timeZone}) {
  const match = CLOCK_PATTERN.exec(clockText)

  if (match === null) {
    return {kind: ClockKind.invalid}
  }

  const isKnownDay = Object.hasOwn(DAY_SHIFTS, day)
  assertCondition(isKnownDay, "trip plan: a day of unknown kind " + day)
  const today = zonedParts({ms: nowMs, timeZone})
  const hours = Number(match.groups.hours)
  const minutes = Number(match.groups.minutes)
  const guessMs = Date.UTC(today.year, today.month - 1, today.day + DAY_SHIFTS[day], hours, minutes)
  const firstMs = guessMs - zoneOffsetMs({ms: guessMs, timeZone})
  const ms = guessMs - zoneOffsetMs({ms: firstMs, timeZone})
  return {kind: ClockKind.valid, ms}
}

/** The day and "HH:MM" a chosen time starts at: the next whole five minutes from `nowMs`. */
export function defaultClock({nowMs, timeZone}) {
  const stepMs = DEFAULT_STEP_MINUTES * MINUTE_S * SECOND_MS
  const roundedMs = Math.ceil(nowMs / stepMs) * stepMs
  const parts = zonedParts({ms: roundedMs, timeZone})
  const clockText = `${String(parts.hour).padStart(CLOCK_DIGITS, "0")}:${String(parts.minute).padStart(CLOCK_DIGITS, "0")}`
  const isToday = dayNumber({ms: roundedMs, timeZone}) === dayNumber({ms: nowMs, timeZone})

  if (isToday) {
    return {day: DayChoice.today, clockText}
  }

  return {day: DayChoice.tomorrow, clockText}
}

function refused(state) {
  return {kind: PlannedKind.refused, state}
}

/**
 * The time a query leaves at or arrives by, from `when`, its TimeMode
 * `mode` with the `day` and `clockText` a chosen time reads: a PlannedKind
 * member, leaving or arriving by with the mode, the instant in `ms`, and
 * the service date of `manifest` that holds it with the seconds from that
 * date's start, or refused with the state that says why. A time no
 * snapshot holds is refused, never moved to another time.
 */
export function plannedTime({when, nowMs, timeZone, manifest}) {
  switch (when.mode) {
    case TimeMode.now: {
      const dated = serviceDateAt({manifest, departureMs: nowMs})

      if (dated.kind === ServiceDateKind.none) {
        return refused(StateKind.noServiceDate)
      }

      return {kind: PlannedKind.leaving, mode: when.mode, ms: nowMs, serviceDate: dated.serviceDate, seconds: dated.departureS}
    }
    case TimeMode.departAt:
    case TimeMode.arriveBy: {
      const clock = wallClockMs({nowMs, day: when.day, clockText: when.clockText, timeZone})

      if (clock.kind === ClockKind.invalid) {
        return refused(StateKind.chooseTime)
      }

      const dated = serviceDateAt({manifest, departureMs: clock.ms})

      if (dated.kind === ServiceDateKind.none) {
        return refused(StateKind.outsideSchedules)
      }

      let kind = PlannedKind.leaving

      if (when.mode === TimeMode.arriveBy) {
        kind = PlannedKind.arrivingBy
      }

      return {kind, mode: when.mode, ms: clock.ms, serviceDate: dated.serviceDate, seconds: dated.departureS}
    }
    default:
      return unreachable(when.mode, "trip plan: a time mode of unknown kind")
  }
}

/** Whole minutes of a walk, rounded up, so a short walk reads as one minute. */
export function walkMinutes(durationS) {
  return Math.ceil(durationS / MINUTE_S)
}

function changesText(changes) {
  if (changes === 0) {
    return "No change"
  } else if (changes === 1) {
    return "1 change"
  } else {
    return `${changes} changes`
  }
}

/** The name the page gave the stop `stopId` in `names`, or its identifier. */
export function stopName({names, stopId}) {
  const named = names.stops[stopId]
  const isText = named !== undefined && typeof named.name === "string"
  const isNamed = isText && named.name !== ""

  if (isNamed) {
    return named.name
  } else {
    return stopId
  }
}

/** The chip of the route `routeId`: the name and color the page gave it, or its identifier in gray. */
export function routeChip({names, routeId}) {
  const named = names.routes[routeId]

  if (named === undefined) {
    return {name: routeId, color: ROUTE_COLOR_DEFAULT}
  } else {
    return {name: named.name, color: named.color}
  }
}

// The name of where a journey ends: the point a journey to a point walks
// to, or else the stop it ends at.
function destinationName({journey, names}) {
  if (journey.destination !== undefined) {
    return journey.destination.name
  }

  const last = journey.legs[journey.legs.length - 1]
  return stopName({names, stopId: last.toStopId})
}

// The parts of the line that sums up a journey: a chip per ride and a text
// per walk.
function summaryParts({journey, names}) {
  const parts = []

  for (const leg of journey.legs) {
    switch (leg.kind) {
      case LegKind.ride:
        parts.push({kind: LegKind.ride, chip: routeChip({names, routeId: leg.routeId})})
        break
      case LegKind.walk:
      case LegKind.walkFromPosition:
      case LEG_KIND_TO_POINT:
        parts.push({kind: LegKind.walk, text: `walk ${walkMinutes(leg.durationS)} min`})
        break
      default:
        unreachable(leg.kind, "trip plan: a leg of unknown kind")
    }
  }

  return parts
}

// The steps of a journey, one sentence each, in the order the rider takes
// them. A ride that ends the journey has its stop in the arrival.
function steps({journey, names, clockOf}) {
  const result = []
  const lastIndex = journey.legs.length - 1

  for (const [index, leg] of journey.legs.entries()) {
    switch (leg.kind) {
      case LegKind.ride: {
        const route = routeChip({names, routeId: leg.routeId}).name
        result.push(`${clockOf(leg.departureS)} board ${route} at ${stopName({names, stopId: leg.fromStopId})}`)

        if (index < lastIndex) {
          result.push(`${clockOf(leg.arrivalS)} get off at ${stopName({names, stopId: leg.toStopId})}`)
        }

        break
      }
      case LegKind.walk:
      case LegKind.walkFromPosition:
        result.push(`walk ${walkMinutes(leg.durationS)} min to ${stopName({names, stopId: leg.toStopId})}`)
        break
      case LEG_KIND_TO_POINT:
        result.push(`walk ${walkMinutes(leg.durationS)} min to ${journey.destination.name}`)
        break
      default:
        unreachable(leg.kind, "trip plan: a leg of unknown kind")
    }
  }

  result.push(`${clockOf(journey.arrivalS)} arrive at ${destinationName({journey, names})}`)
  return result
}

// The text a row's badge leads with: the journey the answer marks, the
// earliest arrival or the latest departure, or none.
function markText(journey) {
  if (journey.isEarliest === true) {
    return "Earliest · "
  } else if (journey.isLatest === true) {
    return "Latest · "
  }

  return ""
}

/**
 * The rows of the journey list for `journeys`, a found answer's, fewest
 * changes first and the earlier arrival first within that. A journey that
 * leaves on another day than `nowMs` reads "Tomorrow" or its weekday before
 * its time. `serviceDayStartsMs` holds each service date's start, `names`
 * the page's names of the stops and the routes, and `timeZone` the zone the
 * times read in. Each row keeps its journey, and the row of the journey the
 * answer marks, the earliest arrival or the latest departure, is marked.
 */
export function journeyRows({journeys, nowMs, serviceDayStartsMs, names, timeZone}) {
  const timed = []

  for (const journey of journeys) {
    const arrivalMs = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds: journey.arrivalS})
    timed.push({journey, arrivalMs})
  }

  timed.sort(byChangesThenArrival)
  const rows = []

  for (const {journey, arrivalMs} of timed) {
    function clockOf(seconds) {
      const ms = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds})
      return clockText({ms, timeZone})
    }

    const startS = journeyLeaveS(journey)
    const leaveMs = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds: startS})
    const day = dayWords({ms: leaveMs, nowMs, timeZone})
    const leaveClockText = clockOf(startS)
    const durationMinutes = Math.round((journey.arrivalS - startS) / MINUTE_S)
    const mark = markText(journey)
    const arrivalText = clockText({ms: arrivalMs, timeZone})

    rows.push({
      journey,
      isMarked: mark !== "",
      dayPhrase: day.phrase,
      leaveClockText,
      arrivalText,
      timesText: day.prefix + leaveClockText + ARROW + arrivalText,
      badgeText: `${mark}${durationMinutes} min`,
      changesText: changesText(journey.changes),
      summary: summaryParts({journey, names}),
      steps: steps({journey, names, clockOf}),
    })
  }

  return rows
}

/**
 * The sentence the Trip tab's status line holds once `rows`, the rows of
 * a found answer, are written: how many journeys there are and when the
 * marked one arrives, or leaves for an answer arriving by a time, which a
 * screen reader announces in place of the list a sighted rider sees appear.
 */
export function journeysAnnouncement(rows) {
  assertCondition(rows.length > 0, `trip plan: an announcement needs a journey, got ${rows.length}`)
  const marked = rows.find(isMarkedRow)
  assertCondition(marked !== undefined, "trip plan: a found answer marks a journey")
  const isArrivingBy = marked.journey.isLatest === true

  if (rows.length === 1) {
    if (isArrivingBy) {
      return `1 journey. It leaves ${marked.dayPhrase}at ${marked.leaveClockText}.`
    }

    return `1 journey. It arrives ${marked.dayPhrase}at ${marked.arrivalText}.`
  }

  if (isArrivingBy) {
    return `${rows.length} journeys. The latest leaves ${marked.dayPhrase}at ${marked.leaveClockText}.`
  }

  return `${rows.length} journeys. The earliest arrives ${marked.dayPhrase}at ${marked.arrivalText}.`
}

/** Whether `row` is the row of the journey its answer marks. */
export function isMarkedRow(row) {
  return row.isMarked
}

// The words after a chosen time that place it on a day, such as " tomorrow".
function daySuffix({ms, nowMs, timeZone}) {
  const {phrase} = dayWords({ms, nowMs, timeZone})

  if (phrase === "") {
    return ""
  }

  return " " + phrase.trim()
}

function earliestArrivalMs({journeys, serviceDayStartsMs}) {
  let earliestMs = Number.POSITIVE_INFINITY

  for (const journey of journeys) {
    const arrivalMs = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds: journey.arrivalS})
    earliestMs = Math.min(earliestMs, arrivalMs)
  }

  assertCondition(Number.isFinite(earliestMs), "trip plan: a window over no journey")
  return earliestMs
}

function latestDepartureMs({journeys, serviceDayStartsMs}) {
  let latestMs = Number.NEGATIVE_INFINITY

  for (const journey of journeys) {
    const departureMs = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds: journeyLeaveS(journey)})
    latestMs = Math.max(latestMs, departureMs)
  }

  assertCondition(Number.isFinite(latestMs), "trip plan: a window over no journey")
  return latestMs
}

/**
 * The line over the journey list: what `planned`, a PlannedKind member a
 * query was routed for, asked, and the window of the journeys shown: those
 * arriving by the earliest arrival plus the window, or those leaving from
 * the latest departure less it for a query arriving by a time.
 */
export function windowText({journeys, planned, nowMs, serviceDayStartsMs, timeZone}) {
  const windowMs = WINDOW_SECONDS * SECOND_MS
  const chosenText = clockText({ms: planned.ms, timeZone}) + daySuffix({ms: planned.ms, nowMs, timeZone})

  switch (planned.mode) {
    case TimeMode.now: {
      const cutoffMs = earliestArrivalMs({journeys, serviceDayStartsMs}) + windowMs
      return `Leaving now · journeys arriving by ${clockText({ms: cutoffMs, timeZone})}`
    }
    case TimeMode.departAt: {
      const cutoffMs = earliestArrivalMs({journeys, serviceDayStartsMs}) + windowMs
      return `Leaving at ${chosenText} · journeys arriving by ${clockText({ms: cutoffMs, timeZone})}`
    }
    case TimeMode.arriveBy: {
      const cutoffMs = latestDepartureMs({journeys, serviceDayStartsMs}) - windowMs
      return `Arriving by ${chosenText} · journeys leaving from ${clockText({ms: cutoffMs, timeZone})}`
    }
    default:
      return unreachable(planned.mode, "trip plan: a time mode of unknown kind")
  }
}

function addBounded({values, value, countMax}) {
  if (values.size < countMax) {
    values.add(value)
  }
}

/**
 * The stops and the routes of `journeys` that the list names, each once,
 * at most `countMax` of each: the stops a leg boards, leaves, or walks
 * between, and the route of each ride.
 */
export function nameRequest({journeys, countMax}) {
  const stopIds = new Set()
  const routeIds = new Set()

  for (const journey of journeys) {
    for (const leg of journey.legs) {
      if (leg.kind === LEG_KIND_TO_POINT) {
        addBounded({values: stopIds, value: leg.fromStopId, countMax})
        continue
      }

      if (leg.kind === LegKind.ride) {
        addBounded({values: routeIds, value: leg.routeId, countMax})
        addBounded({values: stopIds, value: leg.fromStopId, countMax})
      } else if (leg.kind === LegKind.walk) {
        addBounded({values: stopIds, value: leg.fromStopId, countMax})
      }

      addBounded({values: stopIds, value: leg.toStopId, countMax})
    }
  }

  return {stopIds: Array.from(stopIds), routeIds: Array.from(routeIds)}
}

/**
 * The routes the filter of a trip whose selected journey is `journey`
 * names: the route of each ride, once, in the order the journey rides
 * them. A journey with no ride names none, and the page then keeps the
 * rider's own filter. `countMax` is the most a trip's filter names.
 */
export function tripRouteIds({journey, countMax}) {
  const routeIds = []

  for (const leg of journey.legs) {
    const isNewRide = leg.kind === LegKind.ride && routeIds.includes(leg.routeId) === false

    if (isNewRide) {
      routeIds.push(leg.routeId)
    }
  }

  assertCondition(routeIds.length <= countMax, "trip plan: a journey rides more routes than a trip's filter names: " + routeIds.length)
  return routeIds
}

// The position of `stopId` as a GeoJSON coordinate, or none.
function coordinatesOf({journey, stopId}) {
  const position = journey.stopPositions[stopId]

  if (position === undefined) {
    return []
  }

  return [[position.lon, position.lat]]
}

function lineFeature({coordinates, properties}) {
  return {type: "Feature", geometry: {type: "LineString", coordinates}, properties}
}

function pointFeature({coordinate, kind}) {
  return {type: "Feature", geometry: {type: "Point", coordinates: coordinate}, properties: {kind}}
}

/**
 * The coordinates of `leg` of `journey`, each `[lon, lat]`: a ride's stops
 * in order, a walk's two ends, with `origin`, the rider's position as a
 * list of one coordinate or none, standing for a walk from a position. A
 * stop with no known position is left out.
 */
export function legCoordinates({journey, leg, origin}) {
  switch (leg.kind) {
    case LegKind.ride: {
      const coordinates = []

      for (const stopId of leg.stopIds) {
        for (const coordinate of coordinatesOf({journey, stopId})) {
          coordinates.push(coordinate)
        }
      }

      return coordinates
    }
    case LegKind.walk:
      return [...coordinatesOf({journey, stopId: leg.fromStopId}), ...coordinatesOf({journey, stopId: leg.toStopId})]
    case LegKind.walkFromPosition:
      return [...origin, ...coordinatesOf({journey, stopId: leg.toStopId})]
    case LEG_KIND_TO_POINT:
      return [...coordinatesOf({journey, stopId: leg.fromStopId}), [journey.destination.lon, journey.destination.lat]]
    default:
      return unreachable(leg.kind, "trip plan: a leg of unknown kind")
  }
}

const LegTripKind = Object.freeze({trip: "trip", none: "none"})

/**
 * The trips `journey` rides, each `{tripId, routeId, serviceDateMs}` once,
 * in riding order, the service day of each the start of its date in
 * `serviceDayStartsMs`: a run of the previous date's schedule takes that
 * date's start, and a ride whose date has no start is left out.
 */
export function rideTripsOf({journey, serviceDayStartsMs}) {
  const trips = []
  const keys = new Set()

  for (const leg of journey.legs) {
    const found = legTripOf({journey, leg, serviceDayStartsMs})
    const isNew = found.kind === LegTripKind.trip && keys.has(tripPathKey(found.trip)) === false

    if (isNew) {
      keys.add(tripPathKey(found.trip))
      trips.push(found.trip)
    }
  }

  return trips
}

// The trip a ride of `journey` runs, on the service day it starts on, or
// none for a leg that is no ride and a ride whose date has no start.
function legTripOf({journey, leg, serviceDayStartsMs}) {
  if (leg.kind !== LegKind.ride) {
    return {kind: LegTripKind.none}
  }

  let serviceDate = journey.serviceDate

  if (leg.serviceDayOffset === PREVIOUS_DATE_OFFSET) {
    serviceDate = previousDate(journey.serviceDate)
  }

  const serviceDateMs = serviceDayStartsMs[serviceDate]

  if (!Number.isSafeInteger(serviceDateMs)) {
    return {kind: LegTripKind.none}
  }

  return {kind: LegTripKind.trip, trip: {tripId: leg.tripId, routeId: leg.routeId, serviceDateMs}}
}

// The coordinates a ride is drawn along: its trip's path in `paths` where
// the page holds it and it serves the ride, and `stopCoordinates`, the line
// through the ride's stops, otherwise.
function rideLineOf({journey, leg, stopCoordinates, paths, serviceDayStartsMs}) {
  const found = legTripOf({journey, leg, serviceDayStartsMs})

  if (found.kind === LegTripKind.none) {
    return stopCoordinates
  }

  const path = paths.get(tripPathKey(found.trip))

  if (path === undefined) {
    return stopCoordinates
  }

  const line = ridePathLine({path, leg, stopPositions: journey.stopPositions})

  switch (line.kind) {
    case RideLineKind.slice:
      return line.coordinates
    case RideLineKind.fallback:
      return stopCoordinates
    default:
      return unreachable(line.kind, "trip plan: a ride line of unknown kind")
  }
}

/**
 * What the map draws of `journey`: a line per ride in its route's color from
 * `names`, a line per walk, and a point at each end, as a GeoJSON feature
 * collection, with the bounds of every coordinate this call draws, a BoundsKind member.
 * A ride follows its trip's path where `paths`, the decoded paths by
 * `tripPathKey`, holds one that serves it, cut between its boarding and
 * alighting stops, and otherwise runs through the stops it passes;
 * `serviceDayStartsMs` names the service day each trip runs on. `origin` is
 * the rider's position in degrees for a journey from it, or null. A stop
 * with no known position is left out of its line, a line with fewer than two
 * points is not drawn, and the ends stand at the first and last stop.
 */
export function journeyFeatures({journey, names, origin, paths, serviceDayStartsMs}) {
  const originCoordinates = []

  if (origin !== null) {
    originCoordinates.push([origin.lon, origin.lat])
  }

  const lines = []
  const points = []
  const drawn = []

  for (const leg of journey.legs) {
    const stopCoordinates = legCoordinates({journey, leg, origin: originCoordinates})
    let coordinates = stopCoordinates
    let properties = {kind: FeatureKind.walk}

    if (leg.kind === LegKind.ride) {
      properties = {kind: FeatureKind.ride, color: routeChip({names, routeId: leg.routeId}).color}
      coordinates = rideLineOf({journey, leg, stopCoordinates, paths, serviceDayStartsMs})
    }

    if (coordinates.length >= LINE_POINT_COUNT_MIN) {
      lines.push(lineFeature({coordinates, properties}))
    }

    for (const coordinate of stopCoordinates) {
      points.push(coordinate)
    }

    for (const coordinate of coordinates) {
      drawn.push(coordinate)
    }
  }

  const features = [...lines]
  const isPlaced = points.length > 0

  if (isPlaced) {
    features.push(pointFeature({coordinate: points[0], kind: FeatureKind.origin}))
    features.push(pointFeature({coordinate: points[points.length - 1], kind: FeatureKind.destination}))
  }

  return {collection: {type: "FeatureCollection", features}, bounds: boundsOf([...points, ...drawn])}
}

// The bounds of `points`, [[west, south], [east, north]], or none.
function boundsOf(points) {
  if (points.length === 0) {
    return {kind: BoundsKind.none}
  }

  let [west, south] = points[0]
  let [east, north] = points[0]

  for (const [lon, lat] of points) {
    west = Math.min(west, lon)
    east = Math.max(east, lon)
    south = Math.min(south, lat)
    north = Math.max(north, lat)
  }

  return {kind: BoundsKind.bounds, bounds: [[west, south], [east, north]]}
}
