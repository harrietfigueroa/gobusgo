// What the arrivals board reads from the answers of the `arrivals` tool, as
// pure functions: the result of a tool call as one answer of a known kind,
// the arrivals of an answer as the rows the page draws take them, the board
// that keeps the stop's name and the last arrivals across answers that carry
// neither, and the texts of the status line and of the fetch time. Nothing
// here reads the document, the clock, or a timer.

import {shownAt} from "./arrival_countdown.js"
import {assertCondition, unreachable} from "./assert.js"
import {OutcomeKind} from "./mcp_host.js"

/** The kinds of what one result of the tool says. */
export const AnswerKind = Object.freeze({
  arrivals: "arrivals",
  fetching: "fetching",
  capacityReached: "capacity_reached",
  unknownStop: "unknown_stop",
  refused: "refused",
  invalid: "invalid"
})

/** The kinds of what the tool's arguments say of the stop. */
export const InputStopKind = Object.freeze({found: "found", missing: "missing"})

// The kinds of what reading one arrival of an answer ends in.
const ArrivalReadKind = Object.freeze({read: "read", unreadable: "unreadable"})

const INVALID = Object.freeze({kind: AnswerKind.invalid})
const UNREADABLE = Object.freeze({kind: ArrivalReadKind.unreadable})
const SECONDS_PLURAL_LIMIT = 1
const MINUTE_MS = 60 * 1000
// A narrow no-break space, which recent ICU data writes before "PM".
const NARROW_NO_BREAK_SPACE = new RegExp("\\u202f", "g")

function isRecord(value) {
  const isObject = typeof value === "object" && value !== null
  return isObject && !Array.isArray(value)
}

// The rows of the page take a text the arrival lacks as null.
function nullableText(value) {
  let text = null

  if (typeof value === "string") {
    text = value
  }

  return text
}

function isArrivalShaped({json, timeMs}) {
  const hasTime = Number.isFinite(timeMs) && typeof json.predicted === "boolean"
  return hasTime && Number.isSafeInteger(json.minutes)
}

// One arrival the tool sent, in the shape the rows of the page take.
function arrivalOf(json) {
  if (!isRecord(json)) {
    return UNREADABLE
  }

  const timeMs = Date.parse(json.time)

  if (isArrivalShaped({json, timeMs}) === false) {
    return UNREADABLE
  }

  const arrival = {route: nullableText(json.route), color: nullableText(json.color), headsign: nullableText(json.headsign), minutes: json.minutes, time_ms: timeMs, predicted: json.predicted}
  return {kind: ArrivalReadKind.read, arrival}
}

function arrivalsAnswerOf({data, meta}) {
  const fetchedAtMs = Date.parse(meta.fetchedAt)
  const hasStop = typeof data.stopId === "string" && Array.isArray(data.arrivals)
  const isShaped = hasStop && Number.isFinite(fetchedAtMs)

  if (isShaped === false) {
    return INVALID
  }

  const arrivals = []

  for (const json of data.arrivals) {
    const read = arrivalOf(json)

    if (read.kind === ArrivalReadKind.unreadable) {
      return INVALID
    }

    arrivals.push(read.arrival)
  }

  return {kind: AnswerKind.arrivals, stopId: data.stopId, stopName: nullableText(data.stopName), fetchedAtMs, arrivals}
}

function waitingAnswerOf({kind, data}) {
  const hasWait = Number.isSafeInteger(data.retryAfterSeconds) && data.retryAfterSeconds >= 1
  const isShaped = typeof data.stopId === "string" && hasWait

  if (isShaped === false) {
    return INVALID
  }

  return {kind, stopId: data.stopId, retryAfterSeconds: data.retryAfterSeconds}
}

function isTextBlock(candidate) {
  return isRecord(candidate) && typeof candidate.text === "string"
}

function errorText(result) {
  if (!Array.isArray(result.content)) {
    return ""
  }

  const block = result.content.find(isTextBlock)

  if (block === undefined) {
    return ""
  }

  return block.text
}

function isAnswerShaped(content) {
  const hasData = isRecord(content) && isRecord(content.data)
  return hasData && isRecord(content.meta)
}

/**
 * What `result`, the result of a call of the `arrivals` or `arrivals_board`
 * tool, says: an AnswerKind member with the fields the kind reads. A result
 * the tool flagged with `isError` is `refused` with the text of its first
 * block, and a result that is none of the tool's answers is `invalid`.
 */
export function answerOf(result) {
  if (!isRecord(result)) {
    return INVALID
  }

  if (result.isError === true) {
    return {kind: AnswerKind.refused, text: errorText(result)}
  }

  const content = result.structuredContent

  if (isAnswerShaped(content) === false) {
    return INVALID
  }

  const {data, meta} = content

  switch (data.status) {
    case "arrivals":
      return arrivalsAnswerOf({data, meta})
    case "fetching":
      return waitingAnswerOf({kind: AnswerKind.fetching, data})
    case "capacity_reached":
      return waitingAnswerOf({kind: AnswerKind.capacityReached, data})
    case "unknown_stop":
      if (typeof data.stopId !== "string") {
        return INVALID
      }

      return {kind: AnswerKind.unknownStop, stopId: data.stopId}
    default:
      return INVALID
  }
}

function hasInputStop(params) {
  const hasArguments = isRecord(params) && isRecord(params.arguments)
  const hasText = hasArguments && typeof params.arguments.stopId === "string"
  return hasText && params.arguments.stopId !== ""
}

/**
 * The stop `params`, the params of the host's `tool-input` notification,
 * name in their arguments: `{kind: "found", stopId}` for a non-empty text,
 * and `{kind: "missing"}` otherwise.
 */
export function inputStopOf(params) {
  if (hasInputStop(params)) {
    return {kind: InputStopKind.found, stopId: params.arguments.stopId}
  }

  return {kind: InputStopKind.missing}
}

/**
 * What a call of the tool through the host ended in, `outcome`, as one
 * answer: the tool's result, which `answerOf` reads, for an answered call,
 * and `refused` for a refusal or a timeout of the host.
 */
export function answerOfOutcome(outcome) {
  if (outcome.kind === OutcomeKind.answered) {
    return answerOf(outcome.result)
  }

  return {kind: AnswerKind.refused, text: ""}
}

/**
 * `answer`, of kind `arrivals`, as the page's rows take a stop's arrivals,
 * counted from `nowMs`, Unix milliseconds, with the arrivals that have
 * passed left out and at most `countMax` of them.
 */
export function shownOf({answer, nowMs, countMax}) {
  assertCondition(answer.kind === AnswerKind.arrivals, "board answer: only an arrivals answer has rows, got: " + answer.kind)

  const ageMinutes = Math.floor(Math.max(nowMs - answer.fetchedAtMs, 0) / MINUTE_MS)
  const shown = {stop_id: answer.stopId, status: "arrivals", age_minutes: ageMinutes, arrivals: answer.arrivals}
  return shownAt({shown, nowMs, countMax})
}

/**
 * What the board holds after `answer`: the stop's name, kept from an answer
 * that has one, the last arrivals answer, kept across answers that carry no
 * arrivals and dropped for a stop the server does not know, and the latest
 * answer, which the status line reads.
 */
export function boardAfter({board, answer}) {
  let {stopName, arrivals} = board

  if (answer.kind === AnswerKind.arrivals) {
    arrivals = answer

    if (answer.stopName !== null) {
      stopName = answer.stopName
    }
  }

  if (answer.kind === AnswerKind.unknownStop) {
    arrivals = null
  }

  return {stopName, arrivals, latest: answer}
}

function secondsText(seconds) {
  if (seconds === SECONDS_PLURAL_LIMIT) {
    return "1 second"
  }

  return `${seconds} seconds`
}

function againText({isRefreshing, retryAfterSeconds}) {
  if (isRefreshing) {
    return `Trying again in ${secondsText(retryAfterSeconds)}.`
  }

  return `Ask again in ${secondsText(retryAfterSeconds)}.`
}

/**
 * The line the board shows under its arrivals for `answer`, the latest one,
 * or an empty text for arrivals. `isRefreshing` says whether the board
 * asks again on its own, which changes who tries again.
 */
export function statusText({answer, isRefreshing}) {
  switch (answer.kind) {
    case AnswerKind.arrivals:
      return ""
    case AnswerKind.fetching:
      if (isRefreshing) {
        return `Fetching this stop's arrivals. ${againText({isRefreshing, retryAfterSeconds: answer.retryAfterSeconds})}`
      }

      return `This stop's arrivals are being fetched. ${againText({isRefreshing, retryAfterSeconds: answer.retryAfterSeconds})}`
    case AnswerKind.capacityReached:
      return `Too many stops are held to show this one. ${againText({isRefreshing, retryAfterSeconds: answer.retryAfterSeconds})}`
    case AnswerKind.unknownStop:
      return "This stop is not known."
    case AnswerKind.refused:
    case AnswerKind.invalid:
      if (isRefreshing) {
        return "The arrivals could not be fetched. Trying again soon."
      }

      return "The arrivals could not be fetched."
    default:
      return unreachable(answer.kind, "board answer: an answer of unknown kind")
  }
}

/** When the arrivals were fetched, on the clock of `timeZone`, an IANA name, such as "Fetched at 3:04 PM". */
export function fetchedText({fetchedAtMs, timeZone}) {
  const format = new Intl.DateTimeFormat("en-US", {hour: "numeric", minute: "2-digit", timeZone})
  const clock = format.format(fetchedAtMs).replace(NARROW_NO_BREAK_SPACE, " ")
  return `Fetched at ${clock}`
}
