// The assertions of the math modules' hot paths. Each formats its message
// only when it fails: a template literal formats its numbers on every call,
// which costs more than the arithmetic it guards.

import {AssertionError} from "../assert.js"

/** Asserts that `value` is a finite number; `label` names it in a failure. */
export function assertFinite(value, label) {
  if (Number.isFinite(value)) {
    return
  }

  throw new AssertionError(`${label}: ${value} is not a finite number`)
}

/** Asserts that `low` is at most `high`; `label` names the pair in a failure. */
export function assertOrdered({low, high, label}) {
  if (low <= high) {
    return
  }

  throw new AssertionError(`${label}: ${low} is above ${high}`)
}
