// What the Trip tab's journey cards decide, as pure functions: which stops'
// live arrivals the tab asks for, which arrival is a journey's first bus and
// how late it runs, what a card leads with, the bar of its walks, waits,
// and rides, and the order of the cards under each sort. Nothing here reads
// the document, the network, storage, or a clock: the arrivals, the time,
// and the time zone arrive as arguments.
//
// A card's times move with its first bus: where the arrival of the first
// ride's trip at its boarding stop holds a prediction, the leave time and
// the arrival move by that bus's lateness, and otherwise they read the
// schedule.

import {assertCondition, unreachable} from "./assert.js"
import {LegKind} from "./routing_engine.js"
import {LEG_KIND_TO_POINT} from "./point_journeys.js"
import {clockText, journeyLeaveS, routeChip} from "./trip_plan.js"

/** The sorts of the journey list. */
export const SortKind = Object.freeze({soonest: "soonest", fewestChanges: "fewestChanges", leastWalking: "leastWalking"})

/** The label of each sort's button. */
export const SORT_LABELS = Object.freeze({[SortKind.soonest]: "Soonest", [SortKind.fewestChanges]: "Fewest changes", [SortKind.leastWalking]: "Least walking"})

/** What a journey's first bus is known by: a live lateness, the schedule alone, or no ride at all. */
export const LiveKind = Object.freeze({live: "live", scheduled: "scheduled", noRide: "noRide"})

/** The kinds of a segment of a card's bar. */
export const SegmentKind = Object.freeze({ride: "ride", walk: "walk", wait: "wait"})

const SECOND_MS = 1000
const MINUTE_S = 60
const MINUTE_MS = MINUTE_S * SECOND_MS
const LEAD_MINUTES_MAX = 60
// How far from a ride's scheduled departure an arrival of its trip may be
// scheduled and still be that ride: the arrival's time at a stop can be its
// arrival where the ride's is its departure, a dwell apart.
const MATCH_TOLERANCE_MINUTES = 5
const MATCH_TOLERANCE_MS = MATCH_TOLERANCE_MINUTES * MINUTE_MS
const ARRIVALS_STATUS = "arrivals"
const WALK_ONLY_TEXT = "Walk only"
const SEPARATOR = " · "

function firstRide(journey) {
  for (const leg of journey.legs) {
    if (leg.kind === LegKind.ride) {
      return {kind: LiveKind.live, leg}
    }
  }

  return {kind: LiveKind.noRide}
}

/**
 * The stops whose live arrivals the tab asks for for `journeys`: each
 * journey's first ride's boarding stop, once each, in the order of the
 * journeys, at most `countMax`. A journey with no ride names none.
 */
export function liveStopIds({journeys, countMax}) {
  assertCondition(Number.isInteger(countMax), "journey cards: the stop bound is not whole: " + countMax)
  const stopIds = []

  for (const journey of journeys) {
    const first = firstRide(journey)
    const isNamed = first.kind === LiveKind.live && stopIds.includes(first.leg.fromStopId) === false
    const isRoom = stopIds.length < countMax
    const isAdded = isNamed && isRoom

    if (isAdded) {
      stopIds.push(first.leg.fromStopId)
    }
  }

  return stopIds
}

/**
 * Whether `arrival` is of the ride's trip near the ride's scheduled
 * departure, `departureMs`, whether its time is predicted or scheduled.
 */
export function isRideRun({arrival, tripId, departureMs}) {
  const isTrip = arrival.trip_id === tripId
  const isNear = Math.abs(arrival.scheduled_ms - departureMs) <= MATCH_TOLERANCE_MS
  return isTrip && isNear
}

// Whether `arrival` is the predicted arrival of the ride's trip near the
// ride's scheduled departure, `departureMs`.
function isRideArrival({arrival, tripId, departureMs}) {
  const isRun = isRideRun({arrival, tripId, departureMs})
  return isRun && arrival.predicted === true
}

/**
 * What `journey`'s first bus is known by from `shownByStop`, the latest
 * "stop-arrivals:arrivals" answer of each stop by identifier: a LiveKind
 * member, live with `latenessS`, the prediction less the schedule, where
 * the first ride's boarding stop holds a predicted arrival of its trip near
 * its scheduled departure; scheduled otherwise; or no ride. Both name the
 * ride's `routeId`. `serviceDayStartsMs` holds each service date's start.
 */
export function firstRideLive({journey, shownByStop, serviceDayStartsMs}) {
  const first = firstRide(journey)

  if (first.kind === LiveKind.noRide) {
    return first
  }

  const {leg} = first
  const scheduled = {kind: LiveKind.scheduled, routeId: leg.routeId}
  const shown = shownByStop[leg.fromStopId]
  const hasArrivals = shown !== undefined && shown.status === ARRIVALS_STATUS

  if (!hasArrivals) {
    return scheduled
  }

  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "journey cards: no start for the service date " + journey.serviceDate)
  const departureMs = startMs + leg.departureS * SECOND_MS
  const arrival = shown.arrivals.find((candidate) => isRideArrival({arrival: candidate, tripId: leg.tripId, departureMs}))

  if (arrival === undefined) {
    return scheduled
  }

  const latenessS = Math.round((arrival.time_ms - arrival.scheduled_ms) / SECOND_MS)
  return {kind: LiveKind.live, latenessS, routeId: leg.routeId}
}

/**
 * How far the first bus is from its schedule, in milliseconds, where `live`
 * is a `firstRideLive` answer: its lateness where the bus is live, and none
 * where it is scheduled or the journey has no ride.
 */
export function liveShiftMs(live) {
  if (live.kind === LiveKind.live) {
    return live.latenessS * SECOND_MS
  }

  return 0
}

/** A lateness in whole minutes, late positive and early negative. */
export function latenessMinutes(latenessS) {
  return Math.round(latenessS / MINUTE_S)
}

/** The text of a lateness in whole minutes: on time, late, or early. */
export function latenessText(latenessS) {
  const minutes = latenessMinutes(latenessS)

  if (minutes === 0) {
    return "on time"
  } else if (minutes > 0) {
    return `${minutes} min late`
  }

  return `${-minutes} min early`
}

/**
 * The text of a journey's first bus: its route and its lateness, or that it
 * is scheduled, or that the journey only walks.
 */
export function firstBusText({live, names}) {
  switch (live.kind) {
    case LiveKind.live:
      return `${routeChip({names, routeId: live.routeId}).name} ${latenessText(live.latenessS)}`
    case LiveKind.scheduled:
      return `${routeChip({names, routeId: live.routeId}).name} scheduled`
    case LiveKind.noRide:
      return WALK_ONLY_TEXT
    default:
      return unreachable(live.kind, "journey cards: a first bus of unknown kind")
  }
}

function leadText({leaveMs, nowMs, dayPhrase, timeZone}) {
  const minutes = Math.floor((leaveMs - nowMs) / MINUTE_MS)

  if (minutes <= 0) {
    return "Leave now"
  } else if (minutes < LEAD_MINUTES_MAX) {
    return `Leave in ${minutes} min`
  }

  return `Leave ${dayPhrase}at ${clockText({ms: leaveMs, timeZone})}`
}

function walkSecondsOf(journey) {
  let walkS = 0

  for (const leg of journey.legs) {
    if (leg.kind !== LegKind.ride) {
      walkS += leg.durationS
    }
  }

  return walkS
}

/**
 * The card of `row`, a row of `journeyRows`, at `order` among the rows,
 * whose first bus `live` is from `firstRideLive`, at `nowMs`: `leadText`,
 * when to leave, "Leave now", "Leave in 4 min", or a clock time an hour or
 * more ahead with its day where it is not today; `arriveText`; `isLive`;
 * `detailText`, the first bus's lateness or that it is scheduled, and the
 * changes; `segments`, the bar's; and what the sorts read, `leaveMs` and
 * `arrivalMs`, both moved by a live lateness, `changes`, `walkS`, and
 * `order`.
 */
export function journeyCard({row, order, live, nowMs, serviceDayStartsMs, names, timeZone}) {
  assertCondition(Number.isInteger(order), "journey cards: a card's order is not whole: " + order)
  const {journey} = row
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "journey cards: no start for the service date " + journey.serviceDate)
  const shiftMs = liveShiftMs(live)
  const leaveMs = startMs + journeyLeaveS(journey) * SECOND_MS + shiftMs
  const arrivalMs = startMs + journey.arrivalS * SECOND_MS + shiftMs

  return {
    row,
    order,
    leadText: leadText({leaveMs, nowMs, dayPhrase: row.dayPhrase, timeZone}),
    arriveText: `arrive ${clockText({ms: arrivalMs, timeZone})}`,
    isLive: live.kind === LiveKind.live,
    detailText: firstBusText({live, names}) + SEPARATOR + row.changesText,
    segments: barSegments({journey, names}),
    leaveMs,
    arrivalMs,
    changes: journey.changes,
    walkS: walkSecondsOf(journey),
  }
}

/**
 * The bar of `journey`: each walk, wait, and ride in the order taken, from
 * its leave time to its arrival, each `{kind, durationS}` with a ride's
 * route `name` and `color` from `names`, a SegmentKind member each. A
 * segment of no time is left out.
 */
export function barSegments({journey, names}) {
  const segments = []
  let atS = journeyLeaveS(journey)

  for (const leg of journey.legs) {
    switch (leg.kind) {
      case LegKind.ride: {
        const waitS = leg.departureS - atS

        if (waitS > 0) {
          segments.push({kind: SegmentKind.wait, durationS: waitS})
        }

        const chip = routeChip({names, routeId: leg.routeId})
        segments.push({kind: SegmentKind.ride, durationS: leg.arrivalS - leg.departureS, name: chip.name, color: chip.color})
        atS = leg.arrivalS
        break
      }
      case LegKind.walk:
      case LegKind.walkFromPosition:
      case LEG_KIND_TO_POINT:
        if (leg.durationS > 0) {
          segments.push({kind: SegmentKind.walk, durationS: leg.durationS})
        }

        atS += leg.durationS
        break
      default:
        unreachable(leg.kind, "journey cards: a leg of unknown kind")
    }
  }

  return segments
}

// The key each sort orders by, lower first.
function sortKeyOf({card, sort}) {
  switch (sort) {
    case SortKind.soonest:
      return card.arrivalMs
    case SortKind.fewestChanges:
      return card.changes
    case SortKind.leastWalking:
      return card.walkS
    default:
      return unreachable(sort, "journey cards: a sort of unknown kind")
  }
}

/**
 * `cards` in the order `sort`, a SortKind member, gives them: Soonest by
 * the arrival, live where the card is live; Fewest changes by the changes;
 * Least walking by the seconds walked; cards that tie keep their `order`.
 */
export function sortedCards({cards, sort}) {
  assertCondition(Object.hasOwn(SORT_LABELS, sort), "journey cards: a sort of unknown kind " + sort)
  const keyed = Array.from(cards, (card) => ({card, key: sortKeyOf({card, sort})}))
  // The copy is sorted because `sort` reorders an array in place.
  keyed.sort(byKeyThenOrder)
  return Array.from(keyed, cardOfKeyed)
}

function byKeyThenOrder(left, right) {
  if (left.key !== right.key) {
    return left.key - right.key
  }

  return left.card.order - right.card.order
}

function cardOfKeyed(keyed) {
  return keyed.card
}
