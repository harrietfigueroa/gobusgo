// How a vehicle marker moves from where it is drawn to where a fetch puts
// it. Everything here is pure: positions and times are given, so a glide is
// a function of its start, its end, and the time asked about.

// A glide lasts this long, and a move shorter than the first bound or longer
// than the second snaps: the first is noise in a reported position, the
// second a vehicle that a glide across the map would misplace for its whole
// length, such as one that starts a new trip.
export const glideDurationMs = 1000
const glideDistanceMetersMin = 2
const glideDistanceMetersMax = 500
const earthRadiusMeters = 6371008.8
const degreesPerHalfTurn = 180

function radians(degrees) {
  return degrees * Math.PI / degreesPerHalfTurn
}

// The great-circle distance between two [lon, lat] positions, in meters.
export function distanceMeters(source, target) {
  const [sourceLon, sourceLat] = source
  const [targetLon, targetLat] = target
  const latDelta = radians(targetLat - sourceLat)
  const lonDelta = radians(targetLon - sourceLon)
  const sinLat = Math.sin(latDelta / 2)
  const sinLon = Math.sin(lonDelta / 2)
  const chord = sinLat * sinLat +
    Math.cos(radians(sourceLat)) * Math.cos(radians(targetLat)) * sinLon * sinLon

  return 2 * earthRadiusMeters * Math.asin(Math.min(1, Math.sqrt(chord)))
}

// Whether a marker drawn at `source` glides to `target` rather than snapping
// there. A page whose browser asks for reduced motion never glides.
export function glides({source, target, reducedMotion}) {
  if (reducedMotion) {
    return false
  }

  const distance = distanceMeters(source, target)
  const isFarEnough = distance >= glideDistanceMetersMin
  const isNearEnough = distance <= glideDistanceMetersMax
  const isGlideDistance = isFarEnough && isNearEnough
  return isGlideDistance
}

// The position of a glide `elapsedMs` after it started, in a straight line
// at an even pace, and whether the glide has ended.
export function glidePosition({source, target, elapsedMs}) {
  if (elapsedMs >= glideDurationMs) {
    return {position: target, ended: true}
  }

  const fraction = Math.max(0, elapsedMs) / glideDurationMs
  const [sourceLon, sourceLat] = source
  const [targetLon, targetLat] = target
  const position = [
    sourceLon + (targetLon - sourceLon) * fraction,
    sourceLat + (targetLat - sourceLat) * fraction
  ]

  return {position, ended: false}
}
