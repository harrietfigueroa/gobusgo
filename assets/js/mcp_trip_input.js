// What the trip planner app reads of a `plan_trip` call, as pure functions:
// the arguments the host sends, or the tool result's `structuredContent`,
// which holds the same object, read into the start, the destination's text,
// and the time the Trip tab plans for, and the words the search takes for an
// end's text. Nothing here reads the document, the
// network, or a clock.
//
// The arguments come from a model, so each field is checked, and a refusal
// is a value that names the field, never a throw.

import {DayChoice, TimeMode} from "./core/trip_plan.js"

/** The most characters an end's text holds; the tool's schema bounds it the same. */
export const END_TEXT_LENGTH_MAX = 200

/** The kinds of a read of the arguments. */
export const InputKind = Object.freeze({found: "found", refused: "refused"})

/** The kinds of a start: where the rider is, or the words that name a place. */
export const StartKind = Object.freeze({position: "position", words: "words"})

const CLOCK_PATTERN = /^(?:[01]\d|2[0-3]):[0-5]\d$/
const LEAVING_NOW = Object.freeze({mode: TimeMode.now, day: DayChoice.today, clockText: ""})
const AT_POSITION = Object.freeze({kind: StartKind.position})

// The phrases that name where the rider is rather than a place, compared
// lowercased with runs of spaces joined and a closing full stop or
// exclamation mark dropped.
const POSITION_PHRASES = Object.freeze(["here", "my location", "current location", "my current location", "my position", "where i am"])
const SPACE_RUN = /\s+/g
const CLOSING_MARK = /[.!]$/

const MODE_NAMES = Object.freeze(Object.values(TimeMode))
const DAY_NAMES = Object.freeze(Object.values(DayChoice))
const NO_ARGUMENTS = Object.freeze({})

/** The most comma-separated parts of a trailing region dropped: a city, a state, and a ZIP. */
export const REGION_PARTS_MAX = 3

// A name and one region part: the fewest comma-separated parts that hold a region.
const NAME_AND_REGION_COUNT_MIN = 2

// A ZIP code after other words, five digits and optionally four more.
const TRAILING_ZIP = /\s+\d{5}(?:-\d{4})?$/
const LEADING_THE = /^the\s+(?=\S)/i
const WORD_CHARACTER = /[\p{L}\p{N}]/u

function isRecord(value) {
  const isObject = typeof value === "object" && value !== null
  return isObject && !Array.isArray(value)
}

// The text without the region its commas set apart: the first part is the
// name, and at most REGION_PARTS_MAX of the parts after it are dropped. Text
// with no comma is returned as it is, since a name such as "West Seattle" or
// "University of Washington" holds region words of its own.
function withoutCommaRegion(text) {
  const parts = []

  for (const piece of text.split(",")) {
    const part = piece.trim()

    if (part !== "") {
      parts.push(part)
    }
  }

  if (parts.length < NAME_AND_REGION_COUNT_MIN) {
    return text
  }

  const regionCount = Math.min(parts.length - 1, REGION_PARTS_MAX)
  const kept = parts.slice(0, parts.length - regionCount)
  return kept.join(", ")
}

function withoutTrailingZip(text) {
  return text.replace(TRAILING_ZIP, "")
}

function withoutLeadingThe(text) {
  return text.replace(LEADING_THE, "")
}

/**
 * The words the "Where to?" search falls back to for an end `text` the rider
 * said, when the text as given finds nothing:
 * the text without a trailing region (the parts after its first comma, at
 * most REGION_PARTS_MAX of them, and a ZIP code after its words) and without
 * a leading "the", since the search keeps a place only when every word of
 * the query matches one of the place's words. Text with no comma is left
 * whole, and text that would strip to nothing is returned unchanged.
 */
export function searchWords(text) {
  const trimmed = text.trim()
  const regionless = withoutCommaRegion(trimmed)
  const zipless = withoutTrailingZip(regionless)
  const words = withoutLeadingThe(zipless).trim()

  const isSearchable = WORD_CHARACTER.test(words)

  if (!isSearchable) {
    return trimmed
  }

  return words
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

function isPositionPhrase(text) {
  const spaced = text.toLowerCase().replace(SPACE_RUN, " ")
  const phrase = spaced.replace(CLOSING_MARK, "")
  return POSITION_PHRASES.includes(phrase)
}

// The start: where the rider is for no text, blank text, or a phrase that
// names their position, and otherwise the words, read as an end's text is.
function startOf(value) {
  if (value === undefined) {
    return {kind: InputKind.found, start: AT_POSITION}
  }

  const isBlankText = typeof value === "string" && value.trim() === ""

  if (isBlankText) {
    return {kind: InputKind.found, start: AT_POSITION}
  }

  const named = endText(value)

  if (named.kind === InputKind.refused) {
    return named
  }

  if (isPositionPhrase(named.text)) {
    return {kind: InputKind.found, start: AT_POSITION}
  }

  return {kind: InputKind.found, start: {kind: StartKind.words, text: named.text}}
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

/**
 * The time `value`, the `when` of a call's arguments, names: an InputKind
 * member, found with the page's `{mode, day, clockText}` for a time on the
 * rider's clock, leaving now where none is given, or refused for the field
 * `when`.
 */
export function whenOf(value) {
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
 * InputKind member, found with `from`, a StartKind member, `position` for a
 * missing or blank `from` or one such as "here" or "my location", and
 * `words` with the trimmed `text` otherwise; `to`, the destination's trimmed
 * text; and `when`, the `{mode, day, clockText}` the planner takes. Refused
 * names the `field` that failed, `from`, `to`, or `when`. A call with no
 * `when` leaves now, and a `when` of mode `now` carries no time.
 */
export function tripInput(value) {
  if (!isRecord(value)) {
    return refused("from")
  }

  const from = startOf(value.from)

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

  return {kind: InputKind.found, from: from.start, to: to.text, when: timed.when}
}
