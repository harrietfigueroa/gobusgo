// The breakdown of what Save for offline use stores, by part, in the order
// `breakdownRows` lists them. Everything here is pure: the saved index and each
// stored file's store, path, and size are given as values, and nothing here
// touches a store.
//
// A file of the saved map's store is the map. In the schedules' store a trip
// path index or shard is trip paths by its name alone, indexed or not; the
// rest take their part from the saved index: the tile archive and the places
// file by the addresses the index gives them, and the index, the bundle's
// manifest, and every other file the index names are the schedules. Any
// other file the index does not name, such as one a save in progress stored
// before writing its index, is other.

import {assertCondition, unreachable} from "#core/assert.js"
import {
  BUNDLE_MANIFEST_PATH,
  INDEX_PATH,
  IndexKind,
  OFFLINE_SCHEDULES_CACHE_NAME
} from "#core/offline_bundle.js"
import {KINDS, PackedKind} from "#core/packed_container.js"
import {OFFLINE_BASEMAP_CACHE_NAME} from "./offline_basemap.js"

const KILOBYTE_BYTES = 1000
const MEGABYTE_BYTES = 1000 * 1000
// Sizes under a tenth of a megabyte are shown in kilobytes, so a small file
// never reads as 0.0 MB.
const KILOBYTES_SHOWN_BYTES_MAX = 100_000

function kindEntryOf(number) {
  let found = undefined

  for (const entry of KINDS) {
    if (entry.number === number) {
      found = entry
    }
  }

  assertCondition(found !== undefined, "offline breakdown: a packed kind the table lacks: " + String(number))
  return found
}

const tripPathNamePrefix = kindEntryOf(PackedKind.tripPathShard).prefix + "-"
const tripPathIndexNamePrefix = kindEntryOf(PackedKind.tripPathIndex).prefix + "-"
assertCondition(
  tripPathIndexNamePrefix.startsWith(tripPathNamePrefix),
  "offline breakdown: a trip path index's name does not start as a shard's: " + tripPathIndexNamePrefix
)

/** The parts of the breakdown, in the order `breakdownRows` lists them. */
export const PartKind = Object.freeze({
  schedules: "schedules",
  tripPaths: "tripPaths",
  tiles: "tiles",
  places: "places",
  map: "map",
  other: "other"
})

const PART_ORDER = Object.freeze(Object.values(PartKind))

function fileNameOf(path) {
  const slashIndex = path.lastIndexOf("/")
  return path.slice(slashIndex + 1)
}

function namedPathsOf(savedIndex) {
  switch (savedIndex.kind) {
    case IndexKind.none:
      return new Set()
    case IndexKind.found:
      return new Set([INDEX_PATH, BUNDLE_MANIFEST_PATH, ...savedIndex.index.paths])
    default:
      return unreachable(savedIndex.kind, "offline breakdown: a read of the saved index of unknown kind")
  }
}

function schedulesPartOf({path, savedIndex, namedPaths}) {
  const fileName = fileNameOf(path)

  if (fileName.startsWith(tripPathNamePrefix)) {
    return PartKind.tripPaths
  }

  if (!namedPaths.has(path)) {
    return PartKind.other
  }

  const {index} = savedIndex

  if (path === index.tileArchivePath) {
    return PartKind.tiles
  }

  if (path === index.placesPath) {
    return PartKind.places
  }

  return PartKind.schedules
}

function partOf({file, savedIndex, namedPaths}) {
  if (file.cacheName === OFFLINE_BASEMAP_CACHE_NAME) {
    return PartKind.map
  }

  assertCondition(
    file.cacheName === OFFLINE_SCHEDULES_CACHE_NAME,
    "offline breakdown: a file of a store offline use does not own: " + String(file.cacheName)
  )
  return schedulesPartOf({path: file.path, savedIndex, namedPaths})
}

/**
 * What the two stores of offline use hold, by part: `savedIndex` is a read
 * of the saved index, and `files` every stored file as `{cacheName, path,
 * bytes}`. The result lists each part that holds a file, in PartKind's
 * order, with its bytes, and `totalBytes`, the sum of the parts.
 */
export function offlineBreakdown({savedIndex, files}) {
  const namedPaths = namedPathsOf(savedIndex)
  const bytesByPart = new Map()

  for (const file of files) {
    assertCondition(Number.isSafeInteger(file.bytes), "offline breakdown: a size that is not a whole number: " + String(file.bytes))
    assertCondition(file.bytes >= 0, "offline breakdown: a negative size: " + String(file.bytes))
    const part = partOf({file, savedIndex, namedPaths})
    let bytes = 0

    if (bytesByPart.has(part)) {
      bytes = bytesByPart.get(part)
    }

    bytesByPart.set(part, bytes + file.bytes)
  }

  const parts = []
  let totalBytes = 0

  for (const kind of PART_ORDER) {
    if (bytesByPart.has(kind)) {
      const bytes = bytesByPart.get(kind)
      parts.push({kind, bytes})
      totalBytes += bytes
    }
  }

  assertCondition(parts.length === bytesByPart.size, "offline breakdown: a part outside PartKind")
  return {parts, totalBytes}
}

/** The text of a size of `bytes`: kilobytes, rounded up, under a tenth of a megabyte, and megabytes to one decimal from there. */
export function sizeText(bytes) {
  assertCondition(Number.isSafeInteger(bytes), "offline breakdown: a size that is not a whole number: " + String(bytes))
  assertCondition(bytes >= 0, "offline breakdown: a negative size: " + String(bytes))

  if (bytes < KILOBYTES_SHOWN_BYTES_MAX) {
    const kilobytes = Math.ceil(bytes / KILOBYTE_BYTES)
    return `${kilobytes} kB`
  }

  const megabytes = bytes / MEGABYTE_BYTES
  return megabytes.toFixed(1) + " MB"
}

function termOf(kind) {
  switch (kind) {
    case PartKind.schedules:
      return "Schedules"
    case PartKind.tripPaths:
      return "Trip paths"
    case PartKind.tiles:
      return "Route lines and stops"
    case PartKind.places:
      return "Places"
    case PartKind.map:
      return "Map"
    case PartKind.other:
      return "Other files"
    default:
      return unreachable(kind, "offline breakdown: a part of unknown kind")
  }
}

/**
 * The rows of `breakdown` as terms and definitions: each part's name and
 * size, then the total; no rows where nothing is stored.
 */
export function breakdownRows(breakdown) {
  const rows = []

  for (const part of breakdown.parts) {
    rows.push({term: termOf(part.kind), definition: sizeText(part.bytes)})
  }

  if (rows.length > 0) {
    rows.push({term: "Total", definition: sizeText(breakdown.totalBytes)})
  }

  return rows
}
