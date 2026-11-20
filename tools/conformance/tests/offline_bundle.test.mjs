// Checks the offline bundle plan and status as pure functions of a manifest
// and a saved index written out by hand: which service dates and files a
// bundle holds, what a rider is told about a saved one, the sentence that
// says whether the browser keeps it, and the status line's headline and
// caption. The bundle's own manifest names only the dates it saves. Later
// steps build on the plans of earlier ones, so each implementation builds
// them once and every test reads them.

import {beforeAll, describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

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
const SHARDS_PER_DATE = 3
const SHARD_BYTE_SIZE = 1000
const SHARED_PLAN_FILE_COUNT = 2
const PLACES_BYTE_SIZE = 1092528
const INDEX_BYTE_SIZE = 300
const SAVED_AT_MS = DAY_START_MS + HOUR_MS
const NOW_MS = DAY_START_MS + HOUR_MS
const PAST_EVERY_DATE_MS = DAY_START_MS + DAYS_PAST_EVERY_DATE * DAY_MS

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
    connectionChunks: [{...file("chunk-0"), departureSMax: HOUR_SECONDS}, {...file("chunk-1"), departureSMax: LAST_DEPARTURE_HOUR * HOUR_SECONDS}]
  }
}

function serviceDateOf(date) {
  return date.serviceDate
}

function datesOf(plan) {
  return Array.from(plan.dates, serviceDateOf)
}

// A date whose snapshot has trip paths saves its index with its other files,
// and the shards its index names after them.
function withTripPaths(source) {
  const tripPaths = {path: "/routing/" + source.serviceDate + "-trip-paths-index.bin.gz", byteSize: INDEX_BYTE_SIZE, sha256: "ab"}
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

const firstDate = entry(0)
const secondDate = entry(1)
const thirdDate = entry(SERVICE_DATES.length - 1)
const manifest = {formatVersion: 2, snapshots: [thirdDate, firstDate, secondDate]}
const pathsFirst = withTripPaths(firstDate)
const pathsSecond = withTripPaths(secondDate)
const pathsManifest = {formatVersion: 2, snapshots: [pathsFirst, pathsSecond]}

describe.each(IMPLEMENTATIONS)("offline bundle ($name)", ({offlineBundle}) => {
  const {
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
    savedIndex: indexOf,
    stalePaths,
    statusMessage,
    tripPathShardPlan
  } = offlineBundle

  function shardPlanOf(serviceDate, shardCount) {
    const entries = Array.from({length: shardCount}, shardEntryAt(serviceDate))
    return {serviceDate, shardPlan: tripPathShardPlan(entries)}
  }

  // The plans every later step builds on.
  const states = {}

  beforeAll(() => {
    states.morning = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: NO_PLACES_FILE})
    states.pathsPlan = planBundle({manifest: pathsManifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: NO_PLACES_FILE})
    const firstShards = shardPlanOf(pathsFirst.serviceDate, SHARDS_PER_DATE)
    const secondShards = shardPlanOf(pathsSecond.serviceDate, SHARDS_PER_DATE)
    states.shardPlans = [firstShards, secondShards]
    states.pathsBundle = bundleWithTripPaths({plan: states.pathsPlan, shardPlans: states.shardPlans})
    const pathsIndex = indexOf({plan: states.pathsBundle, savedAtMs: SAVED_AT_MS})
    states.pathsSaved = {kind: IndexKind.found, index: pathsIndex}
  })

  // The two earliest dates that have not ended, with the tile archive last.
  test("the two earliest dates that have not ended, with the tile archive last", () => {
    const {morning} = states
    expect(morning.kind).toBe(PlanKind.bundle)
    expect(datesOf(morning)).toStrictEqual([SERVICE_DATES[0], SERVICE_DATES[1]])
    expect(morning.paths.length).toBe(BUNDLE_DATE_COUNT * FILES_PER_DATE + 1)
    expect(morning.paths[morning.paths.length - 1]).toBe(TILE_ARCHIVE_PATH)
  })

  // Each date's stop positions are saved with its other tables.
  test("each date's stop positions are saved", () => {
    const {morning} = states
    expect(morning.paths.includes(firstDate.files.positions.path)).toBe(true)
    expect(morning.paths.includes(secondDate.files.positions.path)).toBe(true)
  })

  // The bundle's manifest keeps the manifest's other fields and names only the
  // dates the bundle saves, so it names no file the bundle lacks.
  test("the bundle's manifest names only the dates it saves", () => {
    const {morning} = states
    expect(morning.manifest).toStrictEqual({formatVersion: 2, snapshots: [firstDate, secondDate]})
    expect(morning.tileArchivePath).toBe(TILE_ARCHIVE_PATH)
  })

  // The index names the bundle's manifest and its tile archive.
  test("the index names the bundle's manifest and its tile archive", () => {
    const {morning} = states
    expect(indexOf({plan: morning, savedAtMs: SAVED_AT_MS})).toStrictEqual({
      savedAtMs: SAVED_AT_MS,
      formatVersion: 2,
      dates: morning.dates,
      paths: morning.paths,
      manifestPath: BUNDLE_MANIFEST_PATH,
      tileArchivePath: TILE_ARCHIVE_PATH,
      placesPath: ""
    })
    expect(BUNDLE_MANIFEST_PATH === INDEX_PATH).toBe(false)
  })

  // Each date's names file is saved with its other files.
  test("each date's names file is saved", () => {
    const {morning} = states
    expect(morning.paths.includes(firstDate.files.names.path)).toBe(true)
    expect(morning.paths.includes(secondDate.files.names.path)).toBe(true)
  })

  // A date ends at its last departure, two hours past the next midnight here.
  test("a date ends at its last departure", () => {
    const afterLastDepartureMs = DAY_START_MS + (LAST_DEPARTURE_HOUR + 1) * HOUR_MS
    const afterLastDeparture = planBundle({manifest, nowMs: afterLastDepartureMs, tileArchivePath: "", placesFile: NO_PLACES_FILE})
    expect(datesOf(afterLastDeparture)).toStrictEqual([secondDate.serviceDate, thirdDate.serviceDate])
    expect(afterLastDeparture.paths.includes(TILE_ARCHIVE_PATH)).toBe(false)
    expect(afterLastDeparture.tileArchivePath).toBe("")
    expect(afterLastDeparture.manifest.snapshots).toStrictEqual([secondDate, thirdDate])
  })

  // Nothing to save once every date has ended.
  test("nothing to save once every date has ended", () => {
    const plan = planBundle({manifest, nowMs: PAST_EVERY_DATE_MS, tileArchivePath: "", placesFile: NO_PLACES_FILE})
    expect(plan).toStrictEqual({kind: PlanKind.nothingToSave})
  })

  // The places file, where the page names one, is saved last, at the size its
  // manifest gives, and the index names it; with none the index names none.
  test("the places file is saved last at its manifest's size", () => {
    const placesFile = {kind: PlacesFileKind.file, path: "/places/places-abcd.bin.gz", byteSize: PLACES_BYTE_SIZE}
    const withPlaces = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile})
    expect(withPlaces.paths[withPlaces.paths.length - 1]).toBe(placesFile.path)
    expect(withPlaces.sizedFiles).toStrictEqual([{path: placesFile.path, byteSize: placesFile.byteSize}])
    const withPlacesIndex = indexOf({plan: withPlaces, savedAtMs: SAVED_AT_MS})
    expect(withPlacesIndex.placesPath).toBe(placesFile.path)
    const morningIndex = indexOf({plan: states.morning, savedAtMs: SAVED_AT_MS})
    expect(morningIndex.placesPath).toBe("")
    expect(placesFileOf({path: "places/places-abcd.bin.gz", byteSize: PLACES_BYTE_SIZE})).toStrictEqual(placesFile)
    expect(placesFileOf({path: "/routing/x.bin", byteSize: 1})).toStrictEqual(NO_PLACES_FILE)
    expect(placesFileOf({path: "/places/x.bin.gz", byteSize: -1})).toStrictEqual(NO_PLACES_FILE)
  })

  // A save that cannot read the places manifest, as offline, keeps the
  // places file the saved bundle holds, with no size to check it by.
  test("a save that cannot read the places manifest keeps the saved places file", () => {
    const placesPath = "/places/places-abcd.bin.gz"
    const keptFile = keptPlacesFile(placesPath)
    const kept = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: keptFile})
    expect(kept.paths[kept.paths.length - 1]).toBe(placesPath)
    expect(kept.sizedFiles).toStrictEqual([])
    expect(kept.placesPath).toBe(placesPath)
    expect(keptPlacesFile("")).toStrictEqual(NO_PLACES_FILE)
  })

  test("a bundle's status: saved, incomplete, and not saved", () => {
    const {morning} = states
    const savedIndex = {kind: IndexKind.found, index: {dates: morning.dates, paths: morning.paths}}
    const evicted = morning.paths.slice(1)
    const savedStatus = bundleStatus({savedIndex, presentPaths: morning.paths, nowMs: NOW_MS})
    expect(savedStatus.kind).toBe(StatusKind.saved)
    expect(bundleStatus({savedIndex, presentPaths: evicted, nowMs: NOW_MS})).toStrictEqual({kind: StatusKind.incomplete, dates: morning.dates, missingCount: 1})
    expect(bundleStatus({savedIndex: {kind: IndexKind.none}, presentPaths: [], nowMs: NOW_MS})).toStrictEqual({kind: StatusKind.notSaved})
    expect(bundleStatus({savedIndex, presentPaths: morning.paths, nowMs: PAST_EVERY_DATE_MS})).toStrictEqual({kind: StatusKind.notSaved})
  })

  test("the stale paths are the stored ones the index lacks", () => {
    expect(stalePaths({index: {paths: ["/a", "/b"]}, storedPaths: ["/a", "/old", "/b"]})).toStrictEqual(["/old"])
  })

  // Each answer to the request to keep storage gets its own sentence.
  const persistenceCases = [
    {name: "granted", persistence: () => PersistenceKind.granted, expected: "Your browser keeps them until you remove them."},
    {name: "not granted", persistence: () => PersistenceKind.notGranted, expected: "Your browser can remove them when the device runs short of space."},
    {name: "unknown", persistence: () => PersistenceKind.unknown, expected: "Your browser does not say whether it keeps them."}
  ]

  test.each(persistenceCases)("the persistence sentence: $name", ({persistence, expected}) => {
    const kind = persistence()
    expect(persistenceText(kind)).toBe(expected)
  })

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
      setting: () => ({kind: SettingKind.off}),
      expected: {headline: "Schedules not saved", caption: "Turn this on to plan trips offline."}
    },
    {
      name: "a browser that cannot save",
      setting: () => ({kind: SettingKind.unsupported}),
      expected: {headline: "Can't save schedules", caption: "This browser can't save them for offline use."}
    },
    {
      name: "saved",
      setting: () => ({...onSetting, status: {kind: StatusKind.saved, dates: states.morning.dates}}),
      expected: {
        headline: "Schedules saved for offline use",
        caption: "For Sat, Nov 7 and Sun, Nov 8, updated Nov 7, 4:12 AM, 3.4 MB. Your browser keeps them until you remove them."
      }
    },
    {
      name: "one file evicted",
      setting: () => ({...onSetting, status: {kind: StatusKind.incomplete, dates: states.morning.dates, missingCount: 1}}),
      expected: {
        headline: "Schedules partly saved",
        caption: "Your browser removed 1 file of Sat, Nov 7 and Sun, Nov 8. They're saved again while you're online. Your browser keeps them until you remove them."
      }
    },
    {
      name: "three files evicted",
      setting: () => ({...onSetting, persistence: PersistenceKind.notGranted, status: {kind: StatusKind.incomplete, dates: states.morning.dates, missingCount: 3}}),
      expected: {
        headline: "Schedules partly saved",
        caption: "Your browser removed 3 files of Sat, Nov 7 and Sun, Nov 8. They're saved again while you're online. Your browser can remove them when the device runs short of space."
      }
    },
    {
      name: "on with nothing saved yet",
      setting: () => ({...onSetting, persistence: PersistenceKind.unknown, status: {kind: StatusKind.notSaved}}),
      expected: {headline: "No schedules saved yet", caption: "They're saved while you're online. Your browser does not say whether it keeps them."}
    }
  ]

  test.each(statusMessageCases)("the status message: $name", ({setting, expected}) => {
    const shown = setting()
    expect(statusMessage(shown)).toStrictEqual(expected)
  })

  test("a plan names each date's trip path index and holds it", () => {
    const {morning, pathsPlan} = states
    expect(pathsPlan.tripPathIndexes).toStrictEqual([
      {serviceDate: pathsFirst.serviceDate, path: pathsFirst.files.tripPaths.path, byteSize: INDEX_BYTE_SIZE},
      {serviceDate: pathsSecond.serviceDate, path: pathsSecond.files.tripPaths.path, byteSize: INDEX_BYTE_SIZE}
    ])
    expect(pathsPlan.paths.length).toBe(morning.paths.length + BUNDLE_DATE_COUNT)
    expect(pathsPlan.manifest.snapshots).toStrictEqual([pathsFirst, pathsSecond])
  })

  test("every shard of every date is to save", () => {
    const {pathsBundle, pathsPlan, shardPlans} = states
    expect(pathsBundle.shardFiles.length).toBe(BUNDLE_DATE_COUNT * SHARDS_PER_DATE)
    expect(pathsBundle.paths.length).toBe(pathsPlan.paths.length + BUNDLE_DATE_COUNT * SHARDS_PER_DATE)

    for (const {shardPlan} of shardPlans) {
      for (const file of shardPlan.files) {
        expect(pathsBundle.paths.includes(file.path)).toBe(true)
      }
    }

    expect(pathsBundle.manifest.snapshots).toStrictEqual([pathsFirst, pathsSecond])
  })

  // The saved index names the shards, so a shard the browser evicted is a
  // missing file of an incomplete bundle, and a complete one counts none.
  test("an evicted shard is a missing file of an incomplete bundle", () => {
    const {pathsBundle, pathsPlan, pathsSaved} = states
    const firstShardPath = shardEntry(pathsFirst.serviceDate, 0).path
    expect(pathsSaved.index.paths.includes(firstShardPath)).toBe(true)
    const completeStatus = bundleStatus({savedIndex: pathsSaved, presentPaths: pathsBundle.paths, nowMs: NOW_MS})
    expect(completeStatus.kind).toBe(StatusKind.saved)
    const evictedShardPath = shardEntry(pathsSecond.serviceDate, 1).path

    function isNotEvicted(path) {
      return path !== evictedShardPath
    }

    const shardEvicted = pathsBundle.paths.filter(isNotEvicted)
    expect(bundleStatus({savedIndex: pathsSaved, presentPaths: shardEvicted, nowMs: NOW_MS})).toStrictEqual({
      kind: StatusKind.incomplete,
      dates: pathsPlan.dates,
      missingCount: 1
    })
  })

  // A store keeps the shards the index names and drops those of a date no
  // longer saved.
  test("a store drops the shards of a date no longer saved", () => {
    const {pathsBundle, pathsSaved} = states
    const droppedDate = shardEntry(thirdDate.serviceDate, 0).path
    const storedWithOld = [...pathsBundle.paths, droppedDate]
    expect(stalePaths({index: pathsSaved.index, storedPaths: storedWithOld})).toStrictEqual([droppedDate])
  })

  // A shard two routes share is named once.
  test("a shard two routes share is named once", () => {
    const sharedPlan = tripPathShardPlan([shardEntry("d", 0), {...shardEntry("d", 0), sha256: "cd"}, shardEntry("d", 1)])
    expect(sharedPlan.files.length).toBe(SHARED_PLAN_FILE_COUNT)
  })

  // A date with no files.tripPaths, a killed path build, saves without them
  // and is complete.
  test("a date with no trip paths saves without them and is complete", () => {
    const noPathsPlan = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH, placesFile: NO_PLACES_FILE})
    expect(noPathsPlan.tripPathIndexes).toStrictEqual([])
    const noPathsBundle = bundleWithTripPaths({plan: noPathsPlan, shardPlans: []})
    expect(noPathsBundle.paths).toStrictEqual(noPathsPlan.paths)
    expect(noPathsBundle.shardFiles).toStrictEqual([])
    const noPathsIndex = indexOf({plan: noPathsBundle, savedAtMs: SAVED_AT_MS})
    const noPathsSaved = {kind: IndexKind.found, index: noPathsIndex}
    const noPathsStatus = bundleStatus({savedIndex: noPathsSaved, presentPaths: noPathsBundle.paths, nowMs: NOW_MS})
    expect(noPathsStatus.kind).toBe(StatusKind.saved)
  })

  // An index naming more than the bound refuses its date: the bundle holds the
  // date's other files, and its manifest entry drops files.tripPaths.
  test("an index naming more shards than the bound refuses its date", () => {
    const {pathsPlan, shardPlans} = states
    const overBound = shardPlanOf(pathsFirst.serviceDate, TRIP_PATH_SHARD_COUNT_MAX + 1)
    expect(overBound.shardPlan).toStrictEqual({kind: ShardPlanKind.refused, reason: ShardRefusal.tooManyShards})
    const atBound = shardPlanOf(pathsFirst.serviceDate, TRIP_PATH_SHARD_COUNT_MAX)
    expect(atBound.shardPlan.kind).toBe(ShardPlanKind.shards)
    const refusedBundle = bundleWithTripPaths({plan: pathsPlan, shardPlans: [overBound, shardPlans[1]]})
    expect(refusedBundle.paths.includes(pathsFirst.files.tripPaths.path)).toBe(false)
    expect(refusedBundle.paths.includes(pathsSecond.files.tripPaths.path)).toBe(true)
    expect(refusedBundle.manifest.snapshots).toStrictEqual([firstDate, pathsSecond])
    expect(refusedBundle.shardFiles.length).toBe(SHARDS_PER_DATE)
  })

  // A shard path outside the routing files is refused.
  test("a shard path outside the routing files is refused", () => {
    expect(tripPathShardPlan([{path: "/other/shard.bin.gz", byteSize: 1, sha256: "cd"}])).toStrictEqual({
      kind: ShardPlanKind.refused,
      reason: ShardRefusal.badPath
    })
  })
})
