// The stops a rider at a position can walk to before a first ride, by the
// rules of a snapshot's walking links, so a journey can start from the
// rider's position with no request: the position stays in the browser.
// Everything here is pure.
//
// A stop is a start when it lies within the snapshot's walking radius in a
// straight line, and its walk takes that distance at the snapshot's walking
// speed, rounded up to the second. The nearest are kept, at most as many as
// the walking links a stop keeps.

import {assertCondition} from "./assert.js"
import {distanceMeters} from "./math/geodesy.js"
import {POSITION_UNKNOWN_MICRODEGREES} from "./routing_snapshot.js"

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

/**
 * The start stops within walking distance of `position`, in degrees, from
 * `positions`, a decoded positions file, under `transferRules`, the
 * manifest entry's: each stop index with the whole seconds of its walk,
 * nearest first. Stops with no known position are never starts.
 */
export function startsNear({position, positions, transferRules}) {
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

    const stopPosition = [lonMicrodegrees[stop] / MICRODEGREES_PER_DEGREE, latMicrodegrees[stop] / MICRODEGREES_PER_DEGREE]
    const stopDistanceM = distanceMeters(riderPosition, stopPosition)

    if (stopDistanceM <= transferRules.walkRadiusM) {
      near.push({stop, distanceM: stopDistanceM})
    }
  }

  near.sort(byDistance)
  const kept = near.slice(0, transferRules.walkLinkCountPerStopMax)
  const starts = []

  for (const candidate of kept) {
    const walkS = Math.ceil(candidate.distanceM / transferRules.walkSpeedMPerS)
    starts.push({stop: candidate.stop, walkS})
  }

  return starts
}
