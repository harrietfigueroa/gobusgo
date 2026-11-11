// The address search of the Trip tab over the address shards: a shard holds
// the streets whose normalized name starts with its prefix, each with its
// house numbers and their positions. Everything here is
// pure and takes decoded tables: it fetches nothing, keeps nothing between
// calls, and touches no DOM, so a caller owns the fetches and the cache and
// what a rider types never has to leave the device.
//
// A number the shard holds is answered at its own position. A number it
// lacks, between two numbers on the same side of the street, is placed by
// linear interpolation between them. A number with no neighbor of its parity
// on one side is past the street's end and has no answer.

import {assertCondition} from "./assert.js"
import {parseQuery, streetKey} from "./address_normalize.js"
import {assertPosition, distanceMeters} from "./math/geodesy.js"

/** The most places `searchAddress` returns. */
export const RESULT_COUNT_MAX = 5

const OWN_NAME_MARK = "$"
const MICRODEGREES_PER_DEGREE = 1_000_000
const COORDINATES_PER_ADDRESS = 2
const PARITY_MODULUS = 2
const HALVES = 2
const SUFFIX_NONE = 0
const NOT_FOUND = -1
const BACKWARD = -1
const FORWARD = 1
const ADDRESS_QUERY_KIND = "address"

/** The outcomes of a lookup, the `kind` of each returned value. */
export const LookupKind = Object.freeze({
  found: "found",
  noShard: "noShard",
  noStreet: "noStreet",
  notAnAddress: "notAnAddress",
  pastEnd: "pastEnd",
})

/** How a result's point was found: a point the shard holds, or one between two it holds. */
export const PlacementKind = Object.freeze({
  exact: "exact",
  interpolated: "interpolated",
})

/** The key of the shard that holds a street: its normalized name with the spaces removed. */
function nameKeyOf(street) {
  return street.name.replaceAll(" ", "")
}

/**
 * The shard of an index that holds the street `text` names, `index` being
 * what `decodeAddressIndex` returns: the shard of the name alone where the
 * index names one, otherwise the shard of the longest prefix of the name's
 * key. The outcome is `{kind: "found", path, byteSize, sha256, prefix}`,
 * `{kind: "noShard"}` for a name no prefix covers, or
 * `{kind: "notAnAddress"}` for text with no house number and street.
 */
export function shardFor({index, text}) {
  assertCondition(typeof text === "string", "address lookup: the text is not a string: " + typeof text)
  assertCondition(index.prefixes.length === index.shardCount, "address lookup: the index holds " + index.prefixes.length + " prefixes for " + index.shardCount + " shards")
  const query = parseQuery(text)
  if (query.kind !== ADDRESS_QUERY_KIND) {
    const notAnAddress = {kind: LookupKind.notAnAddress}
    return notAnAddress
  }

  const key = nameKeyOf(query.street)
  const ownPrefix = key + OWN_NAME_MARK
  let best = NOT_FOUND
  for (let shard = 0; shard < index.shardCount; shard++) {
    const prefix = index.prefixes[shard]
    if (prefix === ownPrefix) {
      best = shard
      break
    }
    const isLonger = best === NOT_FOUND || prefix.length > index.prefixes[best].length
    const isPrefix = key.startsWith(prefix)
    const isBetter = isPrefix && isLonger
    if (isBetter) {
      best = shard
    }
  }

  if (best === NOT_FOUND) {
    const noShard = {kind: LookupKind.noShard}
    return noShard
  }

  const found = {
    kind: LookupKind.found,
    path: index.paths[best],
    byteSize: index.byteSizes[best],
    sha256: index.sha256s[best],
    prefix: index.prefixes[best],
  }
  return found
}

function isOmittedOrEqual(typed, held) {
  const isOmitted = typed === ""
  const isEqual = typed === held
  return isOmitted || isEqual
}

function streetAgrees({typed, held}) {
  const directionsAgree = isOmittedOrEqual(typed.preDirection, held.preDirection) && isOmittedOrEqual(typed.sufDirection, held.sufDirection)
  return directionsAgree && isOmittedOrEqual(typed.type, held.type)
}

function localityAgrees({locality, city}) {
  const isOmitted = locality === ""
  const isPrefix = city.startsWith(locality)
  return isOmitted || isPrefix
}

// The parts a rider left out that the street has: fewer means the typed text
// names the street more completely.
function filledInCount({typed, held}) {
  let count = 0
  for (const part of ["preDirection", "type", "sufDirection"]) {
    const isFilledIn = typed[part] === "" && held[part] !== ""
    if (isFilledIn) {
      count++
    }
  }
  return count
}

// The first address of [start, end) whose number is at least `number`, or
// `end` where none is: numbers do not decrease within a street.
function lowerBound({numbers, start, end, number}) {
  let low = start
  let high = end
  while (low < high) {
    const middle = low + Math.floor((high - low) / HALVES)
    if (numbers[middle] < number) {
      low = middle + 1
    } else {
      high = middle
    }
  }
  return low
}

// The address that holds `number`, preferring the one with the typed letter
// and otherwise the first with that number, or NOT_FOUND.
function heldAddress({table, start, end, number, suffixCode}) {
  const first = lowerBound({numbers: table.numbers, start, end, number})
  for (let address = first; address < end; address++) {
    if (table.numbers[address] !== number) {
      break
    }
    if (table.suffixes[address] === suffixCode) {
      return address
    }
  }
  const isHeld = first < end && table.numbers[first] === number
  if (isHeld) {
    return first
  }
  return NOT_FOUND
}

// The nearest address at or before `from`, and not before `start`, whose
// number is on the same side of the street as `number`, by parity.
function sameSideBefore({table, from, start, number}) {
  const parity = number % PARITY_MODULUS
  for (let address = from; address >= start; address--) {
    if (table.numbers[address] % PARITY_MODULUS === parity) {
      return address
    }
  }
  return NOT_FOUND
}

// The nearest address at or after `from`, and before `end`, whose number is
// on the same side of the street as `number`, by parity.
function sameSideFrom({table, from, end, number}) {
  const parity = number % PARITY_MODULUS
  for (let address = from; address < end; address++) {
    if (table.numbers[address] % PARITY_MODULUS === parity) {
      return address
    }
  }
  return NOT_FOUND
}

function positionOf({table, address}) {
  const latitude = table.positions[address * COORDINATES_PER_ADDRESS]
  const longitude = table.positions[address * COORDINATES_PER_ADDRESS + 1]
  return {latitude, longitude}
}

// The point of `number` on a street, or nothing where no same-side neighbor
// stands on one side of it. Degrees are returned as [lon, lat].
function place({table, street, number, suffixCode}) {
  const start = table.addressStarts[street]
  const end = table.addressStarts[street + 1]
  const held = heldAddress({table, start, end, number, suffixCode})
  if (held !== NOT_FOUND) {
    const {latitude, longitude} = positionOf({table, address: held})
    const exact = {kind: PlacementKind.exact, position: [longitude / MICRODEGREES_PER_DEGREE, latitude / MICRODEGREES_PER_DEGREE]}
    return exact
  }

  const above = lowerBound({numbers: table.numbers, start, end, number})
  const left = sameSideBefore({table, from: above - 1, start, number})
  const right = sameSideFrom({table, from: above, end, number})
  const isBracketed = left !== NOT_FOUND && right !== NOT_FOUND
  if (!isBracketed) {
    const outside = {kind: LookupKind.pastEnd}
    return outside
  }

  const leftNumber = table.numbers[left]
  const rightNumber = table.numbers[right]
  const share = (number - leftNumber) / (rightNumber - leftNumber)
  assertCondition(share > 0, "address lookup: an interpolation share of " + share + " is not past the left neighbor")
  assertCondition(share < 1, "address lookup: an interpolation share of " + share + " is not before the right neighbor")
  const leftPoint = positionOf({table, address: left})
  const rightPoint = positionOf({table, address: right})
  const latitude = leftPoint.latitude + (rightPoint.latitude - leftPoint.latitude) * share
  const longitude = leftPoint.longitude + (rightPoint.longitude - leftPoint.longitude) * share
  const interpolated = {kind: PlacementKind.interpolated, position: [longitude / MICRODEGREES_PER_DEGREE, latitude / MICRODEGREES_PER_DEGREE]}
  return interpolated
}

function heldStreetOf({table, street}) {
  const {strings} = table
  return {
    preDirection: strings[table.preDirections[street]],
    name: strings[table.names[street]],
    type: strings[table.types[street]],
    sufDirection: strings[table.sufDirections[street]],
  }
}

function labelOf({query, held, city}) {
  const line = String(query.number) + query.numberSuffix + " " + streetKey(held)
  if (city === "") {
    return line
  }
  return line + ", " + city
}

// Held points rank before interpolated ones however far they are, then the
// fewer parts filled in, then the nearer.
function byRank(left, right) {
  const isSamePlacement = left.placement === right.placement
  if (!isSamePlacement) {
    if (left.placement === PlacementKind.exact) {
      return BACKWARD
    }
    return FORWARD
  }
  if (left.filledInCount !== right.filledInCount) {
    return left.filledInCount - right.filledInCount
  }
  return left.distanceM - right.distanceM
}

function suffixCodeOf(numberSuffix) {
  if (numberSuffix === "") {
    return SUFFIX_NONE
  }
  return numberSuffix.charCodeAt(0)
}

/**
 * The places that answer `text` in `table`, a shard as `decodeAddressShard`
 * returns it: `{kind: "found", query, results}`, at most `RESULT_COUNT_MAX`
 * results, best first, each `{label, city, lat, lon, placement,
 * filledInCount, distanceM}` with the position in degrees, `placement` one of
 * `PlacementKind`, and the distance in whole meters from `near`, a
 * [lon, lat] position such as the map's center. A typed type or directional
 * must equal the street's, one left out matches any, and a locality must
 * start the postal city. Otherwise `{kind: "noStreet"}` where no street of
 * the shard agrees, `{kind: "pastEnd"}` where a street agrees and none has a
 * same-side neighbor on both sides of the number, or `{kind:
 * "notAnAddress"}` for text with no house number and street. A ZIP code is
 * read and left out, since a shard holds none.
 */
export function searchAddress({text, table, near}) {
  assertCondition(typeof text === "string", "address lookup: the text is not a string: " + typeof text)
  assertPosition(near, "address lookup: the search center")
  const query = parseQuery(text)
  if (query.kind !== ADDRESS_QUERY_KIND) {
    const notAnAddress = {kind: LookupKind.notAnAddress, query}
    return notAnAddress
  }

  const suffixCode = suffixCodeOf(query.numberSuffix)
  let agreeingCount = 0
  const candidates = []
  for (let street = 0; street < table.streetCount; street++) {
    const isSameName = table.strings[table.names[street]] === query.street.name
    if (!isSameName) {
      continue
    }
    const held = heldStreetOf({table, street})
    const city = table.strings[table.cities[street]]
    const isAgreeing = streetAgrees({typed: query.street, held}) && localityAgrees({locality: query.locality, city})
    if (!isAgreeing) {
      continue
    }
    agreeingCount++
    const placed = place({table, street, number: query.number, suffixCode})
    if (placed.kind === LookupKind.pastEnd) {
      continue
    }
    const [lon, lat] = placed.position
    candidates.push({
      label: labelOf({query, held, city}),
      city,
      lat,
      lon,
      placement: placed.kind,
      filledInCount: filledInCount({typed: query.street, held}),
      distanceM: Math.round(distanceMeters(near, [lon, lat])),
    })
  }

  if (agreeingCount === 0) {
    const noStreet = {kind: LookupKind.noStreet, query}
    return noStreet
  }
  if (candidates.length === 0) {
    const pastEnd = {kind: LookupKind.pastEnd, query}
    return pastEnd
  }

  candidates.sort(byRank)
  const results = candidates.slice(0, RESULT_COUNT_MAX)
  const found = {kind: LookupKind.found, query, results}
  return found
}

/**
 * The results of the outcomes of `searchAddress` over several counties'
 * shards, ranked together as one search ranks its own and at most
 * `RESULT_COUNT_MAX`, so a street that runs across a county line is answered
 * from the shards of either side. An outcome that found nothing adds
 * nothing; no outcome that found is an empty list.
 */
export function mergedResults(outcomes) {
  assertCondition(Array.isArray(outcomes), "address lookup: the outcomes are not a list")
  const candidates = []

  for (const outcome of outcomes) {
    if (outcome.kind === LookupKind.found) {
      for (const result of outcome.results) {
        candidates.push(result)
      }
    }
  }

  candidates.sort(byRank)
  return candidates.slice(0, RESULT_COUNT_MAX)
}
