// Decodes the shared places fixture, expanded and as a gzip stream, and
// compares the table with the expected table the fixture holds beside it,
// then checks the refusals that are the kind's own as values: another
// version, a wrong section count, alias counts that run past the alias
// column, a category index past the categories, a place with no position, a
// name index past the string table, labels with no category, and an
// expansion past the kind's bound. Run it with
// `node test/scripts/place_file_check.mjs`; it exits non-zero on the first
// result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual} from "node:assert/strict"
import {
  PLACE_FILE_EXPANDED_BYTES_MAX,
  PlaceFileRefusal,
  PlaceSection,
  decodePlaceFile,
  loadPlaceFile,
} from "../../assets/js/place_file.js"
import {
  PackedKind,
  PackedOutcome,
  PackedRefusal,
  UNKNOWN_MICRODEGREES,
  decodeContainer,
} from "../../assets/js/packed_container.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/places/v1/", import.meta.url))
const FIXTURE_VERSIONS = Object.freeze([1])
const VERSION_OFFSET = 4
const VERSION_SECOND = 2
const SECTION_COUNT = 8
const U32_BYTES = 4
const LATITUDE_OFFSET = 0
const LONGITUDE_OFFSET = 4
const ALIAS_COUNT_PAST_COLUMN = 9
const CATEGORY_PAST_CATEGORIES = 99
const NAME_PAST_TABLE = 999
const BOUND_PAD_BYTES = 16
const LITTLE_ENDIAN = true

const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const expanded = new Uint8Array(readFileSync(fixtureDirectory + "places.bin"))
const stream = new Uint8Array(readFileSync(fixtureDirectory + "places.bin.gz"))

function plain(table) {
  return {
    placeCount: table.placeCount,
    names: table.names,
    aliasStarts: Array.from(table.aliasStarts),
    aliasNames: table.aliasNames,
    latitudeMicrodegrees: Array.from(table.latitudeMicrodegrees),
    longitudeMicrodegrees: Array.from(table.longitudeMicrodegrees),
    categories: Array.from(table.categories),
    prominences: Array.from(table.prominences),
    areas: Array.from(table.areas),
    categoryNames: table.categoryNames,
    sourceDate: table.sourceDate,
  }
}

function fixtureContainer() {
  return decodeContainer(expanded, {
    kind: PackedKind.places,
    versions: FIXTURE_VERSIONS,
    sectionCount: SECTION_COUNT,
  })
}

// A copy of the fixture with `write(view, section)` applied to one section after the string table.
function patched({index, write}) {
  const bytes = new Uint8Array(expanded)
  const view = new DataView(bytes.buffer)
  write(view, fixtureContainer().sections[index])
  return bytes
}

function expectRefusal({label, result, reason}) {
  deepStrictEqual(result, {kind: PackedOutcome.refused, reason}, label)
}

function setAliasCount(view, section) {
  view.setUint8(section.offset, ALIAS_COUNT_PAST_COLUMN)
}

function setCategory(view, section) {
  view.setUint8(section.offset, CATEGORY_PAST_CATEGORIES)
}

function setUnknownPosition(view, section) {
  view.setInt32(section.offset + LATITUDE_OFFSET, UNKNOWN_MICRODEGREES, LITTLE_ENDIAN)
  view.setInt32(section.offset + LONGITUDE_OFFSET, UNKNOWN_MICRODEGREES, LITTLE_ENDIAN)
}

function setName(view, section) {
  view.setUint32(section.offset, NAME_PAST_TABLE, LITTLE_ENDIAN)
}

function checkDecodes() {
  const result = decodePlaceFile(expanded)
  deepStrictEqual(result.kind, PackedOutcome.decoded)
  deepStrictEqual(plain(result.table), expected, "the expanded fixture")
}

async function checkLoads() {
  const result = await loadPlaceFile(stream)
  deepStrictEqual(result.kind, PackedOutcome.decoded)
  deepStrictEqual(plain(result.table), expected, "the gzip fixture")
}

function checkHeaderRefusals() {
  const otherVersion = new Uint8Array(expanded)
  new DataView(otherVersion.buffer).setUint16(VERSION_OFFSET, VERSION_SECOND, LITTLE_ENDIAN)
  const versionResult = decodePlaceFile(otherVersion)
  expectRefusal({label: "another version", result: versionResult, reason: PackedRefusal.unsupportedVersion})

  const extraSection = new Uint8Array(expanded.byteLength + U32_BYTES)
  extraSection.set(expanded)
  const sectionResult = decodePlaceFile(extraSection)
  expectRefusal({label: "another section count", result: sectionResult, reason: PackedRefusal.sectionCount})
}

function checkColumnRefusals() {
  const aliasPast = patched({index: PlaceSection.aliasCounts, write: setAliasCount})
  const aliasResult = decodePlaceFile(aliasPast)
  expectRefusal({label: "alias counts past the column", result: aliasResult, reason: PlaceFileRefusal.aliasCounts})

  const categoryPast = patched({index: PlaceSection.categories, write: setCategory})
  const categoryResult = decodePlaceFile(categoryPast)
  expectRefusal({label: "a category past the categories", result: categoryResult, reason: PlaceFileRefusal.badCategory})

  const noPosition = patched({index: PlaceSection.positions, write: setUnknownPosition})
  const positionResult = decodePlaceFile(noPosition)
  expectRefusal({label: "an unknown position", result: positionResult, reason: PlaceFileRefusal.unknownPosition})

  const namePast = patched({index: PlaceSection.names, write: setName})
  const nameResult = decodePlaceFile(namePast)
  expectRefusal({label: "a name past the string table", result: nameResult, reason: PlaceFileRefusal.badStringIndex})
}

// The labels are the last section, so a file cut after one label has no category.
function checkLabelRefusal() {
  const labels = fixtureContainer().sections[PlaceSection.labels]
  const oneLabel = expanded.slice(0, labels.offset + U32_BYTES)
  new DataView(oneLabel.buffer).setUint32(labels.offset - U32_BYTES, U32_BYTES, LITTLE_ENDIAN)
  const result = decodePlaceFile(oneLabel)
  expectRefusal({label: "labels with no category", result, reason: PlaceFileRefusal.badLabels})
}

async function checkBound() {
  const tooLarge = new Uint8Array(PLACE_FILE_EXPANDED_BYTES_MAX + BOUND_PAD_BYTES)
  const compression = new CompressionStream("gzip")
  const compressedStream = new Blob([tooLarge]).stream().pipeThrough(compression)
  const compressed = await new Response(compressedStream).arrayBuffer()
  const result = await loadPlaceFile(new Uint8Array(compressed))
  expectRefusal({label: "an expansion past the bound", result, reason: PackedRefusal.tooLarge})
}

checkDecodes()
await checkLoads()
checkHeaderRefusals()
checkColumnRefusals()
checkLabelRefusal()
await checkBound()
console.log("place_file_check: ok")
