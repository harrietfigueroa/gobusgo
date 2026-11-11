// Checks the offline bundle plan and status as pure functions of a manifest
// and a saved index written out by hand: which service dates and files a
// bundle holds, what a rider is told about a saved one, the sentence that
// says whether the browser keeps it, and the status line's headline and
// caption. Run it with
// `node test/scripts/offline_bundle_check.mjs`; it exits non-zero on the
// first case that differs. The bundle's own manifest names only the dates it
// saves.

import {deepStrictEqual} from "node:assert/strict"
import {
  BUNDLE_MANIFEST_PATH,
  INDEX_PATH,
  IndexKind,
  NO_PLACES_FILE,
  PlacesFileKind,
  PersistenceKind,
  PlanKind,
  SettingKind,
  ShardPlanKind,
  ShardRefusal,
  StatusKind,
  TRIP_PATH_SHARD_COUNT_MAX,
  bundleStatus,
  bundleWithTripPaths,
  keptPlacesFile,
  persistenceText,
  placesFileOf,
  planBundle,
  savedIndex as indexOf,
  stalePaths,
  statusMessage,
  tripPathShardPlan
} from "../../assets/js/offline_bundle.js"

const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const HOUR_SECONDS = 60 * 60
// 2026-11-07 at midnight in Seattle, eight hours after midnight UTC.
const DAY_START_MS = 1794038400000
const SERVICE_DATES = ["2026-11-07", "2026-11-08", "2026-11-09"]
const LAST_DEPARTURE_HOUR = 26
const FILES_PER_DATE = 7
const BUNDLE_DATE_COUNT = 2
const DAYS_PAST_EVERY_DATE = 4
const TILE_ARCHIVE_PATH = "/tiles/route-stops/dt=2026-11-07/route-stops-1.pmtiles"

function entry(dayIndex) {
  const serviceDate = SERVICE_DATES[dayIndex]

  function file(kind) {
    return {path: "/routing/" + serviceDate + "-" + kind + ".bin"}
  }

  return {
    serviceDate,
    serviceDayStartMs: DAY_START_MS + dayIndex * DAY_MS,
    builtAt: "2026-11-07T12:00:00Z",
    sourceFetchedAt: {newest: "2026-11-07T11:00:00Z"},
    files: {stops: file("stops"), trips: file("trips"), transfers: file("transfers"), positions: file("positions"), names: {path: "/routing/" + serviceDate + "-names.json.gz"}},
    connectionChunks: [{...file("chunk-0"), departureSMax: HOUR_SECONDS}, {...file("chunk-1"), departureSMax: LAST_DEPARTURE_HOUR * HOUR_SECONDS}],
  }
}

function serviceDateOf(date) {
  return date.serviceDate
}

function datesOf(plan) {
  return Array.from(plan.dates, serviceDateOf)
}

const [firstDate, secondDate, thirdDate] = [entry(0), entry(1), entry(SERVICE_DATES.length - 1)]
const manifest = {formatVersion: 2, snapshots: [thirdDate, firstDate, secondDate]}
const pastEveryDateMs = DAY_START_MS + DAYS_PAST_EVERY_DATE * DAY_MS

// The two earliest dates that have not ended, with the tile archive last.
const morning = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: NO_PLACES_FILE})
deepStrictEqual(morning.kind, PlanKind.bundle)
deepStrictEqual(datesOf(morning), [SERVICE_DATES[0], SERVICE_DATES[1]])
deepStrictEqual(morning.paths.length, BUNDLE_DATE_COUNT * FILES_PER_DATE + 1)
deepStrictEqual(morning.paths[morning.paths.length - 1], TILE_ARCHIVE_PATH)

// Each date's stop positions are saved with its other tables.
deepStrictEqual(morning.paths.includes(firstDate.files.positions.path), true)
deepStrictEqual(morning.paths.includes(secondDate.files.positions.path), true)

// The bundle's manifest keeps the manifest's other fields and names only the
// dates the bundle saves, so it names no file the bundle lacks.
deepStrictEqual(morning.manifest, {formatVersion: 2, snapshots: [firstDate, secondDate]})
deepStrictEqual(morning.tileArchivePath, TILE_ARCHIVE_PATH)

// The index names the bundle's manifest and its tile archive.
const savedAtMs = DAY_START_MS + HOUR_MS
deepStrictEqual(indexOf({plan: morning, savedAtMs}), {
  savedAtMs,
  formatVersion: 2,
  dates: morning.dates,
  paths: morning.paths,
  manifestPath: BUNDLE_MANIFEST_PATH,
  tileArchivePath: TILE_ARCHIVE_PATH,
  placesPath: ""
})
deepStrictEqual(BUNDLE_MANIFEST_PATH === INDEX_PATH, false)
// Each date's names file is saved with its other files.
deepStrictEqual(morning.paths.includes(firstDate.files.names.path), true)
deepStrictEqual(morning.paths.includes(secondDate.files.names.path), true)

// A date ends at its last departure, two hours past the next midnight here.
const afterLastDepartureMs = DAY_START_MS + (LAST_DEPARTURE_HOUR + 1) * HOUR_MS
const afterLastDeparture = planBundle({manifest, nowMs: afterLastDepartureMs, tileArchivePath: "", placesFile: NO_PLACES_FILE})
deepStrictEqual(datesOf(afterLastDeparture), [secondDate.serviceDate, thirdDate.serviceDate])
deepStrictEqual(afterLastDeparture.paths.includes(TILE_ARCHIVE_PATH), false)
deepStrictEqual(afterLastDeparture.tileArchivePath, "")
deepStrictEqual(afterLastDeparture.manifest.snapshots, [secondDate, thirdDate])

// Nothing to save once every date has ended.
deepStrictEqual(planBundle({manifest, nowMs: pastEveryDateMs, tileArchivePath: "", placesFile: NO_PLACES_FILE}), {kind: PlanKind.nothingToSave})

// The places file, where the page names one, is saved last, at the size its
// manifest gives, and the index names it; with none the index names none.
{
  const placesFile = {kind: PlacesFileKind.file, path: "/places/places-abcd.bin.gz", byteSize: 1092528}
  const withPlaces = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile})
  deepStrictEqual(withPlaces.paths[withPlaces.paths.length - 1], placesFile.path)
  deepStrictEqual(withPlaces.sizedFiles, [{path: placesFile.path, byteSize: placesFile.byteSize}])
  deepStrictEqual(indexOf({plan: withPlaces, savedAtMs}).placesPath, placesFile.path)
  deepStrictEqual(indexOf({plan: morning, savedAtMs}).placesPath, "")
  deepStrictEqual(placesFileOf({path: "places/places-abcd.bin.gz", byteSize: 1092528}), placesFile)
  deepStrictEqual(placesFileOf({path: "/routing/x.bin", byteSize: 1}), NO_PLACES_FILE)
  deepStrictEqual(placesFileOf({path: "/places/x.bin.gz", byteSize: -1}), NO_PLACES_FILE)

  // A save that cannot read the places manifest, as offline, keeps the
  // places file the saved bundle holds, with no size to check it by.
  const kept = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: keptPlacesFile(placesFile.path)})
  deepStrictEqual(kept.paths[kept.paths.length - 1], placesFile.path)
  deepStrictEqual(kept.sizedFiles, [])
  deepStrictEqual(kept.placesPath, placesFile.path)
  deepStrictEqual(keptPlacesFile(""), NO_PLACES_FILE)
}

const savedIndex = {kind: IndexKind.found, index: {dates: morning.dates, paths: morning.paths}}
const nowMs = DAY_START_MS + HOUR_MS
const evicted = morning.paths.slice(1)

deepStrictEqual(bundleStatus({savedIndex, presentPaths: morning.paths, nowMs}).kind, StatusKind.saved)
deepStrictEqual(bundleStatus({savedIndex, presentPaths: evicted, nowMs}), {kind: StatusKind.incomplete, dates: morning.dates, missingCount: 1})
deepStrictEqual(bundleStatus({savedIndex: {kind: IndexKind.none}, presentPaths: [], nowMs}), {kind: StatusKind.notSaved})
deepStrictEqual(bundleStatus({savedIndex, presentPaths: morning.paths, nowMs: pastEveryDateMs}), {kind: StatusKind.notSaved})

deepStrictEqual(stalePaths({index: {paths: ["/a", "/b"]}, storedPaths: ["/a", "/old", "/b"]}), ["/old"])

// Each answer to the request to keep storage gets its own sentence.
deepStrictEqual(persistenceText(PersistenceKind.granted), "Your browser keeps them until you remove them.")
deepStrictEqual(persistenceText(PersistenceKind.notGranted), "Your browser can remove them when the device runs short of space.")
deepStrictEqual(persistenceText(PersistenceKind.unknown), "Your browser does not say whether it keeps them.")

// The status line says the setting's state in its headline, and the dates,
// the size, and whether the browser keeps them in its caption.
const onSetting = {
  kind: SettingKind.on,
  persistence: PersistenceKind.granted,
  datesText: "Sat, Nov 7 and Sun, Nov 8",
  updatedText: "Nov 7, 4:12 AM",
  sizeText: "3.4 MB"
}
const statusMessageCases = [
  {
    name: "off",
    setting: {kind: SettingKind.off},
    expected: {headline: "Schedules not saved", caption: "Turn this on to plan trips offline."}
  },
  {
    name: "a browser that cannot save",
    setting: {kind: SettingKind.unsupported},
    expected: {headline: "Can't save schedules", caption: "This browser can't save them for offline use."}
  },
  {
    name: "saved",
    setting: {...onSetting, status: {kind: StatusKind.saved, dates: morning.dates}},
    expected: {
      headline: "Schedules saved for offline use",
      caption: "For Sat, Nov 7 and Sun, Nov 8, updated Nov 7, 4:12 AM, 3.4 MB. Your browser keeps them until you remove them."
    }
  },
  {
    name: "one file evicted",
    setting: {...onSetting, status: {kind: StatusKind.incomplete, dates: morning.dates, missingCount: 1}},
    expected: {
      headline: "Schedules partly saved",
      caption: "Your browser removed 1 file of Sat, Nov 7 and Sun, Nov 8. They're saved again while you're online. Your browser keeps them until you remove them."
    }
  },
  {
    name: "three files evicted",
    setting: {...onSetting, persistence: PersistenceKind.notGranted, status: {kind: StatusKind.incomplete, dates: morning.dates, missingCount: 3}},
    expected: {
      headline: "Schedules partly saved",
      caption: "Your browser removed 3 files of Sat, Nov 7 and Sun, Nov 8. They're saved again while you're online. Your browser can remove them when the device runs short of space."
    }
  },
  {
    name: "on with nothing saved yet",
    setting: {...onSetting, persistence: PersistenceKind.unknown, status: {kind: StatusKind.notSaved}},
    expected: {headline: "No schedules saved yet", caption: "They're saved while you're online. Your browser does not say whether it keeps them."}
  }
]

for (const {name, setting, expected} of statusMessageCases) {
  deepStrictEqual(statusMessage(setting), expected, `the status message: ${name}`)
}

// A date whose snapshot has trip paths saves its index with its other files,
// and the shards its index names after them.
function withTripPaths(source) {
  const tripPaths = {path: "/routing/" + source.serviceDate + "-trip-paths-index.bin.gz", byteSize: 300, sha256: "ab"}
  return {...source, files: {...source.files, tripPaths}}
}

function shardEntry(serviceDate, number) {
  return {path: "/routing/" + serviceDate + "-trip-paths-" + number + ".bin.gz", byteSize: SHARD_BYTE_SIZE + number, sha256: "cd"}
}

function shardEntryAt(serviceDate) {
  return function entryAt(_unused, number) {
    return shardEntry(serviceDate, number)
  }
}

function shardPlanOf(serviceDate, shardCount) {
  const entries = Array.from({length: shardCount}, shardEntryAt(serviceDate))
  return {serviceDate, shardPlan: tripPathShardPlan(entries)}
}

const pathsFirst = withTripPaths(firstDate)
const pathsSecond = withTripPaths(secondDate)
const pathsManifest = {formatVersion: 2, snapshots: [pathsFirst, pathsSecond]}
const pathsPlan = planBundle({manifest: pathsManifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: NO_PLACES_FILE})
const SHARDS_PER_DATE = 3
const SHARD_BYTE_SIZE = 1000
const SHARED_PLAN_FILE_COUNT = 2
const shardPlans = [shardPlanOf(pathsFirst.serviceDate, SHARDS_PER_DATE), shardPlanOf(pathsSecond.serviceDate, SHARDS_PER_DATE)]
const pathsBundle = bundleWithTripPaths({plan: pathsPlan, shardPlans})

deepStrictEqual(
  pathsPlan.tripPathIndexes,
  [
    {serviceDate: pathsFirst.serviceDate, path: pathsFirst.files.tripPaths.path, byteSize: 300},
    {serviceDate: pathsSecond.serviceDate, path: pathsSecond.files.tripPaths.path, byteSize: 300}
  ],
  "a plan names each date's trip path index"
)
deepStrictEqual(pathsPlan.paths.length, morning.paths.length + BUNDLE_DATE_COUNT, "the plan holds each index")
deepStrictEqual(pathsPlan.manifest.snapshots, [pathsFirst, pathsSecond], "the bundle's manifest keeps files.tripPaths")
deepStrictEqual(pathsBundle.shardFiles.length, BUNDLE_DATE_COUNT * SHARDS_PER_DATE, "every shard of every date is to save")
deepStrictEqual(pathsBundle.paths.length, pathsPlan.paths.length + BUNDLE_DATE_COUNT * SHARDS_PER_DATE, "the bundle holds the shards")

for (const {shardPlan} of shardPlans) {
  for (const file of shardPlan.files) {
    deepStrictEqual(pathsBundle.paths.includes(file.path), true, "the bundle holds " + file.path)
  }
}

deepStrictEqual(pathsBundle.manifest.snapshots, [pathsFirst, pathsSecond], "the manifest still names both indexes")

// The saved index names the shards, so a shard the browser evicted is a
// missing file of an incomplete bundle, and a complete one counts none.
const pathsSaved = {kind: IndexKind.found, index: indexOf({plan: pathsBundle, savedAtMs})}
deepStrictEqual(pathsSaved.index.paths.includes(shardEntry(pathsFirst.serviceDate, 0).path), true)
deepStrictEqual(bundleStatus({savedIndex: pathsSaved, presentPaths: pathsBundle.paths, nowMs}).kind, StatusKind.saved)
const evictedShardPath = shardEntry(pathsSecond.serviceDate, 1).path
function isNotEvicted(path) {
  return path !== evictedShardPath
}

const shardEvicted = pathsBundle.paths.filter(isNotEvicted)
deepStrictEqual(bundleStatus({savedIndex: pathsSaved, presentPaths: shardEvicted, nowMs}), {
  kind: StatusKind.incomplete,
  dates: pathsPlan.dates,
  missingCount: 1
})

// A store keeps the shards the index names and drops those of a date no
// longer saved.
const droppedDate = shardEntry(thirdDate.serviceDate, 0).path
const storedWithOld = [...pathsBundle.paths, droppedDate]
deepStrictEqual(stalePaths({index: pathsSaved.index, storedPaths: storedWithOld}), [droppedDate])

// A shard two routes share is named once.
const sharedPlan = tripPathShardPlan([shardEntry("d", 0), {...shardEntry("d", 0), sha256: "cd"}, shardEntry("d", 1)])
deepStrictEqual(sharedPlan.files.length, SHARED_PLAN_FILE_COUNT)

// A date with no files.tripPaths, a killed path build, saves without them
// and is complete.
const noPathsPlan = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: NO_PLACES_FILE})
deepStrictEqual(noPathsPlan.tripPathIndexes, [])
const noPathsBundle = bundleWithTripPaths({plan: noPathsPlan, shardPlans: []})
deepStrictEqual(noPathsBundle.paths, noPathsPlan.paths)
deepStrictEqual(noPathsBundle.shardFiles, [])
const noPathsSaved = {kind: IndexKind.found, index: indexOf({plan: noPathsBundle, savedAtMs})}
deepStrictEqual(bundleStatus({savedIndex: noPathsSaved, presentPaths: noPathsBundle.paths, nowMs}).kind, StatusKind.saved)

// An index naming more than the bound refuses its date: the bundle holds the
// date's other files, and its manifest entry drops files.tripPaths.
const overBound = shardPlanOf(pathsFirst.serviceDate, TRIP_PATH_SHARD_COUNT_MAX + 1)
deepStrictEqual(overBound.shardPlan, {kind: ShardPlanKind.refused, reason: ShardRefusal.tooManyShards})
deepStrictEqual(shardPlanOf(pathsFirst.serviceDate, TRIP_PATH_SHARD_COUNT_MAX).shardPlan.kind, ShardPlanKind.shards)
const refusedBundle = bundleWithTripPaths({plan: pathsPlan, shardPlans: [overBound, shardPlans[1]]})
deepStrictEqual(refusedBundle.paths.includes(pathsFirst.files.tripPaths.path), false)
deepStrictEqual(refusedBundle.paths.includes(pathsSecond.files.tripPaths.path), true)
deepStrictEqual(refusedBundle.manifest.snapshots, [firstDate, pathsSecond])
deepStrictEqual(refusedBundle.shardFiles.length, SHARDS_PER_DATE)

// A shard path outside the routing files is refused.
deepStrictEqual(tripPathShardPlan([{path: "/other/shard.bin.gz", byteSize: 1, sha256: "cd"}]), {
  kind: ShardPlanKind.refused,
  reason: ShardRefusal.badPath
})

console.log("offline bundle: every case holds")
