// Checks the offline bundle plan and status as pure functions of a manifest
// and a saved index written out by hand: which service dates and files a
// bundle holds, what a rider is told about a saved one, and the sentence
// that says whether the browser keeps it. Run it with
// `node test/scripts/offline_bundle_check.mjs`; it exits non-zero on the
// first case that differs. The bundle's own manifest names only the dates it
// saves.

import {deepStrictEqual} from "node:assert/strict"
import {
  BUNDLE_MANIFEST_PATH,
  INDEX_PATH,
  IndexKind,
  PersistenceKind,
  PlanKind,
  StatusKind,
  bundleStatus,
  persistenceText,
  planBundle,
  savedIndex as indexOf,
  stalePaths
} from "../../assets/js/offline_bundle.js"

const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const HOUR_SECONDS = 60 * 60
// 2026-11-07 at midnight in Seattle, eight hours after midnight UTC.
const DAY_START_MS = 1794038400000
const SERVICE_DATES = ["2026-11-07", "2026-11-08", "2026-11-09"]
const LAST_DEPARTURE_HOUR = 26
const FILES_PER_DATE = 6
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
    files: {stops: file("stops"), trips: file("trips"), transfers: file("transfers"), positions: file("positions")},
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
const morning = planBundle({manifest, nowMs: DAY_START_MS + HOUR_MS, tileArchivePath: TILE_ARCHIVE_PATH})
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
  tileArchivePath: TILE_ARCHIVE_PATH
})
deepStrictEqual(BUNDLE_MANIFEST_PATH === INDEX_PATH, false)

// A date ends at its last departure, two hours past the next midnight here.
const afterLastDepartureMs = DAY_START_MS + (LAST_DEPARTURE_HOUR + 1) * HOUR_MS
const afterLastDeparture = planBundle({manifest, nowMs: afterLastDepartureMs, tileArchivePath: ""})
deepStrictEqual(datesOf(afterLastDeparture), [secondDate.serviceDate, thirdDate.serviceDate])
deepStrictEqual(afterLastDeparture.paths.includes(TILE_ARCHIVE_PATH), false)
deepStrictEqual(afterLastDeparture.tileArchivePath, "")
deepStrictEqual(afterLastDeparture.manifest.snapshots, [secondDate, thirdDate])

// Nothing to save once every date has ended.
deepStrictEqual(planBundle({manifest, nowMs: pastEveryDateMs, tileArchivePath: ""}), {kind: PlanKind.nothingToSave})

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
console.log("offline bundle: every case holds")
