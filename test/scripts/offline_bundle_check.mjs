// Checks the offline bundle plan and status as pure functions of a manifest
// and a saved index written out by hand: which service dates and files a
// bundle holds, the order they are fetched in, the keys they are stored
// under, and what a rider is told about a saved bundle. Run it with
// `node test/scripts/offline_bundle_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {IndexKind, PlanKind, StatusKind, bundleStatus, planBundle, staleKeys} from "../../assets/js/offline_bundle.js"

const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const HOUR_SECONDS = 60 * 60
// 2026-11-07 at midnight in Seattle, eight hours after midnight UTC.
const DAY_START_MS = 1794038400000
const SERVICE_DATES = ["2026-11-07", "2026-11-08", "2026-11-09"]
const EARLY_CHUNK_HOUR = 5
const MORNING_CHUNK_HOUR = 9
const LAST_DEPARTURE_HOUR = 26
const CHUNK_HOURS = [EARLY_CHUNK_HOUR, MORNING_CHUNK_HOUR, LAST_DEPARTURE_HOUR]
const TABLE_COUNT = 3
const DAYS_PAST_EVERY_DATE = 4
const SAVE_HOUR = 10
const TILE_ARCHIVE_PATH = "/tiles/route-stops/dt=2026-11-07/route-stops-1.pmtiles"
const SHARED_STOPS_SHA256 = "stops-shared"

function entry(dayIndex) {
  const serviceDate = SERVICE_DATES[dayIndex]

  function file(kind) {
    return {path: "/routing/snapshots/dt=" + serviceDate + "/" + kind + ".bin", sha256: serviceDate + "-" + kind}
  }

  function chunk(hour) {
    return {...file("chunk-" + hour), departureSMax: hour * HOUR_SECONDS}
  }

  return {
    serviceDate,
    serviceDayStartMs: DAY_START_MS + dayIndex * DAY_MS,
    builtAt: "2026-11-07T12:00:00Z",
    sourceFetchedAt: {newest: "2026-11-07T11:00:00Z"},
    files: {stops: {...file("stops"), sha256: SHARED_STOPS_SHA256}, trips: file("trips"), transfers: file("transfers")},
    connectionChunks: Array.from(CHUNK_HOURS, chunk),
  }
}

function serviceDateOf(date) {
  return date.serviceDate
}

function datesOf(plan) {
  return Array.from(plan.dates, serviceDateOf)
}

function pathOf(file) {
  return file.path
}

function keyOf(file) {
  return file.key
}

const [firstDate, secondDate, thirdDate] = [entry(0), entry(1), entry(SERVICE_DATES.length - 1)]
const manifest = {formatVersion: 1, snapshots: [thirdDate, firstDate, secondDate]}
const pastEveryDateMs = DAY_START_MS + DAYS_PAST_EVERY_DATE * DAY_MS
const saveMs = DAY_START_MS + SAVE_HOUR * HOUR_MS
const plan = planBundle({manifest, nowMs: saveMs, tileArchivePath: TILE_ARCHIVE_PATH})
const paths = Array.from(plan.files, pathOf)

// The two earliest dates that have not ended.
deepStrictEqual(plan.kind, PlanKind.bundle)
deepStrictEqual(datesOf(plan), [firstDate.serviceDate, secondDate.serviceDate])

// The tile archive first, then today's tables, then today's chunks from the
// hour of the save, the hours already past last, then tomorrow's in hour order.
deepStrictEqual(paths[0], TILE_ARCHIVE_PATH)
deepStrictEqual(paths.slice(1, 1 + TABLE_COUNT), [firstDate.files.stops.path, firstDate.files.trips.path, firstDate.files.transfers.path])
const [earlyChunk, morningChunk, lateChunk] = firstDate.connectionChunks
deepStrictEqual(paths.slice(1 + TABLE_COUNT, 1 + TABLE_COUNT + CHUNK_HOURS.length), [lateChunk.path, earlyChunk.path, morningChunk.path])

// A file two dates share, by its content, is fetched once.
function isSharedStops(file) {
  return file.key.endsWith(SHARED_STOPS_SHA256)
}

const stopsFiles = plan.files.filter(isSharedStops)
deepStrictEqual(stopsFiles.length, 1)
deepStrictEqual(plan.files.length, 1 + TABLE_COUNT + CHUNK_HOURS.length + (TABLE_COUNT - 1) + CHUNK_HOURS.length)

// A snapshot file is stored under its content's hash, the tile archive under its address.
deepStrictEqual(plan.files[1].key, "/offline-schedules/content/" + SHARED_STOPS_SHA256)
deepStrictEqual(plan.files[0].key, TILE_ARCHIVE_PATH)

// A date ends at its last departure, two hours past the next midnight here.
const afterLastDepartureMs = DAY_START_MS + (LAST_DEPARTURE_HOUR + 1) * HOUR_MS
const afterLastDeparture = planBundle({manifest, nowMs: afterLastDepartureMs, tileArchivePath: ""})
deepStrictEqual(datesOf(afterLastDeparture), [secondDate.serviceDate, thirdDate.serviceDate])
deepStrictEqual(Array.from(afterLastDeparture.files, pathOf).includes(TILE_ARCHIVE_PATH), false)

// Nothing to save once every date has ended.
deepStrictEqual(planBundle({manifest, nowMs: pastEveryDateMs, tileArchivePath: ""}), {kind: PlanKind.nothingToSave})

const savedIndex = {kind: IndexKind.found, index: {dates: plan.dates, files: plan.files}}
const keys = Array.from(plan.files, keyOf)
const evicted = keys.slice(1)

deepStrictEqual(bundleStatus({savedIndex, presentKeys: keys, nowMs: saveMs}).kind, StatusKind.saved)
deepStrictEqual(bundleStatus({savedIndex, presentKeys: evicted, nowMs: saveMs}), {kind: StatusKind.incomplete, dates: plan.dates, missingCount: 1})
deepStrictEqual(bundleStatus({savedIndex: {kind: IndexKind.none}, presentKeys: [], nowMs: saveMs}), {kind: StatusKind.notSaved})
deepStrictEqual(bundleStatus({savedIndex, presentKeys: keys, nowMs: pastEveryDateMs}), {kind: StatusKind.notSaved})

deepStrictEqual(staleKeys({keptKeys: ["/a", "/b"], storedKeys: ["/a", "/old", "/b"]}), ["/old"])
console.log("offline bundle: every case holds")
