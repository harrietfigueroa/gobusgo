// The search of an intersection typed as "4th & Pike", "Pine and 3rd", or
// "3rd Ave @ Pine St", over the decoded intersection index and shards. Reading
// is two steps so that no step fetches: `planIntersection` parses the text and
// names the shard of the first street from the index, and
// `searchIntersection` reads the crossings of that shard and returns those
// of the two streets nearest a point. Every refusal and every miss is a value
// keyed by `kind`. Everything here is pure.

import {assertCondition} from "./core/assert.js"
import {parseQuery, parseStreet, streetKey, tokenize} from "./address_normalize.js"
import {distanceMeters} from "./core/math/geodesy.js"

const MICRODEGREES_PER_DEGREE = 1_000_000
const COORDINATE_COUNT = 2
const PREFIX_LENGTH_MAX = 32
const OWN_NAME_MARK = "$"
const RESULT_COUNT_MAX = 5
const SHARD_NOT_FOUND = -1
const OMITTABLE_PARTS = Object.freeze(["preDirection", "type", "sufDirection"])

/** The kinds of what the two steps return. */
export const IntersectionLookupKind = Object.freeze({
  plan: "plan",
  found: "found",
  missing: "missing",
  notAnIntersection: "notAnIntersection",
  noShard: "noShard",
})

/** Why a text is not an intersection. */
export const NotAnIntersectionReason = Object.freeze({
  notTwoStreets: "notTwoStreets",
})

// The key a street's shard is chosen by: its name with the spaces removed.
function nameKeyOf(street) {
  return street.name.replaceAll(" ", "")
}

// The position in the index of the shard whose prefix holds `nameKey`: the
// shard of the streets named by the key alone, or the longest of its prefixes
// that a shard is named by. A shard prefix is at most 32 characters long.
function shardPositionFor({index, nameKey}) {
  const positions = new Map()

  for (let position = 0; position < index.shardCount; position += 1) {
    positions.set(index.prefixes[position], position)
  }

  const letters = Array.from(nameKey)
  const characters = letters.slice(0, PREFIX_LENGTH_MAX)
  const own = positions.get(characters.join("") + OWN_NAME_MARK)
  const isOwnShardPresent = own !== undefined
  const isOwnShardNamed = characters.length < PREFIX_LENGTH_MAX
  const isOwnShard = isOwnShardPresent && isOwnShardNamed

  if (isOwnShard) {
    return own
  }

  for (let length = characters.length; length >= 0; length -= 1) {
    const shortened = characters.slice(0, length)
    const found = positions.get(shortened.join(""))

    if (found !== undefined) {
      return found
    }
  }

  return SHARD_NOT_FOUND
}

/**
 * The shard to read for `text`, typed as two streets: `{kind: "plan", query,
 * prefix, path}` where `query` is `{first, second}`, the two streets with
 * the parts the rider typed, and `path` is the shard's path from `index`, the
 * table of the decoded index; `{kind: "notAnIntersection", reason}` for text
 * that is not two streets; or `{kind: "noShard"}` where no shard holds the
 * first street's name.
 */
export function planIntersection({text, index}) {
  assertCondition(typeof text === "string", "intersection lookup: the text is not a string: " + typeof text)
  assertCondition(index !== null, "intersection lookup: the index is null")
  assertCondition(typeof index === "object", "intersection lookup: the index is not a table")
  const parsed = parseQuery(text)

  if (parsed.kind !== "intersection") {
    const refusal = {kind: IntersectionLookupKind.notAnIntersection, reason: NotAnIntersectionReason.notTwoStreets}
    return refusal
  }

  // The parser reads an intersection word only between two tokens, so each
  // street has at least one and the name keeps the last of them.
  assertCondition(parsed.first.name !== "", "intersection lookup: the first street has no name: " + text)
  assertCondition(parsed.second.name !== "", "intersection lookup: the second street has no name: " + text)

  const shard = shardPositionFor({index, nameKey: nameKeyOf(parsed.first)})

  if (shard === SHARD_NOT_FOUND) {
    const refusal = {kind: IntersectionLookupKind.noShard}
    return refusal
  }

  const plan = {
    kind: IntersectionLookupKind.plan,
    query: {first: parsed.first, second: parsed.second},
    prefix: index.prefixes[shard],
    path: index.paths[shard],
  }

  return plan
}

// A part the rider left out agrees with whatever the street holds.
function partAgrees(typed, held) {
  const isOmitted = typed === ""
  return isOmitted || typed === held
}

function streetAgrees({typed, held}) {
  const isNameEqual = typed.name === held.name
  const areDirectionsAgreeing = partAgrees(typed.preDirection, held.preDirection) && partAgrees(typed.sufDirection, held.sufDirection)
  const isNameAndDirectionsAgreeing = isNameEqual && areDirectionsAgreeing
  return isNameAndDirectionsAgreeing && partAgrees(typed.type, held.type)
}

function omittedPartCount({typed, held}) {
  let count = 0

  for (const part of OMITTABLE_PARTS) {
    const isFilledIn = typed[part] === "" && held[part] !== ""

    if (isFilledIn) {
      count += 1
    }
  }

  return count
}

function byNearness(left, right) {
  const isDistanceEqual = left.distanceM === right.distanceM

  if (isDistanceEqual) {
    return left.label.localeCompare(right.label)
  }

  return left.distanceM - right.distanceM
}

// The street a string of the shard's table holds, parsed once per search.
function parsedStreetOf({shard, parsed, stringIndex}) {
  if (!parsed.has(stringIndex)) {
    const tokens = tokenize(shard.strings[stringIndex])
    parsed.set(stringIndex, parseStreet(tokens))
  }

  return parsed.get(stringIndex)
}

function crossingOf({shard, crossing, near, held, other, query}) {
  const lat = shard.positions[crossing * COORDINATE_COUNT] / MICRODEGREES_PER_DEGREE
  const lon = shard.positions[crossing * COORDINATE_COUNT + 1] / MICRODEGREES_PER_DEGREE
  const meters = distanceMeters([near.lon, near.lat], [lon, lat])
  const omittedFirst = omittedPartCount({typed: query.first, held})
  const omittedSecond = omittedPartCount({typed: query.second, held: other})

  return {
    label: streetKey(held) + " & " + streetKey(other),
    lat,
    lon,
    distanceM: Math.round(meters),
    omittedPartCount: omittedFirst + omittedSecond,
  }
}

/**
 * The crossings of the two streets of `query`, as `planIntersection` returned
 * it, in `shard`, the table of the decoded shard, nearest `near`, a
 * `{lat, lon}` in degrees, first: `{kind: "found", results}` of at most five,
 * each `{label, lat, lon, distanceM, omittedPartCount}` where the label is
 * the two street keys joined by " & " and `omittedPartCount` is how many
 * directions and types the rider left out that the streets hold, or
 * `{kind: "missing"}` where the shard holds no such crossing. A crossing is
 * stored under both streets, so one shard answers either order.
 */
export function searchIntersection({query, shard, near}) {
  assertCondition(query !== null, "intersection lookup: the query is null")
  assertCondition(typeof query === "object", "intersection lookup: the query is not an object")
  assertCondition(Number.isFinite(near.lat), "intersection lookup: the latitude is not a number: " + near.lat)
  assertCondition(Number.isFinite(near.lon), "intersection lookup: the longitude is not a number: " + near.lon)
  const parsed = new Map()
  const candidates = []

  for (let street = 0; street < shard.streetCount; street += 1) {
    const held = parsedStreetOf({shard, parsed, stringIndex: shard.keys[street]})
    const isFirst = streetAgrees({typed: query.first, held})

    if (!isFirst) {
      continue
    }

    const end = shard.crossingStarts[street + 1]

    for (let crossing = shard.crossingStarts[street]; crossing < end; crossing += 1) {
      const other = parsedStreetOf({shard, parsed, stringIndex: shard.others[crossing]})
      const isSecond = streetAgrees({typed: query.second, held: other})

      if (isSecond) {
        candidates.push(crossingOf({shard, crossing, near, held, other, query}))
      }
    }
  }

  if (candidates.length === 0) {
    const missing = {kind: IntersectionLookupKind.missing}
    return missing
  }

  candidates.sort(byNearness)
  const found = {kind: IntersectionLookupKind.found, results: candidates.slice(0, RESULT_COUNT_MAX)}
  return found
}
