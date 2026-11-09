// Reads the names file of a routing snapshot, version 1, as
// Gobusgo.Routing.Names writes it: one JSON object stored as one gzip
// stream. `expandNames` expands the stream as fetched, and `decodeNames`
// checks the JSON against the counts of the snapshot's stops and trips
// files, whose indexes key its stop and trip columns. Each returns a result
// keyed by `kind`, the records or the reason the file was refused, and
// `decodeNames` is pure.

import {DecodeKind} from "./routing_snapshot.js"

const COMPRESSION_FORMAT = "gzip"

/** The version of the names file this module reads. */
export const NAMES_VERSION = 1

/** The most bytes a names file expands to, the bound the server stores compressed content under. */
export const NAMES_EXPANDED_BYTES_MAX = 16 * 1024 * 1024

/** Why a names file was refused. */
export const NamesRefusalReason = Object.freeze({
  invalidStream: "invalidStream",
  tooLarge: "tooLarge",
  invalidText: "invalidText",
  unsupportedVersion: "unsupportedVersion",
  invalidShape: "invalidShape",
  countMismatch: "countMismatch",
})

const textDecoder = new TextDecoder("utf-8", {fatal: true})

function refused(reason) {
  return {kind: DecodeKind.refused, reason}
}

function decoded(records) {
  return {kind: DecodeKind.decoded, records}
}

// The chunks of `reader` joined into one buffer, read until the stream ends
// or passes NAMES_EXPANDED_BYTES_MAX.
async function readBounded(reader) {
  const chunks = []
  let byteCount = 0

  for (;;) {
    const read = await reader.read()

    if (read.done) {
      break
    }

    byteCount += read.value.byteLength

    if (byteCount > NAMES_EXPANDED_BYTES_MAX) {
      await reader.cancel()
      return refused(NamesRefusalReason.tooLarge)
    }

    chunks.push(read.value)
  }

  const bytes = new Uint8Array(byteCount)
  let offset = 0

  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }

  return decoded(bytes.buffer)
}

/** The content of the gzip stream `buffer`, a names file as fetched. */
export async function expandNames(buffer) {
  const compressed = new Blob([buffer]).stream()
  const expanded = compressed.pipeThrough(new DecompressionStream(COMPRESSION_FORMAT))
  const reader = expanded.getReader()

  try {
    return await readBounded(reader)
  } catch (error) {
    // A stream that is not gzip, or ends early, rejects the read with a TypeError.
    if (error instanceof TypeError) {
      return refused(NamesRefusalReason.invalidStream)
    }

    throw error
  }
}

function isText(value) {
  return typeof value === "string"
}

function isTextOrNull(value) {
  const isNull = value === null
  return isNull || isText(value)
}

function isColumn(value) {
  if (!Array.isArray(value)) {
    return false
  }

  for (const cell of value) {
    if (!isTextOrNull(cell)) {
      return false
    }
  }

  return true
}

function isObject(value) {
  const isNonNull = value !== null
  const isObjectType = typeof value === "object"
  const isRecord = isNonNull && isObjectType
  return isRecord && !Array.isArray(value)
}

const ROUTE_FIELDS = Object.freeze(["shortName", "longName", "color", "agencyId"])

function isRoute(value) {
  if (!isObject(value)) {
    return false
  }

  for (const field of ROUTE_FIELDS) {
    if (!isTextOrNull(value[field])) {
      return false
    }
  }

  return true
}

// Whether `value` is an object whose every value passes `isEntry`.
function isKeyed({value, isEntry}) {
  if (!isObject(value)) {
    return false
  }

  for (const entry of Object.values(value)) {
    if (!isEntry(entry)) {
      return false
    }
  }

  return true
}

function hasColumns(names) {
  const hasStopNames = isColumn(names.stopNames)
  const hasStopCodes = isColumn(names.stopCodes)
  const hasStopColumns = hasStopNames && hasStopCodes
  return hasStopColumns && isColumn(names.tripHeadsigns)
}

function hasKeyedFields(names) {
  const hasRoutes = isKeyed({value: names.routes, isEntry: isRoute})
  return hasRoutes && isKeyed({value: names.agencyNames, isEntry: isText})
}

function parsed(buffer) {
  try {
    const text = textDecoder.decode(new Uint8Array(buffer))
    return decoded(JSON.parse(text))
  } catch (error) {
    // A file that is not UTF-8 throws a TypeError, and one that is not JSON a SyntaxError.
    const isTextError = error instanceof TypeError
    const isTextOrSyntaxError = isTextError || error instanceof SyntaxError

    if (isTextOrSyntaxError) {
      return refused(NamesRefusalReason.invalidText)
    }

    throw error
  }
}

/**
 * The names of a names file's content `buffer`, whose snapshot's stops file
 * holds `stopCount` stops and trips file `tripCount` trips: `stopNames` and
 * `stopCodes` by stop index, `tripHeadsigns` by trip index, each cell a
 * string or null, `routes` by route identifier, each with `shortName`,
 * `longName`, `color`, and `agencyId`, and `agencyNames` by agency
 * identifier.
 */
export function decodeNames({buffer, stopCount, tripCount}) {
  const json = parsed(buffer)

  if (json.kind === DecodeKind.refused) {
    return json
  }

  const names = json.records

  if (!isObject(names)) {
    return refused(NamesRefusalReason.invalidShape)
  }

  if (names.version !== NAMES_VERSION) {
    return refused(NamesRefusalReason.unsupportedVersion)
  }

  const isWellFormed = hasColumns(names) && hasKeyedFields(names)

  if (!isWellFormed) {
    return refused(NamesRefusalReason.invalidShape)
  }

  const isStopNameCount = names.stopNames.length === stopCount
  const isStopCount = isStopNameCount && names.stopCodes.length === stopCount
  const isCountMatched = isStopCount && names.tripHeadsigns.length === tripCount

  if (!isCountMatched) {
    return refused(NamesRefusalReason.countMismatch)
  }

  return decoded({
    stopNames: names.stopNames,
    stopCodes: names.stopCodes,
    tripHeadsigns: names.tripHeadsigns,
    routes: names.routes,
    agencyNames: names.agencyNames,
  })
}
