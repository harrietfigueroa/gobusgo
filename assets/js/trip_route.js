// Routes a trip in the browser from the routing manifest and the snapshot
// files it names, for the Trip tab and the trip planner app: the manifest's
// fetch, the journeys from a start to a stop or to a point by the stops
// within a walk of it, and what a router's answer says to the rider.
//
// Each file is fetched from `origin`, the scheme and host in front of a path
// the manifest names, or "" for the page's own. The rider's position is
// never in a request: a start is the router's argument, and a fetch names
// only a file.

import {assertCondition, unreachable} from "./core/assert.js"
import {FetchKind, FailureReason, FromKind, JourneysKind} from "./core/routing_journeys.js"
import {routeJourneys, routeJourneysArrivingBy} from "./routing_driver.js"
import {EndKind, PlannedKind, StateKind, failureState, isRetryable} from "./core/trip_plan.js"
import {FrontierKind, PointJourneysKind, TARGET_STOP_COUNT_MAX, journeysToPoint, markStraightLineWalks, targetStops, targetStopsOnStreets} from "./core/point_journeys.js"
import {isNotSaved} from "./core/offline_bundle.js"
import {EndWalkKind, PlaceKind, StopsKind, planWalks} from "./trip_walks.js"

const MANIFEST_TIMEOUT_MS = 20 * 1000

/** The kinds of what a router's answer says: journeys to show, or a state to tell the rider. */
export const AnswerKind = Object.freeze({journeys: "journeys", state: "state"})

/**
 * The function that fetches one file the manifest names from `origin`, as
 * the browser caches it: each file's address holds one content, so a cached
 * copy is that file.
 */
export function fetchFileFrom(origin) {
  return async function fetchFile({path, signal}) {
    const response = await fetch(origin + path, {signal, cache: "default", credentials: "same-origin"})

    if (isNotSaved(response)) {
      return {kind: FetchKind.failed, reason: FailureReason.notSaved}
    }

    if (!response.ok) {
      return {kind: FetchKind.failed, reason: FailureReason.fetchFailed}
    }

    const buffer = await response.arrayBuffer()
    return {kind: FetchKind.fetched, buffer}
  }
}

/**
 * The manifest at `path`, revalidated on every call, or why there is none:
 * `{kind: FetchKind.fetched, manifest}` or the router's failure. Its shape
 * is the router's to judge; a body with no snapshots is a failure.
 */
export async function fetchManifest({origin, path}) {
  const signal = AbortSignal.timeout(MANIFEST_TIMEOUT_MS)

  try {
    const response = await fetch(origin + path, {signal, cache: "no-cache", credentials: "same-origin", headers: {accept: "application/json"}})

    if (isNotSaved(response)) {
      return {kind: JourneysKind.failed, reason: FailureReason.notSaved, path}
    }

    if (!response.ok) {
      return {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path}
    }

    const manifest = await response.json()
    const hasSnapshots = typeof manifest === "object" && manifest !== null
    const isManifest = hasSnapshots && Array.isArray(manifest.snapshots)

    if (!isManifest) {
      return {kind: JourneysKind.failed, reason: FailureReason.refused, path}
    }

    return {kind: FetchKind.fetched, manifest}
  } catch (error) {
    console.warn("Routing manifest not fetched", error)
    return {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path}
  }
}

// The journeys of the query to the stop `toStopId` leaving at, or arriving
// by, the time `planned` names, `seconds` being when it leaves or arrives.
async function routeFor({fetchFile, planned, seconds, manifest, from, toStopId}) {
  const {serviceDate} = planned

  switch (planned.kind) {
    case PlannedKind.leaving:
      return await routeJourneys({manifest, serviceDate, departureS: seconds, from, toStopId, fetchFile})
    case PlannedKind.arrivingBy:
      return await routeJourneysArrivingBy({manifest, serviceDate, arrivalS: seconds, from, toStopId, fetchFile})
    default:
      return unreachable(planned.kind, "trip route: a planned time of unknown kind")
  }
}

// The state that says no journey was found for the time `planned` names.
function noneState(planned) {
  if (planned.kind === PlannedKind.arrivingBy) {
    return StateKind.noneInTime
  }

  return JourneysKind.none
}

// The frontier the journeys to a point meet in for the time `planned` names.
function frontierOf(planned) {
  if (planned.kind === PlannedKind.arrivingBy) {
    return FrontierKind.latestDeparture
  }

  return FrontierKind.earliestArrival
}

// The stop identifiers and positions of the manifest entry `entry`, which
// the stops near a point end are found in, or the failure that read them.
async function readSnapshotStops({searchFiles, entry}) {
  try {
    const [stopIds, positions] = await searchFiles.snapshotStops({entry})
    return {kind: StopsKind.read, stopIds, positions}
  } catch (error) {
    console.warn("Snapshot stops not read", error)
    return {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: entry.files.positions.path}
  }
}

/** The walking speed of each service date's snapshot in `manifest`, by its date. */
export function walkSpeedsOf(manifest) {
  const speeds = {}

  for (const entry of manifest.snapshots) {
    speeds[entry.serviceDate] = entry.transferRules.walkSpeedMPerS
  }

  return speeds
}

/** The start of each service date's day in `manifest`, in milliseconds since the epoch, by its date. */
export function serviceDayStartsOf(manifest) {
  const starts = {}

  for (const entry of manifest.snapshots) {
    starts[entry.serviceDate] = entry.serviceDayStartMs
  }

  return starts
}

// The end of a trip as a place a walk is planned from or to: the position
// `end` names, in degrees, where `isPosition`, else none.
function placeOf({isPosition, end}) {
  if (isPosition) {
    return {kind: PlaceKind.position, position: {lat: end.lat, lon: end.lon}}
  }

  return {kind: PlaceKind.absent}
}

// The router's start: `from`, with the stops a walk along the streets
// reached where the start's walk was planned on them.
function startOf({from, walks}) {
  const isOnStreets = from.kind === FromKind.position && walks.start.kind === EndWalkKind.streets

  if (!isOnStreets) {
    return from
  }

  const {stopIds} = walks.stops
  const streetStops = Array.from(walks.start.stops, (reached) => ({stopId: stopIds[reached.stop], streetM: reached.streetM}))
  return {...from, streetStops}
}

// The stops a journey to the point `to` is routed to: those the walk
// planned along the streets reached, or the stops within the walking radius
// in a straight line.
function targetsOf({walk, to, stopIds, positions, transferRules}) {
  if (walk.kind === EndWalkKind.streets) {
    return targetStopsOnStreets({stopIds, stops: walk.stops, transferRules, countMax: TARGET_STOP_COUNT_MAX})
  }

  return targetStops({position: {lat: to.lat, lon: to.lon}, stopIds, positions, transferRules, countMax: TARGET_STOP_COUNT_MAX})
}

// Says once, at the decision, which ends of the trip fell back to a straight
// line; a position is never logged.
function logFallbacks(walks) {
  for (const [end, walk] of [["start", walks.start], ["destination", walks.destination]]) {
    if (walk.kind === EndWalkKind.fallback) {
      console.warn("Walk planned as a straight line", {end, reason: walk.reason})
    }
  }
}

// `answer`, where it found journeys, with each journey's walk marked as a
// straight line where an end's walk fell back to one.
function markedAnswer({answer, walks}) {
  if (answer.kind !== JourneysKind.found) {
    return answer
  }

  const journeys = markStraightLineWalks({
    journeys: answer.journeys,
    isStartStraight: walks.start.kind === EndWalkKind.fallback,
    isEndStraight: walks.destination.kind === EndWalkKind.fallback
  })

  return {...answer, journeys}
}

/**
 * The journeys from `from`, the router's start, to `to`, a stop end or a
 * point end, for the time `planned` names, fetched from `origin`: to a point,
 * the journeys to each stop within a walk of it, arriving there by the time
 * less the walk for a trip arriving by a time, joined in one frontier.
 * `searchFiles` reads the stops a point's neighbors are found in, and
 * `walkTiles` is the page's walk graph tiles, which a walk from the
 * position or to the point is planned over where the snapshot's walks follow
 * the streets; where they cannot be had the walk is a straight line and each
 * journey with such a walk has `hasStraightLineWalk`.
 */
export async function routeTo({origin, searchFiles, walkTiles, manifest, planned, from, to}) {
  const {serviceDate} = planned
  const fetchFile = fetchFileFrom(origin)
  const isFromPosition = from.kind === FromKind.position
  const isToStop = to.kind === EndKind.stop

  const isStopToStop = isToStop && !isFromPosition

  if (isStopToStop) {
    return await routeFor({fetchFile, planned, seconds: planned.seconds, manifest, from, toStopId: to.stopId})
  }

  const entry = manifest.snapshots.find((candidate) => candidate.serviceDate === serviceDate)
  assertCondition(entry !== undefined, "trip route: the manifest holds no snapshot of the service date " + serviceDate)

  const walks = await planWalks({
    walkTiles,
    entry,
    readStops: () => readSnapshotStops({searchFiles, entry}),
    start: placeOf({isPosition: isFromPosition, end: from}),
    destination: placeOf({isPosition: !isToStop, end: to})
  })

  logFallbacks(walks)

  if (isToStop) {
    const answer = await routeFor({fetchFile, planned, seconds: planned.seconds, manifest, from: startOf({from, walks}), toStopId: to.stopId})
    return markedAnswer({answer, walks})
  }

  if (walks.stops.kind === JourneysKind.failed) {
    return walks.stops
  }

  const {stopIds, positions} = walks.stops
  const targets = targetsOf({walk: walks.destination, to, stopIds, positions, transferRules: entry.transferRules})

  if (targets.length === 0) {
    return {kind: PointJourneysKind.noEndStop}
  }

  const routed = []
  const routeFrom = startOf({from, walks})

  for (const target of targets) {
    let seconds = planned.seconds

    if (planned.kind === PlannedKind.arrivingBy) {
      seconds -= target.walkS
    }

    const answer = await routeFor({fetchFile, planned, seconds, manifest, from: routeFrom, toStopId: target.stopId})
    routed.push({target, answer})
  }

  const destination = {name: to.name, lat: to.lat, lon: to.lon}
  const joined = journeysToPoint({routed, destination, serviceDayStartsMs: serviceDayStartsOf(manifest), frontier: frontierOf(planned)})
  return markedAnswer({answer: joined, walks})
}

/**
 * What `answer`, a router's answer for the time `planned` names, says to the
 * rider: `{kind: AnswerKind.journeys, journeys}` for a found one, or
 * `{kind: AnswerKind.state, state, isRetry}` with the StateKind member that
 * says why there are none and whether trying again can help.
 */
export function answerOutcome({answer, planned}) {
  switch (answer.kind) {
    case JourneysKind.found:
      return {kind: AnswerKind.journeys, journeys: answer.journeys}
    case JourneysKind.failed:
      return {kind: AnswerKind.state, state: failureState(answer), isRetry: isRetryable(answer)}
    case JourneysKind.none:
      return {kind: AnswerKind.state, state: noneState(planned), isRetry: false}
    case JourneysKind.unknownStop:
    case JourneysKind.noStartStop:
      return {kind: AnswerKind.state, state: answer.kind, isRetry: false}
    case PointJourneysKind.noEndStop:
      return {kind: AnswerKind.state, state: StateKind.noEndStop, isRetry: false}
    default:
      return unreachable(answer.kind, "trip route: an answer of unknown kind")
  }
}
