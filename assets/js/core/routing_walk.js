// The stops a rider at a position can walk to before a first ride, by the
// rules of a snapshot's walking links, so a journey can start from the
// rider's position with no request: the position stays in the browser.
// Everything here is pure.
//
// A stop is a start when it lies within the snapshot's walking radius in a
// straight line, and its walk takes that distance at the snapshot's walking
// speed, rounded up to the second. The nearest are kept, at most as many as
// the walking links a stop keeps.
//
// Where the snapshot's links are measured along the streets, a walk from a
// position is too: the stops within the straight-line radius are the
// candidates, and the street meters the walk graph gives them decide which
// are starts and how long each walk takes.

import {assertCondition, unreachable} from "./assert.js"
import {distanceMeters} from "./math/geodesy.js"
import {POSITION_UNKNOWN_MICRODEGREES} from "./routing_snapshot.js"

/**
 * How a snapshot's walking links are measured: along a straight line, along
 * the streets of the walk graph, or a mix of the two, a table that stands in
 * for one not current, whose links to a stop new or moved since are straight.
 */
export const WalkBasis = Object.freeze({straight: "straight", streets: "streets", mixed: "mixed"})

/** The most candidates a walk from a position over the streets searches for, the nearest in a straight line. */
export const WALK_CANDIDATE_COUNT_MAX = 256

const MICRODEGREES_PER_DEGREE = 1000000
const LAT_DEGREES_MAX = 90
const LON_DEGREES_MAX = 180

function byDistance(left, right) {
  if (left.distanceM !== right.distanceM) {
    return left.distanceM - right.distanceM
  }

  return left.stop - right.stop
}

function assertPosition(position) {
  assertCondition(Number.isFinite(position.lat), "routing walk: the position's latitude is not a number: " + position.lat)
  assertCondition(Number.isFinite(position.lon), "routing walk: the position's longitude is not a number: " + position.lon)
  assertCondition(Math.abs(position.lat) <= LAT_DEGREES_MAX, "routing walk: the position's latitude is out of range: " + position.lat)
  assertCondition(Math.abs(position.lon) <= LON_DEGREES_MAX, "routing walk: the position's longitude is out of range: " + position.lon)
}

function assertRules(transferRules) {
  assertCondition(transferRules.walkRadiusM > 0, "routing walk: the walking radius is not positive: " + transferRules.walkRadiusM)
  assertCondition(transferRules.walkSpeedMPerS > 0, "routing walk: the walking speed is not positive: " + transferRules.walkSpeedMPerS)
  assertCondition(Number.isInteger(transferRules.walkLinkCountPerStopMax), "routing walk: the link count is not whole: " + transferRules.walkLinkCountPerStopMax)
}

// The stops with a known position within the walking radius of `position`
// in a straight line, each `{stop, distanceM, lat, lon}`, nearest first.
function stopsWithin({position, positions, transferRules}) {
  assertPosition(position)
  assertRules(transferRules)
  const {latMicrodegrees, lonMicrodegrees} = positions
  const riderPosition = [position.lon, position.lat]
  assertCondition(latMicrodegrees.length === lonMicrodegrees.length, "routing walk: the position columns differ in length")
  const near = []

  for (let stop = 0; stop < latMicrodegrees.length; stop++) {
    if (latMicrodegrees[stop] === POSITION_UNKNOWN_MICRODEGREES) {
      continue
    }

    const lat = latMicrodegrees[stop] / MICRODEGREES_PER_DEGREE
    const lon = lonMicrodegrees[stop] / MICRODEGREES_PER_DEGREE
    const stopDistanceM = distanceMeters(riderPosition, [lon, lat])

    if (stopDistanceM <= transferRules.walkRadiusM) {
      near.push({stop, distanceM: stopDistanceM, lat, lon})
    }
  }

  near.sort(byDistance)
  return near
}

/**
 * The basis of `transferRules`, a manifest entry's. A manifest that names
 * none, one this reader does not know, or a streets or mixed basis whose
 * `walkStreetMetersMax` is not a positive finite number, is a straight-line
 * table.
 */
export function walkBasisOf(transferRules) {
  const {walkBasis, walkStreetMetersMax} = transferRules

  const isText = typeof walkBasis === "string"
  const isKnown = isText && Object.hasOwn(WalkBasis, walkBasis)

  if (!isKnown) {
    return WalkBasis.straight
  }

  const isStraight = walkBasis === WalkBasis.straight
  const isBoundNumber = Number.isFinite(walkStreetMetersMax)
  const isBounded = isBoundNumber && walkStreetMetersMax > 0

  const isUsable = isStraight || isBounded

  if (isUsable) {
    return walkBasis
  }

  return WalkBasis.straight
}

/**
 * Whether a walk from a position or to a point is planned along the streets
 * under `basis`, a WalkBasis member. A mixed table is planned on the streets
 * too: the walk graph the page reads is the one a walk is drawn along, and
 * the stops a mixed table has no measure of are the table's own limit, which
 * a rider's own walk does not inherit.
 */
export function isStreetWalk(basis) {
  switch (basis) {
    case WalkBasis.straight:
      return false
    case WalkBasis.streets:
    case WalkBasis.mixed:
      return true
    default:
      return unreachable(basis, "routing walk: a walking basis of unknown kind")
  }
}

/**
 * The street length, in meters, that a walk over the streets may have under
 * `transferRules`, which names it as `walkStreetMetersMax` for the streets
 * and for a mix.
 */
export function streetMetersMaxOf(transferRules) {
  const meters = transferRules.walkStreetMetersMax
  assertCondition(Number.isFinite(meters), "routing walk: the street length bound is not a number: " + meters)
  assertCondition(meters > 0, "routing walk: the street length bound is not positive: " + meters)
  return meters
}

/**
 * The start stops within walking distance of `position`, in degrees, from
 * `positions`, a decoded positions file, under `transferRules`, the
 * manifest entry's: each stop index with the whole seconds of its walk,
 * nearest first. Stops with no known position are never starts.
 */
export function startsNear({position, positions, transferRules}) {
  const near = stopsWithin({position, positions, transferRules})
  const kept = near.slice(0, transferRules.walkLinkCountPerStopMax)
  const starts = []

  for (const candidate of kept) {
    const walkS = Math.ceil(candidate.distanceM / transferRules.walkSpeedMPerS)
    starts.push({stop: candidate.stop, walkS})
  }

  return starts
}

/**
 * The stops a walk from `position` over the streets searches among: those
 * within the walking radius in a straight line, nearest first, at most
 * WALK_CANDIDATE_COUNT_MAX, each `{stop, lat, lon}`.
 */
export function walkCandidatesNear({position, positions, transferRules}) {
  const near = stopsWithin({position, positions, transferRules})
  const kept = near.slice(0, WALK_CANDIDATE_COUNT_MAX)
  return Array.from(kept, candidateOf)
}

function candidateOf(near) {
  return {stop: near.stop, lat: near.lat, lon: near.lon}
}

function byStreetMeters(left, right) {
  if (left.streetM !== right.streetM) {
    return left.streetM - right.streetM
  }

  return left.stop - right.stop
}

/**
 * The start stops of a walk over the streets: `stops`, the `{stop, streetM}`
 * of a found reach, each with the whole seconds of its walk at the
 * snapshot's walking speed, nearest by street first, at most the walking
 * links a stop keeps, as `startsNear` answers them.
 */
export function startsFromStreets({stops, transferRules}) {
  assertRules(transferRules)
  // The copy is sorted because `sort` reorders an array in place.
  const ordered = Array.from(stops)
  ordered.sort(byStreetMeters)
  const kept = ordered.slice(0, transferRules.walkLinkCountPerStopMax)
  const starts = []

  for (const candidate of kept) {
    const walkS = Math.ceil(candidate.streetM / transferRules.walkSpeedMPerS)
    starts.push({stop: candidate.stop, walkS})
  }

  return starts
}
