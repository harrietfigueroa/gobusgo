// The assertions of the front end: a failed assertion is a programmer error
// and throws an AssertionError, never a value a caller handles.

/** The error every failed assertion throws. */
export class AssertionError extends Error {}

/** Throws an AssertionError with `message` unless `condition` holds. */
export function assertCondition(condition, message) {
  if (!condition) {
    throw new AssertionError(message)
  }
}

/** Throws an AssertionError naming `value`, a member no arm of a dispatch handles. */
export function unreachable(value, message) {
  throw new AssertionError(message + ": " + String(value))
}
