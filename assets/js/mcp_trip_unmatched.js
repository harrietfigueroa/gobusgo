// What the trip planner app tells the model when an end of the start's words
// matches no place: a versioned object that names the end and the rider's
// words, so the model can ask the rider about it on their next message. The
// schema is the one a native app implements. Everything here is pure.
//
// Version 1 of the object:
//
//   schema        "gobusgo.unmatched"
//   version       1
//   ends          one or two, `from` before `to`, each of:
//     end         "from" or "to"
//     words       the rider's words for the end, as the call carried them
//
// A change to a field's meaning, or a field removed, is a new version; a
// field added keeps the version.

import {assertCondition} from "./assert.js"
import {ProblemKind, VALID, firstFailure, invalid, isRecord, isText} from "./mcp_trip_journey.js"
import {TripEnd} from "./trip_plan.js"

/** The name that tells the object from any other the model holds. */
export const UNMATCHED_SCHEMA_NAME = "gobusgo.unmatched"

/** The version of the object this module writes. */
export const UNMATCHED_SCHEMA_VERSION = 1

const ENDS_COUNT_MAX = 2
const END_ORDER = Object.freeze([TripEnd.from, TripEnd.to])

function endsProblem(ends) {
  const isEndList = Array.isArray(ends)

  if (!isEndList) {
    return invalid("ends")
  }

  const countFailure = firstFailure([{path: "ends", isValid: ends.length > 0}, {path: "ends", isValid: ends.length <= ENDS_COUNT_MAX}])

  if (countFailure.kind === ProblemKind.invalid) {
    return countFailure
  }

  let orderMin = 0

  for (const [index, entry] of ends.entries()) {
    const path = `ends.${index}`

    if (!isRecord(entry)) {
      return invalid(path)
    }

    const order = END_ORDER.indexOf(entry.end)
    const isKnown = order >= 0
    const isAfterPrevious = order >= orderMin
    const isWordsText = isText(entry.words) && entry.words.trim() !== ""
    const orderFailure = firstFailure([{path: path + ".end", isValid: isKnown}, {path: path + ".end", isValid: isAfterPrevious}, {path: path + ".words", isValid: isWordsText}])

    if (orderFailure.kind === ProblemKind.invalid) {
      return orderFailure
    }

    orderMin = order + 1
  }

  return VALID
}

/**
 * Whether `value` is an object of version 1: a ProblemKind member, valid, or
 * invalid with the `path` of the first field that is not what the version
 * says. Fields it does not name are left alone.
 */
export function unmatchedProblem(value) {
  if (!isRecord(value)) {
    return invalid("root")
  }

  const headFailure = firstFailure([
    {path: "schema", isValid: value.schema === UNMATCHED_SCHEMA_NAME},
    {path: "version", isValid: value.version === UNMATCHED_SCHEMA_VERSION},
  ])

  if (headFailure.kind === ProblemKind.invalid) {
    return headFailure
  }

  return endsProblem(value.ends)
}

/**
 * The object for `unmatched`, one or two `{end, words}`, each a TripEnd
 * member and the rider's non-blank words for it, an end at most once; the
 * ends are written `from` first.
 */
export function unmatchedContext({unmatched}) {
  assertCondition(unmatched.length > 0, "unmatched context: no end is unmatched")
  assertCondition(unmatched.length <= ENDS_COUNT_MAX, "unmatched context: more ends than a trip has: " + unmatched.length)
  const ends = []

  for (const end of END_ORDER) {
    for (const entry of unmatched) {
      if (entry.end === end) {
        ends.push({end, words: entry.words})
      }
    }
  }

  const context = {schema: UNMATCHED_SCHEMA_NAME, version: UNMATCHED_SCHEMA_VERSION, ends}
  const problem = unmatchedProblem(context)
  assertCondition(problem.kind === ProblemKind.valid, "unmatched context: the object is invalid at " + problem.path)
  return context
}
