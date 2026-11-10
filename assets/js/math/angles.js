// Conversions between degrees and radians, and the arithmetic of compass
// angles in degrees clockwise from north. Everything here is pure.
//
// A conversion multiplies by π before it divides by 180. A precomputed
// `Math.PI / 180` rounds once more, and gives other bits for about a
// quarter of the latitudes.

import {assertFinite, assertOrdered} from "./checks.js"

/** The degrees of a whole turn. */
export const DEGREES_PER_TURN = 360

/** The degrees of a half turn, which is π radians. */
export const DEGREES_PER_HALF_TURN = 180

/** `degrees` in radians. */
export function radians(degrees) {
  assertFinite(degrees, "angles: degrees")
  return degrees * Math.PI / DEGREES_PER_HALF_TURN
}

/** `radians` in degrees. */
export function degrees(radians) {
  assertFinite(radians, "angles: radians")
  return radians * DEGREES_PER_HALF_TURN / Math.PI
}

/** `degrees` turned into the range from 0 up to, and not including, 360. */
export function normalizedDegrees(degrees) {
  assertFinite(degrees, "angles: degrees")
  const remainder = degrees % DEGREES_PER_TURN
  const normalized = (remainder + DEGREES_PER_TURN) % DEGREES_PER_TURN
  assertOrdered({low: 0, high: normalized, label: "angles: a normalized angle"})
  return normalized
}

/** The smaller angle between the directions `from` and `to`, from 0 to 180 degrees, either way round. */
export function turnDegrees({from, to}) {
  const clockwise = normalizedDegrees(to - from)
  return Math.min(clockwise, DEGREES_PER_TURN - clockwise)
}
