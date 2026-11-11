// Checks the address lookup as pure functions: the shard an index names for
// what a rider typed, and the places a decoded shard gives for it. The shared
// shard and index fixtures of the address kinds cover the parsing, the
// matching, and the placements of a held number, an interpolated one, and
// one past the street's end; shards built here from the cases of the lookup
// fixture beside them cover the ranking, which needs several streets of one
// name. Each case checks one behavior. Run it with
// `node test/scripts/address_lookup_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {decodeAddressIndex, decodeAddressShard} from "../../assets/js/address_file.js"
import {LookupKind, PlacementKind, RESULT_COUNT_MAX, mergedResults, searchAddress, shardFor} from "../../assets/js/address_lookup.js"
import {AssertionError} from "../../assets/js/assert.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/addresses/", import.meta.url))
const MICRODEGREES = 1_000_000
const POSITION_TOLERANCE = 1e-9
const NOT_A_POSITION = [Number.NaN, 0]
const NOT_TEXT = 7
const SUFFIX_NONE = 0
const DECODED = "decoded"

const cases = JSON.parse(readFileSync(fixtureDirectory + "lookup.json", "utf-8"))

function decodedFixture({name, decode}) {
  const bytes = new Uint8Array(readFileSync(fixtureDirectory + "v1/" + name))
  const decoded = decode(bytes)
  deepStrictEqual(decoded.kind, DECODED, "fixture " + name + " decodes")
  return decoded.table
}

const fixtureShard = decodedFixture({name: "shard.bin", decode: decodeAddressShard})
const fixtureIndex = decodedFixture({name: "index.bin", decode: decodeAddressIndex})

function stringIndexOf({strings, text}) {
  const found = strings.indexOf(text)
  if (found >= 0) {
    return found
  }
  strings.push(text)
  return strings.length - 1
}

/** A decoded shard, in the shape `decodeAddressShard` gives, of streets written out in full. */
function shardOf(streets) {
  const strings = []
  const columns = {names: [], preDirections: [], types: [], sufDirections: [], cities: []}
  const addressStarts = [0]
  const numbers = []
  const positions = []
  for (const street of streets) {
    columns.names.push(stringIndexOf({strings, text: street.name}))
    columns.preDirections.push(stringIndexOf({strings, text: street.preDirection}))
    columns.types.push(stringIndexOf({strings, text: street.type}))
    columns.sufDirections.push(stringIndexOf({strings, text: street.sufDirection}))
    columns.cities.push(stringIndexOf({strings, text: street.city}))
    for (const [number, lat, lon] of street.addresses) {
      numbers.push(number)
      positions.push(Math.round(lat * MICRODEGREES), Math.round(lon * MICRODEGREES))
    }
    addressStarts.push(numbers.length)
  }
  return {
    streetCount: streets.length,
    strings,
    names: Uint32Array.from(columns.names),
    preDirections: Uint32Array.from(columns.preDirections),
    types: Uint32Array.from(columns.types),
    sufDirections: Uint32Array.from(columns.sufDirections),
    cities: Uint32Array.from(columns.cities),
    addressStarts: Uint32Array.from(addressStarts),
    numbers: Uint32Array.from(numbers),
    suffixes: new Uint8Array(numbers.length).fill(SUFFIX_NONE),
    positions: Int32Array.from(positions),
  }
}

function close({actual, expected, label}) {
  ok(Math.abs(actual - expected) < POSITION_TOLERANCE, label + ": " + actual + " is not " + expected)
}

function outcomeOf({text, table}) {
  return searchAddress({text, table, near: cases.center})
}

function firstResult({text, table}) {
  const outcome = outcomeOf({text, table})
  deepStrictEqual(outcome.kind, LookupKind.found, "the outcome of " + JSON.stringify(text))
  return outcome.results[0]
}

function cityOf(result) {
  return result.city
}

function placementOf(result) {
  return result.placement
}

// A held number is answered at its own point, matching its letter where the
// shard holds one.
for (const {text, lat, lon} of cases.held) {
  const result = firstResult({text, table: fixtureShard})
  deepStrictEqual(result.placement, PlacementKind.exact, "placement of " + text)
  close({actual: result.lat, expected: lat, label: "latitude of " + text})
  close({actual: result.lon, expected: lon, label: "longitude of " + text})
}

// A number between two on the same side of the street is placed between them
// by the share of the numbers' span it covers.
const interpolated = firstResult({text: cases.interpolated.text, table: fixtureShard})
deepStrictEqual(interpolated.placement, PlacementKind.interpolated, "placement of an absent number")
close({actual: interpolated.lat, expected: cases.interpolated.lat, label: "interpolated latitude"})
close({actual: interpolated.lon, expected: cases.interpolated.lon, label: "interpolated longitude"})

// A number with no same-side neighbor on both sides, or past either end of
// the street, has no answer, and the outcome says the street was found.
for (const text of cases.pastEnd) {
  deepStrictEqual(outcomeOf({text, table: fixtureShard}).kind, LookupKind.pastEnd, "outcome of " + text)
}

// A typed type or directional must match the street's, and one left out
// matches any.
for (const {text, city} of cases.cityOfFirst) {
  deepStrictEqual(firstResult({text, table: fixtureShard}).city, city, "city of " + text)
}
for (const text of cases.noStreet) {
  deepStrictEqual(outcomeOf({text, table: fixtureShard}).kind, LookupKind.noStreet, "outcome of " + text)
}

// A locality is a prefix of the postal city; a ZIP code is read and left
// out, since a shard holds none.
for (const {text, kind} of cases.locality) {
  deepStrictEqual(outcomeOf({text, table: fixtureShard}).kind, kind, "outcome of " + text)
}

// A unit is dropped and a numbered street is read in each of its spellings.
const plainResult = firstResult({text: cases.held[0].text, table: fixtureShard})
for (const text of cases.spellings) {
  deepStrictEqual(firstResult({text, table: fixtureShard}).lat, plainResult.lat, "latitude of " + text)
}

// Text with no house number and street is not an address.
for (const text of cases.notAnAddress) {
  deepStrictEqual(outcomeOf({text, table: fixtureShard}).kind, LookupKind.notAnAddress, "outcome of " + JSON.stringify(text))
}

// A result names its number, street, and city, the city left out where the
// street has none.
for (const {text, label} of cases.labels) {
  deepStrictEqual(firstResult({text, table: fixtureShard}).label, label, "label of " + text)
}

// A held point ranks before an interpolated one however far it is, then the
// fewer parts filled in, then the nearer.
const rankShard = shardOf(cases.rankStreets)
for (const {why, text, near, cities, placements} of cases.ranking) {
  const {results} = searchAddress({text, table: rankShard, near})
  const rankedCities = Array.from(results, cityOf)
  const rankedPlacements = Array.from(results, placementOf)
  deepStrictEqual(rankedCities, cities, "cities ranked for " + why)
  deepStrictEqual(rankedPlacements, placements, "placements ranked for " + why)
}

// At most five results are returned.
const manyResults = outcomeOf({text: "2 oak st", table: shardOf(cases.manyStreets)}).results
deepStrictEqual(manyResults.length, RESULT_COUNT_MAX, "result count")
deepStrictEqual(RESULT_COUNT_MAX, cases.resultCountMax, "the documented result limit")

// The shard of a query is the longest prefix of its name key the index
// names, or the shard of the name alone where the name is a split prefix.
for (const {text, path} of cases.shards) {
  const outcome = shardFor({index: fixtureIndex, text})
  deepStrictEqual(outcome.kind, LookupKind.found, "outcome for " + text)
  deepStrictEqual(outcome.path, path, "path for " + text)
}
const ownNameShard = shardFor({index: fixtureIndex, text: "5 main st"})
deepStrictEqual(ownNameShard.byteSize, fixtureIndex.byteSizes[1], "byte size of the shard of a name alone")
deepStrictEqual(ownNameShard.sha256, fixtureIndex.sha256s[1], "digest of the shard of a name alone")
deepStrictEqual(shardFor({index: fixtureIndex, text: "pike place market"}).kind, LookupKind.notAnAddress, "an index lookup of a street alone")

const uncoveredIndex = {shardCount: 1, prefixes: ["PINE"], paths: ["a"], byteSizes: Uint32Array.of(1), sha256s: ["x"]}
deepStrictEqual(shardFor({index: uncoveredIndex, text: "5 oak st"}).kind, LookupKind.noShard, "a name no prefix covers")

// Each county's shard is searched on its own, and their found results are
// ranked together, at most five, so a street on a county line is answered
// from either side; an outcome that found nothing adds nothing.
function result({city, placement, filledInCount, distanceM}) {
  return {label: "1 MAIN ST", city, lat: 47.6, lon: -122.3, placement, filledInCount, distanceM}
}

const kingFound = {kind: LookupKind.found, query: {}, results: [
  result({city: "SEATTLE", placement: PlacementKind.interpolated, filledInCount: 0, distanceM: 10}),
  result({city: "KENT", placement: PlacementKind.exact, filledInCount: 1, distanceM: 900}),
]}
const pierceFound = {kind: LookupKind.found, query: {}, results: [
  result({city: "TACOMA", placement: PlacementKind.exact, filledInCount: 0, distanceM: 4000}),
  result({city: "FIFE", placement: PlacementKind.exact, filledInCount: 1, distanceM: 50}),
]}
const snohomishNothing = {kind: LookupKind.noStreet, query: {}}
const merged = mergedResults([kingFound, pierceFound, snohomishNothing])
deepStrictEqual(Array.from(merged, cityOf), ["TACOMA", "FIFE", "KENT", "SEATTLE"], "results of several counties ranked together")
deepStrictEqual(mergedResults([snohomishNothing, {kind: LookupKind.pastEnd, query: {}}]), [], "no county found the address")
const crowded = Array.from({length: RESULT_COUNT_MAX}, () => kingFound)
deepStrictEqual(mergedResults(crowded).length, RESULT_COUNT_MAX, "merged results are at most the result limit")

// Programmer errors crash.
function searchNotText() {
  return searchAddress({text: NOT_TEXT, table: fixtureShard, near: cases.center})
}

function searchNotPosition() {
  return searchAddress({text: cases.held[0].text, table: fixtureShard, near: NOT_A_POSITION})
}

function shardForNotText() {
  return shardFor({index: fixtureIndex, text: NOT_TEXT})
}

throws(searchNotText, AssertionError, "a text that is not a string")
throws(searchNotPosition, AssertionError, "a center that is not a position")
throws(shardForNotText, AssertionError, "an index lookup of a text that is not a string")

console.log("address_lookup_check: ok")
