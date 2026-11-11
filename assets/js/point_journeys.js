// How the Trip tab routes to a point that is not a stop, such as a place, an
// address, or an intersection, as pure functions. The router routes to one
// stop, so a journey to a point is routed to each of the stops within a
// walk of it, by the snapshot's own walking rules, and the answers meet in
// one frontier once each journey gains the walk from its stop to the point.
// Nothing here fetches or reads a clock; the router's answers arrive as
// arguments.

import {assertCondition, unreachable} from "./assert.js"
import {JourneysKind, WINDOW_SECONDS} from "./routing_journeys.js"
import {startsNear} from "./routing_walk.js"

/** The kind of the walk that ends a journey to a point, after its last stop. */
export const LEG_KIND_TO_POINT = "walkToPoint"

/** The most stops near a point a journey to it is routed to. */
export const TARGET_STOP_COUNT_MAX = 4

/** The kinds of the outcome of routing to a point, beside the router's own. */
export const PointJourneysKind = Object.freeze({found: JourneysKind.found, noEndStop: "noEndStop"})

/**
 * The frontier the answers meet in: the earliest arrival, for a query
 * leaving at a time, or the latest departure, for one arriving by a time.
 */
export const FrontierKind = Object.freeze({earliestArrival: "earliestArrival", latestDeparture: "latestDeparture"})

const SECOND_MS = 1000
const WINDOW_MS = WINDOW_SECONDS * SECOND_MS
const NO_SCORE = Number.NEGATIVE_INFINITY

/**
 * The stops within a walk of `position`, `{lat, lon}` in degrees, at most
 * `countMax`, nearest first, each `{stopId, walkS}`: the stops a journey to
 * the point is routed to, by the walking rules `transferRules` of the
 * snapshot whose stops file is `stopIds` and positions file `positions`.
 */
export function targetStops({position, stopIds, positions, transferRules, countMax}) {
  assertCondition(positions.latMicrodegrees.length === stopIds.length, `point journeys: ${positions.latMicrodegrees.length} positions for ${stopIds.length} stops`)
  assertCondition(Number.isInteger(countMax), "point journeys: the stop bound is not whole: " + countMax)
  const starts = startsNear({position, positions, transferRules})
  const kept = starts.slice(0, countMax)
  return Array.from(kept, (start) => ({stopId: stopIds[start.stop], walkS: start.walkS}))
}

// The milliseconds since the Unix epoch of `seconds` from the start of a
// journey's service date.
function journeyMs({journey, seconds, serviceDayStartsMs}) {
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "point journeys: no start for the service date " + journey.serviceDate)
  return startMs + seconds * SECOND_MS
}

// How good a journey is on the frontier `frontier`, higher better: its
// arrival, negated, for the earliest arrival, and its departure for the
// latest, which a journey arriving by a time carries as `departureS`.
function scoreOf({journey, frontier, serviceDayStartsMs}) {
  switch (frontier) {
    case FrontierKind.earliestArrival:
      return -journeyMs({journey, seconds: journey.arrivalS, serviceDayStartsMs})
    case FrontierKind.latestDeparture:
      assertCondition(Number.isInteger(journey.departureS), "point journeys: a journey arriving by a time has no departure")
      return journeyMs({journey, seconds: journey.departureS, serviceDayStartsMs})
    default:
      return unreachable(frontier, "point journeys: a frontier of unknown kind")
  }
}

// `journey` marked, or not, as the best of the frontier `frontier`.
function marked({journey, frontier, isBest}) {
  if (frontier === FrontierKind.latestDeparture) {
    return {...journey, isLatest: isBest}
  }

  return {...journey, isEarliest: isBest}
}

function walkedJourney({journey, target, destination}) {
  const walk = {kind: LEG_KIND_TO_POINT, fromStopId: target.stopId, durationS: target.walkS}
  return {...journey, arrivalS: journey.arrivalS + target.walkS, legs: [...journey.legs, walk], destination}
}

function byChangesThenScore(left, right) {
  if (left.journey.changes !== right.journey.changes) {
    return left.journey.changes - right.journey.changes
  }

  if (left.score !== right.score) {
    return right.score - left.score
  }

  return left.order - right.order
}

function isNoStartStop(part) {
  return part.answer.kind === JourneysKind.noStartStop
}

function isFailed(part) {
  return part.answer.kind === JourneysKind.failed
}

// The outcome of answers none of which found a journey: a start with no
// stop near it, which every answer shares, or else the first failure, since
// the stops share their snapshot's files, or else no journey.
function unfoundOutcome(routed) {
  const noStart = routed.find(isNoStartStop)

  if (noStart !== undefined) {
    return noStart.answer
  }

  const failure = routed.find(isFailed)

  if (failure !== undefined) {
    return failure.answer
  }

  return {kind: JourneysKind.none}
}

/**
 * The journeys to `destination`, `{name, lat, lon}`, from `routed`, the
 * router's answer to each target stop as `{target: {stopId, walkS}, answer}`:
 * each found journey with a walk of LEG_KIND_TO_POINT from its stop added, its
 * arrival moved by the walk, and `destination` beside it, then the one
 * frontier of them all on one timeline, fewest changes first. On the
 * `frontier` FrontierKind.earliestArrival a journey is kept when it arrives
 * earlier than every one with no more changes, cut at the earliest arrival
 * plus WINDOW_SECONDS, and the earliest is marked `isEarliest`; on
 * FrontierKind.latestDeparture, whose answers arrive at their stops by the
 * time less each stop's walk, a journey is kept when it leaves later than
 * every one with no more changes, cut at the latest departure less the
 * window, and the latest is marked `isLatest`. `serviceDayStartsMs` holds
 * each service date's start. Where no answer found a journey the outcome is
 * a start with no stop near it, else the first failure, else none.
 */
export function journeysToPoint({routed, destination, serviceDayStartsMs, frontier}) {
  assertCondition(routed.length > 0, "point journeys: no stop was routed to")
  const scored = []

  for (const part of routed) {
    if (part.answer.kind !== JourneysKind.found) {
      continue
    }

    for (const journey of part.answer.journeys) {
      const walked = walkedJourney({journey, target: part.target, destination})
      scored.push({journey: walked, score: scoreOf({journey: walked, frontier, serviceDayStartsMs}), order: scored.length})
    }
  }

  if (scored.length === 0) {
    return unfoundOutcome(routed)
  }

  scored.sort(byChangesThenScore)
  const kept = []
  let bestScore = NO_SCORE

  for (const entry of scored) {
    if (entry.score > bestScore) {
      bestScore = entry.score
      kept.push(entry)
    }
  }

  const cutoffScore = bestScore - WINDOW_MS
  const journeys = []

  for (const entry of kept) {
    if (entry.score >= cutoffScore) {
      journeys.push(marked({journey: entry.journey, frontier, isBest: entry.score === bestScore}))
    }
  }

  return {kind: PointJourneysKind.found, journeys}
}
