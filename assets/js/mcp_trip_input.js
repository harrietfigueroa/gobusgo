// What the trip planner app reads of a `plan_trip` call, as pure functions:
// the arguments the host sends, or the tool result's `structuredContent`,
// which holds the same object, read into the two ends' texts and the time
// the Trip tab plans for. Nothing here reads the document, the network, or a
// clock.
//
// The arguments come from a model, so each field is checked, and a refusal
// is a value that names the field, never a throw.

import {DayChoice, TimeMode} from "./trip_plan.js"

/** The most characters an end's text holds; the tool's schema bounds it the same. */
export const END_TEXT_LENGTH_MAX = 200

/** The kinds of a read of the arguments. */
export const InputKind = Object.freeze({found: "found", refused: "refused"})

const CLOCK_PATTERN = /^(?:[01]\d|2[0-3]):[0-5]\d$/
const LEAVING_NOW = Object.freeze({mode: TimeMode.now, day: DayChoice.today, clockText: ""})

const MODE_NAMES = Object.freeze(Object.values(TimeMode))
const DAY_NAMES = Object.freeze(Object.values(DayChoice))
const NO_ARGUMENTS = Object.freeze({})

function isRecord(value) {
  const isObject = typeof value === "object" && value !== null
  return isObject && !Array.isArray(value)
}

function isModeName(mode) {
  return MODE_NAMES.includes(mode)
}

function isDayName(day) {
  return DAY_NAMES.includes(day)
}

function refused(field) {
  return {kind: InputKind.refused, field}
}

// The text of an end: trimmed, and not blank or longer than the bound.
function endText(value) {
  if (typeof value !== "string") {
    return {kind: InputKind.refused}
  }

  const text = value.trim()
  const isUsable = text.length > 0 && text.length <= END_TEXT_LENGTH_MAX

  if (!isUsable) {
    return {kind: InputKind.refused}
  }

  return {kind: InputKind.found, text}
}

// The time of the trip: leaving now where none is given, or the page's
// `{mode, day, clockText}` for a time on the rider's clock.
function whenOf(value) {
  if (value === undefined) {
    return {kind: InputKind.found, when: LEAVING_NOW}
  }

  if (!isRecord(value)) {
    return refused("when")
  }

  if (!isModeName(value.mode)) {
    return refused("when")
  }

  if (value.mode === TimeMode.now) {
    return {kind: InputKind.found, when: LEAVING_NOW}
  }

  let day = DayChoice.today

  if (value.day !== undefined) {
    day = value.day
  }

  if (!isDayName(day)) {
    return refused("when")
  }

  const isTimeText = typeof value.time === "string"

  if (!isTimeText) {
    return refused("when")
  }

  if (!CLOCK_PATTERN.test(value.time)) {
    return refused("when")
  }

  return {kind: InputKind.found, when: {mode: value.mode, day, clockText: value.time}}
}

/**
 * The arguments in the params of a `ui/notifications/tool-input`
 * notification, which the host sends with the complete arguments of the
 * call, or an empty object, which `tripInput` refuses, for params of another
 * shape.
 */
export function toolInputArguments(params) {
  if (!isRecord(params)) {
    return NO_ARGUMENTS
  }

  return params.arguments
}

/**
 * The arguments in the params of a `ui/notifications/tool-result`
 * notification, a tool result whose `structuredContent` `plan_trip` fills
 * with the arguments unchanged, or an empty object, which `tripInput`
 * refuses, for params of another shape.
 */
export function toolResultArguments(params) {
  if (!isRecord(params)) {
    return NO_ARGUMENTS
  }

  return params.structuredContent
}

/**
 * The trip `value`, the arguments of a `plan_trip` call, asks for: an
 * InputKind member, found with `from` and `to`, the trimmed texts of the two
 * ends, and `when`, the `{mode, day, clockText}` the planner takes, or
 * refused with the `field` that failed, `from`, `to`, or `when`. A call with
 * no `when` leaves now, and a `when` of mode `now` carries no time.
 */
export function tripInput(value) {
  if (!isRecord(value)) {
    return refused("from")
  }

  const from = endText(value.from)

  if (from.kind === InputKind.refused) {
    return refused("from")
  }

  const to = endText(value.to)

  if (to.kind === InputKind.refused) {
    return refused("to")
  }

  const timed = whenOf(value.when)

  if (timed.kind === InputKind.refused) {
    return timed
  }

  return {kind: InputKind.found, from: from.text, to: to.text, when: timed.when}
}
