// The line a ride is drawn along: the trip's path cut from its boarding
// stop's distance along it to its alighting stop's. Everything here is pure:
// the decoded path, the leg, and the stops' positions are given as values,
// and a ride the path cannot serve answers with the reason, so the caller
// keeps the line through the ride's stops.

import {assertCondition} from "./assert.js"
import {distanceMeters} from "./math/geodesy.js"
import {COORDINATES_PER_POINT, POINT_X, POINT_Y, pointsBetween} from "./math/polyline.js"

/** Whether a ride follows its trip's path or keeps the line through its stops. */
export const RideLineKind = Object.freeze({slice: "slice", fallback: "fallback"})

/** Why a ride keeps the line through its stops. */
export const FallbackReason = Object.freeze({
  indexOutOfRange: "indexOutOfRange",
  stopCountMismatch: "stopCountMismatch",
  noDistance: "noDistance",
  pathTooShort: "pathTooShort",
  distanceOutOfRange: "distanceOutOfRange",
  unplaced: "unplaced",
  detached: "detached"
})

/**
 * How far past the end of a path a stop's distance may lie and still be the
 * end: the distances are sums of haversine distances over the same points,
 * so a stop at the end differs from the path's length by rounding alone.
 */
export const DISTANCE_SLACK_METERS = 1

/**
 * How far a stop may stand from the point its distance cuts the path at.
 * A stop stands beside the road it is served from, and a pattern whose stops
 * are not the leg's cuts the path a stop spacing or more away.
 */
export const DETACHED_METERS_MAX = 200

const PATH_POINT_COUNT_MIN = 2
const CheckKind = Object.freeze({passed: "passed", failed: "failed"})
const PASSED = Object.freeze({kind: CheckKind.passed})

function failed(reason) {
  return {kind: CheckKind.failed, reason}
}

// The path's points as the interleaved longitudes and latitudes the polyline
// module takes, and the distance along the path at each.
function lineOfPath(points) {
  const coordinates = new Float64Array(points.length * COORDINATES_PER_POINT)
  const cumulative = new Float64Array(points.length)

  for (const [index, point] of points.entries()) {
    coordinates[index * COORDINATES_PER_POINT + POINT_X] = point[POINT_X]
    coordinates[index * COORDINATES_PER_POINT + POINT_Y] = point[POINT_Y]

    if (index > 0) {
      cumulative[index] = cumulative[index - 1] + distanceMeters(points[index - 1], point)
    }
  }

  return {coordinates, cumulative}
}

// Whether the end of the cut at `end` stands within DETACHED_METERS_MAX of
// the stop `stopId`.
function attachment({stopPositions, stopId, end}) {
  const stop = stopPositions[stopId]

  if (stop === undefined) {
    return failed(FallbackReason.unplaced)
  }

  const meters = distanceMeters([stop.lon, stop.lat], end)
  const isAttached = meters <= DETACHED_METERS_MAX

  if (!isAttached) {
    return failed(FallbackReason.detached)
  }

  return PASSED
}

// Whether the stops' distances make a stretch of a path of `length`.
function distanceCheck({from, to, length}) {
  const hasStretch = to > from

  if (!hasStretch) {
    return failed(FallbackReason.noDistance)
  }

  const isInside = to <= length + DISTANCE_SLACK_METERS

  if (!isInside) {
    return failed(FallbackReason.distanceOutOfRange)
  }

  return PASSED
}

// Whether `leg` lies on the pattern of `path`, before any point is cut.
function legCheck({path, leg, boardIndex, alightIndex}) {
  const hopCount = leg.stopIds.length - 1
  const isLegHops = alightIndex - boardIndex === hopCount

  if (!isLegHops) {
    return failed(FallbackReason.stopCountMismatch)
  }

  const isInPattern = alightIndex < path.stops.length

  if (!isInPattern) {
    return failed(FallbackReason.indexOutOfRange)
  }

  const isLine = path.points.length >= PATH_POINT_COUNT_MIN

  if (!isLine) {
    return failed(FallbackReason.pathTooShort)
  }

  return PASSED
}

function fallback(check) {
  return {kind: RideLineKind.fallback, reason: check.reason}
}

/**
 * The line of `leg`, a ride with `boardSequence` and `alightSequence`, the
 * positions in its trip of the hops it boards and leaves at, over `path`,
 * the trip's decoded path. A hop's position is the position of the stop it
 * leaves, so the ride boards the pattern's stop `boardSequence` and leaves
 * its stop `alightSequence + 1`. `stopPositions` holds each stop's `{lat,
 * lon}`. The answer is `{kind: RideLineKind.slice, coordinates}`, the
 * `[lon, lat]` points of the path from the boarding stop's distance to the
 * alighting stop's, the two ends interpolated; or `{kind:
 * RideLineKind.fallback, reason}` with a FallbackReason where the path does
 * not serve the leg: the pattern's stops are not the leg's, two stops stand
 * at one distance, a distance lies past the path, the path has one point, or
 * a stop has no position or stands far from the cut.
 */
export function ridePathLine({path, leg, stopPositions}) {
  assertCondition(Number.isSafeInteger(leg.boardSequence), "ride path: a leg's boarding sequence is an integer: " + leg.boardSequence)
  assertCondition(Number.isSafeInteger(leg.alightSequence), "ride path: a leg's alighting sequence is an integer: " + leg.alightSequence)
  assertCondition(leg.boardSequence >= 0, "ride path: a leg's boarding sequence is a position in its trip: " + leg.boardSequence)
  assertCondition(leg.alightSequence >= leg.boardSequence, "ride path: a leg alights at or after the hop it boards: " + leg.alightSequence)
  const boardIndex = leg.boardSequence
  const alightIndex = leg.alightSequence + 1
  const legChecked = legCheck({path, leg, boardIndex, alightIndex})

  if (legChecked.kind === CheckKind.failed) {
    return fallback(legChecked)
  }

  const {coordinates, cumulative} = lineOfPath(path.points)
  const from = path.stops[boardIndex].distanceMeters
  const to = path.stops[alightIndex].distanceMeters
  const distanceChecked = distanceCheck({from, to, length: cumulative[cumulative.length - 1]})

  if (distanceChecked.kind === CheckKind.failed) {
    return fallback(distanceChecked)
  }

  const cut = pointsBetween({coordinates, cumulative, from, to})
  assertCondition(cut.length >= PATH_POINT_COUNT_MIN, "ride path: a cut between two distances has two ends")
  const boarding = attachment({stopPositions, stopId: leg.fromStopId, end: cut[0]})

  if (boarding.kind === CheckKind.failed) {
    return fallback(boarding)
  }

  const alighting = attachment({stopPositions, stopId: leg.toStopId, end: cut[cut.length - 1]})

  if (alighting.kind === CheckKind.failed) {
    return fallback(alighting)
  }

  return {kind: RideLineKind.slice, coordinates: cut}
}
