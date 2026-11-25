// Checks the breakdown of what Save for offline use stores against stores
// written out by hand: each part of a full store, a store with no places
// file, one with no map extract, a file the index does not name, the files
// of a save in progress before its index is written, and the empty store;
// then the rows the Settings tab shows and the size each row reads. Run it
// with `node test/scripts/offline_breakdown_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {
  BUNDLE_MANIFEST_PATH,
  INDEX_PATH,
  IndexKind,
  OFFLINE_SCHEDULES_CACHE_NAME
} from "../../assets/js/core/offline_bundle.js"
import {OFFLINE_BASEMAP_CACHE_NAME} from "../../assets/js/offline_basemap.js"
import {PartKind, breakdownRows, offlineBreakdown, sizeText} from "../../assets/js/offline_breakdown.js"

const DATE_DIRECTORY = "/routing/snapshots/dt=2026-11-09/"
const STOPS_PATH = DATE_DIRECTORY + "stops-1111.bin.gz"
const CONNECTIONS_PATH = DATE_DIRECTORY + "connections-2222.bin.gz"
const NAMES_PATH = DATE_DIRECTORY + "names-3333.json.gz"
const TRIP_PATH_INDEX_PATH = DATE_DIRECTORY + "trip-paths-index-4444.bin.gz"
const TRIP_PATH_SHARD_PATH = DATE_DIRECTORY + "trip-paths-5555.bin.gz"
const TILE_ARCHIVE_PATH = "/tiles/route-stops/dt=2026-11-09/route-stops-20261109T040000Z-6666.pmtiles"
const PLACES_PATH = "/places/places-7777.bin.gz"
const EXTRACT_PATH = "/basemap/basemap-20261004-01-z13.pmtiles"
const NEXT_DATE_STOPS_PATH = "/routing/snapshots/dt=2026-11-10/stops-8888.bin.gz"

const SNAPSHOT_PATHS = [STOPS_PATH, CONNECTIONS_PATH, NAMES_PATH]
const TRIP_PATH_PATHS = [TRIP_PATH_INDEX_PATH, TRIP_PATH_SHARD_PATH]

function indexOf({placesPath}) {
  const paths = [...SNAPSHOT_PATHS, ...TRIP_PATH_PATHS, TILE_ARCHIVE_PATH]

  if (placesPath !== "") {
    paths.push(placesPath)
  }

  return {
    kind: IndexKind.found,
    index: {
      savedAtMs: 0,
      formatVersion: 2,
      dates: [],
      paths,
      manifestPath: BUNDLE_MANIFEST_PATH,
      tileArchivePath: TILE_ARCHIVE_PATH,
      placesPath
    }
  }
}

const FULL_INDEX = indexOf({placesPath: PLACES_PATH})
const NO_PLACES_INDEX = indexOf({placesPath: ""})
const NO_INDEX = {kind: IndexKind.none}

function schedulesFile({path, bytes}) {
  return {cacheName: OFFLINE_SCHEDULES_CACHE_NAME, path, bytes}
}

const INDEX_BYTES = 1_000
const MANIFEST_BYTES = 2_000
const STOPS_BYTES = 100_000
const CONNECTIONS_BYTES = 30_000_000
const NAMES_BYTES = 400_000
const TRIP_PATH_INDEX_BYTES = 90_000
const TRIP_PATH_SHARD_BYTES = 1_400_000
const TILE_ARCHIVE_BYTES = 3_140_000
const PLACES_BYTES = 1_090_000
const NEXT_DATE_STOPS_BYTES = 120_000
const EXTRACT_BYTES = 34_355_445

const INDEX_FILE = schedulesFile({path: INDEX_PATH, bytes: INDEX_BYTES})
const MANIFEST_FILE = schedulesFile({path: BUNDLE_MANIFEST_PATH, bytes: MANIFEST_BYTES})
const STOPS_FILE = schedulesFile({path: STOPS_PATH, bytes: STOPS_BYTES})
const CONNECTIONS_FILE = schedulesFile({path: CONNECTIONS_PATH, bytes: CONNECTIONS_BYTES})
const NAMES_FILE = schedulesFile({path: NAMES_PATH, bytes: NAMES_BYTES})
const TRIP_PATH_INDEX_FILE = schedulesFile({path: TRIP_PATH_INDEX_PATH, bytes: TRIP_PATH_INDEX_BYTES})
const TRIP_PATH_SHARD_FILE = schedulesFile({path: TRIP_PATH_SHARD_PATH, bytes: TRIP_PATH_SHARD_BYTES})
const TILE_ARCHIVE_FILE = schedulesFile({path: TILE_ARCHIVE_PATH, bytes: TILE_ARCHIVE_BYTES})
const PLACES_FILE = schedulesFile({path: PLACES_PATH, bytes: PLACES_BYTES})
const NEXT_DATE_STOPS_FILE = schedulesFile({path: NEXT_DATE_STOPS_PATH, bytes: NEXT_DATE_STOPS_BYTES})
const EXTRACT_FILE = {cacheName: OFFLINE_BASEMAP_CACHE_NAME, path: EXTRACT_PATH, bytes: EXTRACT_BYTES}

const SCHEDULES_FILES = [INDEX_FILE, MANIFEST_FILE, STOPS_FILE, CONNECTIONS_FILE, NAMES_FILE]
const SCHEDULES_BYTES = INDEX_BYTES + MANIFEST_BYTES + STOPS_BYTES + CONNECTIONS_BYTES + NAMES_BYTES
const TRIP_PATHS_BYTES = TRIP_PATH_INDEX_BYTES + TRIP_PATH_SHARD_BYTES
const FULL_FILES = [...SCHEDULES_FILES, TRIP_PATH_INDEX_FILE, TRIP_PATH_SHARD_FILE, TILE_ARCHIVE_FILE, PLACES_FILE, EXTRACT_FILE]

const breakdownCases = [
  {
    name: "a full store, each file in its part",
    savedIndex: FULL_INDEX,
    files: FULL_FILES,
    expected: {
      parts: [
        {kind: PartKind.schedules, bytes: SCHEDULES_BYTES},
        {kind: PartKind.tripPaths, bytes: TRIP_PATHS_BYTES},
        {kind: PartKind.tiles, bytes: TILE_ARCHIVE_BYTES},
        {kind: PartKind.places, bytes: PLACES_BYTES},
        {kind: PartKind.map, bytes: EXTRACT_BYTES}
      ],
      totalBytes: SCHEDULES_BYTES + TRIP_PATHS_BYTES + TILE_ARCHIVE_BYTES + PLACES_BYTES + EXTRACT_BYTES
    }
  },
  {
    name: "a store with no places file",
    savedIndex: NO_PLACES_INDEX,
    files: [...SCHEDULES_FILES, TRIP_PATH_INDEX_FILE, TRIP_PATH_SHARD_FILE, TILE_ARCHIVE_FILE, EXTRACT_FILE],
    expected: {
      parts: [
        {kind: PartKind.schedules, bytes: SCHEDULES_BYTES},
        {kind: PartKind.tripPaths, bytes: TRIP_PATHS_BYTES},
        {kind: PartKind.tiles, bytes: TILE_ARCHIVE_BYTES},
        {kind: PartKind.map, bytes: EXTRACT_BYTES}
      ],
      totalBytes: SCHEDULES_BYTES + TRIP_PATHS_BYTES + TILE_ARCHIVE_BYTES + EXTRACT_BYTES
    }
  },
  {
    name: "a store with no map extract",
    savedIndex: FULL_INDEX,
    files: [...SCHEDULES_FILES, TRIP_PATH_INDEX_FILE, TRIP_PATH_SHARD_FILE, TILE_ARCHIVE_FILE, PLACES_FILE],
    expected: {
      parts: [
        {kind: PartKind.schedules, bytes: SCHEDULES_BYTES},
        {kind: PartKind.tripPaths, bytes: TRIP_PATHS_BYTES},
        {kind: PartKind.tiles, bytes: TILE_ARCHIVE_BYTES},
        {kind: PartKind.places, bytes: PLACES_BYTES}
      ],
      totalBytes: SCHEDULES_BYTES + TRIP_PATHS_BYTES + TILE_ARCHIVE_BYTES + PLACES_BYTES
    }
  },
  {
    name: "a file the index does not name",
    savedIndex: FULL_INDEX,
    files: [...SCHEDULES_FILES, NEXT_DATE_STOPS_FILE],
    expected: {
      parts: [
        {kind: PartKind.schedules, bytes: SCHEDULES_BYTES},
        {kind: PartKind.other, bytes: NEXT_DATE_STOPS_BYTES}
      ],
      totalBytes: SCHEDULES_BYTES + NEXT_DATE_STOPS_BYTES
    }
  },
  {
    name: "the files of a save in progress, before its index is written",
    savedIndex: NO_INDEX,
    files: [STOPS_FILE, TRIP_PATH_SHARD_FILE, EXTRACT_FILE],
    expected: {
      parts: [
        {kind: PartKind.tripPaths, bytes: TRIP_PATH_SHARD_BYTES},
        {kind: PartKind.map, bytes: EXTRACT_BYTES},
        {kind: PartKind.other, bytes: STOPS_BYTES}
      ],
      totalBytes: STOPS_BYTES + TRIP_PATH_SHARD_BYTES + EXTRACT_BYTES
    }
  },
  {
    name: "the empty store",
    savedIndex: NO_INDEX,
    files: [],
    expected: {parts: [], totalBytes: 0}
  }
]

for (const breakdownCase of breakdownCases) {
  const breakdown = offlineBreakdown({savedIndex: breakdownCase.savedIndex, files: breakdownCase.files})
  deepStrictEqual(breakdown, breakdownCase.expected, `breakdown: ${breakdownCase.name}`)
}

const refusedCases = [
  {name: "a file of another store", file: {cacheName: "gobusgo-other-v1", path: STOPS_PATH, bytes: 1}},
  {name: "a size that is not a whole number", file: schedulesFile({path: STOPS_PATH, bytes: 1.5})},
  {name: "a negative size", file: schedulesFile({path: STOPS_PATH, bytes: -1})}
]

for (const refusedCase of refusedCases) {
  throws(
    () => offlineBreakdown({savedIndex: FULL_INDEX, files: [refusedCase.file]}),
    AssertionError,
    `breakdown refuses ${refusedCase.name}`
  )
}

const sizeCases = [
  {bytes: 0, text: "0 kB"},
  {bytes: 1, text: "1 kB"},
  {bytes: 1_000, text: "1 kB"},
  {bytes: 1_001, text: "2 kB"},
  {bytes: 99_999, text: "100 kB"},
  {bytes: 100_000, text: "0.1 MB"},
  {bytes: 1_090_000, text: "1.1 MB"},
  {bytes: 34_355_445, text: "34.4 MB"}
]

for (const sizeCase of sizeCases) {
  deepStrictEqual(sizeText(sizeCase.bytes), sizeCase.text, `size text of ${sizeCase.bytes} bytes`)
}

const NEGATIVE_BYTES = -1

function negativeSizeText() {
  return sizeText(NEGATIVE_BYTES)
}

throws(negativeSizeText, AssertionError, "size text refuses a negative size")

{
  const breakdown = offlineBreakdown({savedIndex: FULL_INDEX, files: [...FULL_FILES, NEXT_DATE_STOPS_FILE]})
  const rows = breakdownRows(breakdown)
  deepStrictEqual(
    rows,
    [
      {term: "Schedules", definition: "30.5 MB"},
      {term: "Trip paths", definition: "1.5 MB"},
      {term: "Route lines and stops", definition: "3.1 MB"},
      {term: "Places", definition: "1.1 MB"},
      {term: "Map", definition: "34.4 MB"},
      {term: "Other files", definition: "0.1 MB"},
      {term: "Total", definition: "70.7 MB"}
    ],
    "rows: each part and the total"
  )
}

{
  const breakdown = offlineBreakdown({savedIndex: NO_INDEX, files: []})
  deepStrictEqual(breakdownRows(breakdown), [], "rows: none for the empty store")
}

console.log("offline breakdown check passed")
