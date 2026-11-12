// Linear interpolation and clamping of plain numbers. Everything here is
// pure.

import {assertFinite, assertOrdered} from "./checks.js"

/**
 * The value `fraction` of the way from `from` to `to`: `from` at 0, `to`
 * at 1, and on the same line outside them.
 */
export function lerp({from, to, fraction}) {
  assertFinite(fraction, "interpolation: a fraction")
  return from + (to - from) * fraction
}

/** `value` brought inside `min` and `max`, both included. */
export function clamp({value, min, max}) {
  assertOrdered({low: min, high: max, label: "interpolation: a clamp's bounds"})
  const clamped = Math.min(max, Math.max(min, value))
  assertOrdered({low: min, high: clamped, label: "interpolation: a clamped value"})
  return clamped
}
