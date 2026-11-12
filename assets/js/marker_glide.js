// How a vehicle marker moves from where it is drawn to where a fetch puts
// it. Everything here is pure: positions and times are given, so a glide is
// a function of its start, its end, and the time asked about.

import {distanceMeters} from "./core/math/geodesy.js"
import {lerp} from "./core/math/interpolation.js"

// A glide lasts this long, and a move shorter than the first bound or longer
// than the second snaps: the first is noise in a reported position, the
// second a vehicle that a glide across the map would misplace for its whole
// length, such as one that starts a new trip.
export const GLIDE_DURATION_MS = 1000
const GLIDE_DISTANCE_METERS_MIN = 2
const GLIDE_DISTANCE_METERS_MAX = 500

// Whether a marker drawn at `source` glides to `target` rather than snapping
// there. A page whose browser asks for reduced motion never glides.
export function glides({source, target, reducedMotion}) {
  if (reducedMotion) {
    return false
  }

  const distance = distanceMeters(source, target)
  const isFarEnough = distance >= GLIDE_DISTANCE_METERS_MIN
  const isNearEnough = distance <= GLIDE_DISTANCE_METERS_MAX
  const isGlideDistance = isFarEnough && isNearEnough
  return isGlideDistance
}

// The position of a glide `elapsedMs` after it started, in a straight line
// at an even pace, and whether the glide has ended.
export function glidePosition({source, target, elapsedMs}) {
  if (elapsedMs >= GLIDE_DURATION_MS) {
    return {position: target, ended: true}
  }

  const fraction = Math.max(0, elapsedMs) / GLIDE_DURATION_MS
  const [sourceLon, sourceLat] = source
  const [targetLon, targetLat] = target
  const position = [
    lerp({from: sourceLon, to: targetLon, fraction}),
    lerp({from: sourceLat, to: targetLat, fraction})
  ]

  return {position, ended: false}
}
