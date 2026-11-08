// The assertion of the routing experiment's engines: a failed assertion is a
// programmer error and throws an AssertionError, never a value a caller
// handles.

/** The error every failed assertion throws. */
export class AssertionError extends Error {}

/** Throws an AssertionError with `message` unless `condition` holds. */
export function assertCondition(condition, message) {
  if (!condition) {
    throw new AssertionError(message)
  }
}
