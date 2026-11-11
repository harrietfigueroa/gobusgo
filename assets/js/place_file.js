// The places file as Gobusgo.Places.Format writes it: a packed container of
// kind 5, version 1, one record per place. `decodePlaceFile` reads the
// expanded bytes into one table of typed columns and decoded strings, and
// `loadPlaceFile` expands a fetched gzip stream under the kind's bound first.
// Each returns a result keyed by `kind`, the table or the reason the file was
// refused; a bad file is never a throw. Everything here is pure but the
// expansion.

import {assertCondition} from "./assert.js"
import {
  ColumnType,
  PackedKind,
  PackedOutcome,
  decodeContainer,
  expandStream,
  openColumn,
  openPositions,
} from "./packed_container.js"

const PLACE_FILE_VERSION = 1
const SECTION_COUNT = 8
const U32_BYTES = 4
const LABELS_COUNT_MIN = 2
const EXPANDED_MEBIBYTES_MAX = 8
const BYTES_PER_MEBIBYTE = 1024 * 1024

/** The most bytes a places file may expand to. */
export const PLACE_FILE_EXPANDED_BYTES_MAX = EXPANDED_MEBIBYTES_MAX * BYTES_PER_MEBIBYTE

/** The sections of the places kind after the string table, in order. */
export const PlaceSection = Object.freeze({
  names: 0,
  aliasCounts: 1,
  aliasNames: 2,
  positions: 3,
  categories: 4,
  prominences: 5,
  areas: 6,
  labels: 7,
})

/** The reasons the kind refuses a file for, beside the container's own. */
export const PlaceFileRefusal = Object.freeze({
  aliasCounts: "aliasCounts",
  badCategory: "badCategory",
  badStringIndex: "badStringIndex",
  badLabels: "badLabels",
  unknownPosition: "unknownPosition",
})

function refused(reason) {
  return {kind: PackedOutcome.refused, reason}
}

function column({container, index, type, count}) {
  return openColumn({view: container.view, section: container.sections[index], type, count})
}

function readLabels(container) {
  const section = container.sections[PlaceSection.labels]
  const isWhole = section.byteLength % U32_BYTES === 0
  const count = section.byteLength / U32_BYTES
  const hasCategory = count >= LABELS_COUNT_MIN
  const isLabels = isWhole && hasCategory

  if (!isLabels) {
    return refused(PlaceFileRefusal.badLabels)
  }

  return column({container, index: PlaceSection.labels, type: ColumnType.u32, count})
}

// The strings at the `count` indexes `indexes.at` gives, or a refusal when
// one is not in the table.
function stringsAt({strings, indexes, count}) {
  const texts = new Array(count)

  for (let position = 0; position < count; position += 1) {
    const index = indexes.at(position)

    if (index >= strings.count) {
      return refused(PlaceFileRefusal.badStringIndex)
    }

    texts[position] = strings.at(index)
  }

  return {kind: PackedOutcome.decoded, texts}
}

// The alias starts of the places: aliasStarts[i] up to aliasStarts[i + 1] are
// place i's aliases. Refused when they do not end at the alias column's length.
function readAliasStarts({counts, placeCount, aliasCount}) {
  const aliasStarts = new Uint32Array(placeCount + 1)

  for (let place = 0; place < placeCount; place += 1) {
    aliasStarts[place + 1] = aliasStarts[place] + counts.at(place)
  }

  if (aliasStarts[placeCount] !== aliasCount) {
    return refused(PlaceFileRefusal.aliasCounts)
  }

  return {kind: PackedOutcome.decoded, aliasStarts}
}

function copyColumn({source, count}) {
  const copy = new Uint8Array(count)

  for (let index = 0; index < count; index += 1) {
    copy[index] = source.at(index)
  }

  return copy
}

// The latitude and longitude columns, or a refusal for a place with no position.
function readPositions({container, placeCount}) {
  const positions = openPositions({
    view: container.view,
    section: container.sections[PlaceSection.positions],
    count: placeCount,
  })

  if (positions.kind === PackedOutcome.refused) {
    return positions
  }

  const latitudes = new Int32Array(placeCount)
  const longitudes = new Int32Array(placeCount)

  for (let place = 0; place < placeCount; place += 1) {
    if (!positions.isKnownAt(place)) {
      return refused(PlaceFileRefusal.unknownPosition)
    }

    latitudes[place] = positions.latitudeAt(place)
    longitudes[place] = positions.longitudeAt(place)
  }

  return {kind: PackedOutcome.decoded, latitudes, longitudes}
}

// The first of `results` that is a refusal, or a decoded result when none is.
function firstRefusal(results) {
  for (const result of results) {
    if (result.kind === PackedOutcome.refused) {
      return result
    }
  }

  return {kind: PackedOutcome.decoded}
}

function hasCategoryPast({categories, placeCount, categoryCount}) {
  for (let place = 0; place < placeCount; place += 1) {
    if (categories[place] >= categoryCount) {
      return true
    }
  }

  return false
}

// The columns of the fixed-width sections, or the first refusal.
function openColumns({container, placeCount}) {
  const u8 = ColumnType.u8
  const names = column({container, index: PlaceSection.names, type: ColumnType.u32, count: placeCount})
  const aliasCounts = column({container, index: PlaceSection.aliasCounts, type: u8, count: placeCount})
  const categories = column({container, index: PlaceSection.categories, type: u8, count: placeCount})
  const prominences = column({container, index: PlaceSection.prominences, type: u8, count: placeCount})
  const areas = column({container, index: PlaceSection.areas, type: u8, count: placeCount})
  const labels = readLabels(container)
  const refusal = firstRefusal([names, aliasCounts, categories, prominences, areas, labels])

  if (refusal.kind === PackedOutcome.refused) {
    return refusal
  }

  return {kind: PackedOutcome.decoded, names, aliasCounts, categories, prominences, areas, labels}
}

// The alias starts and the alias column, or the first refusal.
function readAliases({container, columns, placeCount}) {
  const aliasBytes = container.sections[PlaceSection.aliasNames].byteLength

  if (aliasBytes % U32_BYTES !== 0) {
    return refused(PlaceFileRefusal.aliasCounts)
  }

  const aliasCount = aliasBytes / U32_BYTES
  const starts = readAliasStarts({counts: columns.aliasCounts, placeCount, aliasCount})

  if (starts.kind === PackedOutcome.refused) {
    return starts
  }

  const indexes = column({container, index: PlaceSection.aliasNames, type: ColumnType.u32, count: aliasCount})

  if (indexes.kind === PackedOutcome.refused) {
    return indexes
  }

  return {kind: PackedOutcome.decoded, aliasStarts: starts.aliasStarts, indexes, aliasCount}
}

/**
 * The places of `bytes`, the expanded container: `{kind: "decoded", table}`,
 * where `table` is `{placeCount, names, aliasStarts, aliasNames,
 * latitudeMicrodegrees, longitudeMicrodegrees, categories, prominences,
 * areas, categoryNames, sourceDate}`, or `{kind: "refused", reason}` with a
 * reason of the container or of `PlaceFileRefusal`. Place `i`'s aliases are
 * `aliasNames[aliasStarts[i]]` up to `aliasNames[aliasStarts[i + 1]]`. Every
 * string is decoded once here, eagerly.
 */
export function decodePlaceFile(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.places,
    versions: [PLACE_FILE_VERSION],
    sectionCount: SECTION_COUNT,
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const placeCount = container.header.recordCount
  const columns = openColumns({container, placeCount})

  if (columns.kind === PackedOutcome.refused) {
    return columns
  }

  const aliases = readAliases({container, columns, placeCount})
  const positions = readPositions({container, placeCount})
  const refusal = firstRefusal([aliases, positions])

  if (refusal.kind === PackedOutcome.refused) {
    return refusal
  }

  const {strings} = container
  const labels = stringsAt({strings, indexes: columns.labels, count: columns.labels.count})
  const names = stringsAt({strings, indexes: columns.names, count: placeCount})
  const aliasNames = stringsAt({strings, indexes: aliases.indexes, count: aliases.aliasCount})
  const textRefusal = firstRefusal([labels, names, aliasNames])

  if (textRefusal.kind === PackedOutcome.refused) {
    return textRefusal
  }

  const [sourceDate, ...categoryNames] = labels.texts
  const categories = copyColumn({source: columns.categories, count: placeCount})

  if (hasCategoryPast({categories, placeCount, categoryCount: categoryNames.length})) {
    return refused(PlaceFileRefusal.badCategory)
  }

  const table = {
    placeCount,
    names: names.texts,
    aliasStarts: aliases.aliasStarts,
    aliasNames: aliasNames.texts,
    latitudeMicrodegrees: positions.latitudes,
    longitudeMicrodegrees: positions.longitudes,
    categories,
    prominences: copyColumn({source: columns.prominences, count: placeCount}),
    areas: copyColumn({source: columns.areas, count: placeCount}),
    categoryNames,
    sourceDate,
  }

  return {kind: PackedOutcome.decoded, table}
}

/**
 * The places of `source`, a fetched places file, its gzip stream as bytes or
 * a ReadableStream: the result of `decodePlaceFile` after expanding it to at
 * most `PLACE_FILE_EXPANDED_BYTES_MAX` bytes, or a refusal of the expansion.
 */
export async function loadPlaceFile(source) {
  assertCondition(source !== undefined, "the source must be given")
  assertCondition(source !== null, "the source must not be null")
  const expanded = await expandStream(source, {expandedByteSizeMax: PLACE_FILE_EXPANDED_BYTES_MAX})

  if (expanded.kind === PackedOutcome.refused) {
    return expanded
  }

  return decodePlaceFile(expanded.bytes)
}
