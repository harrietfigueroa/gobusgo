// Checks the shared vehicle reader against the block fixture that
// `Gobusgo.Gbfs.VehicleTileFormatTest` encodes from the vehicles of
// `shared_vehicle_block.json`, so the Elixir writer and the JavaScript
// reader agree byte for byte, then against broken copies of it, and reads
// the index fixture whose keys `Gobusgo.Gbfs.VehicleTileSetTest` checks
// against a built index. Run it with
// `node test/scripts/shared_vehicle_format_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {DecodeKind, decodeBlock, fileUrl, readIndex} from "../../assets/js/shared_vehicle_format.js"

const FIXTURE_DIRECTORY = "../fixtures/gbfs/"
const MICRODEGREES_PER_DEGREE = 1_000_000
const FRACTION_MAX = 0xFFFF
const VERSION_OFFSET = 4
const COUNT_OFFSET = 8
const BOUNDS_OFFSET = 12
const HEADER_BYTES = 28
// The highest byte of the south bound, which made 0x80 is a large negative
// latitude.
const SOUTH_HIGHEST_BYTE_OFFSET = 15
const NEGATIVE_HIGHEST_BYTE = 0x80
const CUT_HEADER_BYTES = 10
const UNKNOWN_FORM_CODE = 9
const OTHER_MAGIC_BYTE = 0x58
const OTHER_VERSION = 2
const INDEX_DIRECTORY = "/shared-vehicles/dt=2026-11-08/system=lime_seattle/20261108T190830Z_x/"

function fixtureBytes(name) {
  const path = new URL(FIXTURE_DIRECTORY + name, import.meta.url)
  const content = readFileSync(path)
  return new Uint8Array(content)
}

function fixtureJson(name) {
  const path = new URL(FIXTURE_DIRECTORY + name, import.meta.url)
  const text = readFileSync(path, "utf8")
  return JSON.parse(text)
}

const fixture = fixtureBytes("shared_vehicle_block.bin")
const expected = fixtureJson("shared_vehicle_block.json")
const indexValue = fixtureJson("shared_vehicle_index.json")
const latSpanDegrees = (expected.bounds.north - expected.bounds.south) / MICRODEGREES_PER_DEGREE
const lonSpanDegrees = (expected.bounds.east - expected.bounds.west) / MICRODEGREES_PER_DEGREE
const latStepDegrees = latSpanDegrees / FRACTION_MAX
const lonStepDegrees = lonSpanDegrees / FRACTION_MAX

function decodedBlock(bytes) {
  const outcome = decodeBlock(bytes)
  deepStrictEqual(outcome.kind, DecodeKind.decoded, `decoded: ${JSON.stringify(outcome)}`)
  return outcome.block
}

const block = decodedBlock(fixture)

deepStrictEqual(block.bounds, expected.bounds, "bounds")

for (const [index, vehicle] of block.vehicles.entries()) {
  const latDifference = Math.abs(vehicle.lat - expected.vehicles[index].lat)
  const lonDifference = Math.abs(vehicle.lon - expected.vehicles[index].lon)
  ok(latDifference <= latStepDegrees, `latitude ${index}: ${vehicle.lat}`)
  ok(lonDifference <= lonStepDegrees, `longitude ${index}: ${vehicle.lon}`)
}

function rangeOf(vehicle) {
  return vehicle.rangeMeters
}

function formOf(vehicle) {
  return vehicle.formFactor
}

const ranges = Array.from(block.vehicles, rangeOf)
deepStrictEqual(ranges, expected.decodedRangesMeters, "ranges")

const forms = Array.from(block.vehicles, formOf)
const expectedForms = Array.from(expected.vehicles, formOf)
deepStrictEqual(forms, expectedForms, "form factors")

// A block with no vehicles is its header alone, with a count of zero.
const emptyBytes = Uint8Array.from(fixture.slice(0, HEADER_BYTES))
emptyBytes.fill(0, COUNT_OFFSET, BOUNDS_OFFSET)
const empty = decodedBlock(emptyBytes)
deepStrictEqual(empty.vehicles, [], "no vehicles")

function withByte({offset, value}) {
  const copy = Uint8Array.from(fixture)
  copy[offset] = value
  return copy
}

const brokenCases = [
  {name: "another magic", bytes: withByte({offset: 0, value: OTHER_MAGIC_BYTE}), reason: "magic"},
  {name: "another version", bytes: withByte({offset: VERSION_OFFSET, value: OTHER_VERSION}), reason: "version"},
  {name: "a block cut short", bytes: fixture.slice(0, fixture.length - 1), reason: "length"},
  {name: "a header cut short", bytes: fixture.slice(0, CUT_HEADER_BYTES), reason: "length"},
  {name: "a form code it does not know", bytes: withByte({offset: fixture.length - 1, value: UNKNOWN_FORM_CODE}), reason: "formFactor"},
  {name: "bounds outside their axis", bytes: withByte({offset: SOUTH_HIGHEST_BYTE_OFFSET, value: NEGATIVE_HIGHEST_BYTE}), reason: "bounds"}
]

for (const brokenCase of brokenCases) {
  deepStrictEqual(decodeBlock(brokenCase.bytes), {kind: DecodeKind.refused, reason: brokenCase.reason}, brokenCase.name)
}

const read = readIndex(indexValue)
deepStrictEqual(read.kind, DecodeKind.decoded, "index read")
deepStrictEqual(read.index.fetchedAtMs, Date.parse(indexValue.fetchedAt), "index fetch time")
deepStrictEqual(read.index.cityName, indexValue.city, "index whole-city file")

for (const [x, y, count, hash] of indexValue.tiles) {
  const name = `tile-${indexValue.tileZoom}-${x}-${y}-${hash}.bin.gz`
  deepStrictEqual(read.index.tiles.get(`${x}/${y}`), {x, y, count, name}, `index tile ${x}/${y}`)
}

deepStrictEqual(read.index.tiles.size, indexValue.tiles.length, "index tiles")

const brokenIndexes = [
  {name: "not an object", value: null},
  {name: "another format version", value: {...indexValue, formatVersion: OTHER_VERSION}},
  {name: "no fetch time", value: {...indexValue, fetchedAt: "yesterday"}},
  {name: "a tile of another shape", value: {...indexValue, tiles: [["1312", "2859"]]}},
  {name: "no whole-city file", value: {...indexValue, city: null}}
]

for (const brokenIndex of brokenIndexes) {
  deepStrictEqual(readIndex(brokenIndex.value).kind, DecodeKind.refused, brokenIndex.name)
}

deepStrictEqual(
  fileUrl({indexUrl: INDEX_DIRECTORY + "index-0123456789abcdef.json.gz", name: indexValue.city}),
  INDEX_DIRECTORY + indexValue.city,
  "a file beside the index"
)

console.log("shared vehicle format: every case matches")
