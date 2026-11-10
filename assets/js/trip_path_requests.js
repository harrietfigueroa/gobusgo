// How the vehicle page asks the server for trip paths, as pure functions of
// the requests' state, the page's path cache, the trips it wants, and the
// time: one request at a time, never a trip the cache holds, a trip the
// server has no path for left out until its retry time, and a busy or
// failed answer backed off until its own. Nothing here sends, waits, or
// keeps time: the page asks again when it next decides what it animates.

import {assertCondition} from "./assert.js"
import {decodeTripPath, tripPathKey, tripPathRequest} from "./trip_path.js"

/** How long a trip the server has no path for is left out: its route's path or schedule can arrive meanwhile. */
export const MISSING_PATH_RETRY_MS = 2 * 60 * 1000

/** How long after a busy answer the page asks again. */
export const BUSY_RETRY_MS = 5 * 1000

/** How long after a build that failed the page asks again. */
export const FAILED_RETRY_MS = 15 * 1000

/** How long a request with no answer is waited for: three times the server's build deadline of 5 s. */
export const PENDING_WAIT_MS = 15 * 1000

/** The most trips with no path held at once, the earliest leaving first. */
export const MISSING_TRIP_COUNT_MAX = 300

/** Whether the page sends a request now, or none. */
export const PathRequestKind = Object.freeze({request: "request", none: "none"})

const NONE = Object.freeze({kind: PathRequestKind.none})
// The fewest points and stops a path the prediction takes holds.
const PATH_PART_COUNT_MIN = 2

function assertTime(nowMs) {
  assertCondition(Number.isFinite(nowMs), `a time ${nowMs} is a number`)
}

/** The state of a page that has asked for nothing. */
export function emptyPathRequests() {
  return Object.freeze({pendingSinceMs: null, retryAtMs: 0, missingUntilMs: new Map()})
}

function isPending({requests, nowMs}) {
  if (requests.pendingSinceMs === null) {
    return false
  }

  return nowMs < requests.pendingSinceMs + PENDING_WAIT_MS
}

function isMissing({requests, key, nowMs}) {
  const untilMs = requests.missingUntilMs.get(key)

  if (untilMs === undefined) {
    return false
  }

  return nowMs < untilMs
}

/**
 * The request to send now for `trips`, each with its `tripId`, `routeId`,
 * and `serviceDateMs`: the trips `cache` lacks and no missing answer
 * holds back, at most 100, with the state that follows sending it; or none
 * while a request runs, before a retry time, or when no trip is left.
 */
export function nextPathRequest({requests, cache, trips, nowMs}) {
  assertTime(nowMs)
  const isWaiting = nowMs < requests.retryAtMs
  const isHeld = isWaiting || isPending({requests, nowMs})

  if (isHeld) {
    return NONE
  }

  const wanted = []

  for (const trip of trips) {
    const key = tripPathKey(trip)

    if (!isMissing({requests, key, nowMs})) {
      wanted.push(trip)
    }
  }

  const requested = tripPathRequest(cache, wanted)

  if (requested.length === 0) {
    return NONE
  }

  const next = Object.freeze({...requests, pendingSinceMs: nowMs})
  return Object.freeze({kind: PathRequestKind.request, trips: requested, requests: next})
}

/**
 * The state after the server's reply to a request: an accepted request
 * still runs, and a busy one is asked again after its retry time. A
 * refused request is a programmer error, since the page sends only trips
 * it has checked.
 */
export function pathRequestReplied({requests, reply, nowMs}) {
  assertTime(nowMs)
  assertCondition(reply.refused !== true, "the server refused a request for trip paths")

  if (reply.busy === true) {
    return Object.freeze({...requests, pendingSinceMs: null, retryAtMs: nowMs + BUSY_RETRY_MS})
  }

  assertCondition(reply.accepted === true, "a reply to a request for trip paths is accepted, busy, or refused")
  return requests
}

function withMissing({missingUntilMs, keys, untilMs}) {
  const next = new Map(missingUntilMs)

  for (const key of keys) {
    next.delete(key)
    next.set(key, untilMs)
  }

  for (const key of next.keys()) {
    if (next.size <= MISSING_TRIP_COUNT_MAX) {
      break
    }
    next.delete(key)
  }

  return next
}

function isPreparable(path) {
  const hasPoints = path.points.length >= PATH_PART_COUNT_MIN
  const hasStops = path.stops.length >= PATH_PART_COUNT_MIN
  const isPreparableShape = hasPoints && hasStops
  return isPreparableShape
}

/**
 * The paths of a `trip-paths:paths` event, decoded, and the state after
 * it: a failed build is asked again after its retry time, and each trip
 * named missing, or whose path holds fewer than two points or stops, is
 * left out until its own.
 */
export function pathsReceived({requests, event, nowMs}) {
  assertTime(nowMs)

  if (typeof event.failed === "string") {
    const failed = Object.freeze({...requests, pendingSinceMs: null, retryAtMs: nowMs + FAILED_RETRY_MS})
    return Object.freeze({requests: failed, paths: Object.freeze([])})
  }

  const paths = []
  const missingKeys = []

  for (const raw of event.paths) {
    const path = decodeTripPath(raw)

    if (isPreparable(path)) {
      paths.push(path)
    } else {
      missingKeys.push(path.key)
    }
  }

  for (const {trip_id: tripId, service_date_ms: serviceDateMs} of event.missing) {
    missingKeys.push(tripPathKey({tripId, serviceDateMs}))
  }

  const missingUntilMs = withMissing({missingUntilMs: requests.missingUntilMs, keys: missingKeys, untilMs: nowMs + MISSING_PATH_RETRY_MS})
  const next = Object.freeze({...requests, pendingSinceMs: null, missingUntilMs})
  return Object.freeze({requests: next, paths: Object.freeze(paths)})
}
