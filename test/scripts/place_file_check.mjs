// Decodes the shared places fixture, expanded and as a gzip stream, and
// compares the table with the expected table the fixture holds beside it,
// decodes the published version 1 fixture to the same table with an empty
// locality for every place, then checks the refusals that are the kind's own
// as values: another version, a wrong section count for each version, alias
// counts that run past the alias column, a category index past the
// categories, a place with no position, a name index past the string table,
// a locality index past it, a locality past the length bound, labels with no
// category, and an expansion past the kind's bound. Run it with
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

const fixtureDirectory = fileURLToPath(new URL("../fixtures/places/v2/", import.meta.url))
const versionOneDirectory = fileURLToPath(new URL("../fixtures/places/v1/", import.meta.url))
const VERSION_CURRENT = 2
const FIXTURE_VERSIONS = Object.freeze([VERSION_CURRENT])
const VERSION_OFFSET = 4
const VERSION_UNKNOWN = 3
const SECTION_COUNT = 9
const SECTION_COUNT_VERSION_ONE = 8
const U32_BYTES = 4
const LATITUDE_OFFSET = 0
const LONGITUDE_OFFSET = 4
const ALIAS_COUNT_PAST_COLUMN = 9
const CATEGORY_PAST_CATEGORIES = 99
const NAME_PAST_TABLE = 999
const LOCALITY_PAST_TABLE = 999
const BOUND_PAD_BYTES = 16
const LITTLE_ENDIAN = true

const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const expanded = new Uint8Array(readFileSync(fixtureDirectory + "places.bin"))
const stream = new Uint8Array(readFileSync(fixtureDirectory + "places.bin.gz"))
const overBound = new Uint8Array(readFileSync(fixtureDirectory + "locality_over_bound.bin"))
const expectedVersionOne = JSON.parse(readFileSync(versionOneDirectory + "expected.json", "utf-8"))
const expandedVersionOne = new Uint8Array(readFileSync(versionOneDirectory + "places.bin"))

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
    localities: table.localities,
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

function emptyLocality() {
  return ""
}

function checkVersionOne() {
  const result = decodePlaceFile(expandedVersionOne)
  deepStrictEqual(result.kind, PackedOutcome.decoded)
  const noLocalities = Array.from({length: expectedVersionOne.placeCount}, emptyLocality)
  deepStrictEqual(plain(result.table), {...expectedVersionOne, localities: noLocalities}, "the version 1 fixture")
}

async function checkLoads() {
  const result = await loadPlaceFile(stream)
  deepStrictEqual(result.kind, PackedOutcome.decoded)
  deepStrictEqual(plain(result.table), expected, "the gzip fixture")
}

function checkHeaderRefusals() {
  const otherVersion = new Uint8Array(expanded)
  new DataView(otherVersion.buffer).setUint16(VERSION_OFFSET, VERSION_UNKNOWN, LITTLE_ENDIAN)
  const versionResult = decodePlaceFile(otherVersion)
  expectRefusal({label: "another version", result: versionResult, reason: PackedRefusal.unsupportedVersion})

  const versionOneWithLocalities = new Uint8Array(expanded)
  new DataView(versionOneWithLocalities.buffer).setUint16(VERSION_OFFSET, 1, LITTLE_ENDIAN)
  const oneResult = decodePlaceFile(versionOneWithLocalities)
  expectRefusal({label: "version 1 with 9 sections", result: oneResult, reason: PackedRefusal.sectionCount})

  const versionTwoWithEight = new Uint8Array(expandedVersionOne)
  new DataView(versionTwoWithEight.buffer).setUint16(VERSION_OFFSET, VERSION_CURRENT, LITTLE_ENDIAN)
  const twoResult = decodePlaceFile(versionTwoWithEight)
  expectRefusal({label: "version 2 with 8 sections", result: twoResult, reason: PackedRefusal.sectionCount})

  const extraSection = new Uint8Array(expanded.byteLength + U32_BYTES)
  extraSection.set(expanded)
  const sectionResult = decodePlaceFile(extraSection)
  expectRefusal({label: "another section count", result: sectionResult, reason: PackedRefusal.sectionCount})
}

function setLocality(view, section) {
  view.setUint32(section.offset, LOCALITY_PAST_TABLE, LITTLE_ENDIAN)
}

function checkLocalityRefusals() {
  const localityPast = patched({index: PlaceSection.localities, write: setLocality})
  const pastResult = decodePlaceFile(localityPast)
  expectRefusal({label: "a locality past the string table", result: pastResult, reason: PlaceFileRefusal.badStringIndex})

  const overResult = decodePlaceFile(overBound)
  expectRefusal({label: "a locality past the length bound", result: overResult, reason: PlaceFileRefusal.badLocality})
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

// The labels are the last section of version 1, so a version 1 file cut after one label has no category.
function checkLabelRefusal() {
  const versionOne = decodeContainer(expandedVersionOne, {
    kind: PackedKind.places,
    versions: [1],
    sectionCount: SECTION_COUNT_VERSION_ONE,
  })
  const labels = versionOne.sections[PlaceSection.labels]
  const oneLabel = expandedVersionOne.slice(0, labels.offset + U32_BYTES)
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
checkVersionOne()
await checkLoads()
checkHeaderRefusals()
checkColumnRefusals()
checkLocalityRefusals()
checkLabelRefusal()
await checkBound()
console.log("place_file_check: ok")
