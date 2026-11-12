// What the browser saves for offline use, decided from the routing manifest
// and the time. Everything here is pure: it names the files of a bundle and
// reads a saved index back into what a rider is told about it, and touches
// no storage.
//
// A bundle holds the routing snapshots of the service dates that have not
// ended, at most BUNDLE_DATE_COUNT_MAX of them, each with its names file
// and, where its snapshot has them, its trip path index and the shard of
// every route the index names, and the route and stop tile archive, which
// holds the stops and route shapes a snapshot leaves out. A shard's path is
// known only once its date's index is read, so a bundle is planned in two
// steps: `planBundle` names the files the manifest names, and
// `bundleWithTripPaths` adds the shards. A bundle also holds the places
// file the Trip tab's search reads, where the page names one; the address
// and intersection shards stay out of it. A service date ends at its last
// departure, which can be past midnight. A bundle also holds a manifest of
// its own, which names its dates alone, so that a page reading it offline
// asks for no file the bundle lacks.

import {unreachable} from "./assert.js"

const BUNDLE_DATE_COUNT_MAX = 2
const MEBIBYTE_BYTES = 1024 * 1024
const SECOND_MS = 1000
const NOT_SAVED_HEADER_NAME = "gobusgo-offline"
const NOT_SAVED_HEADER_VALUE = "not-saved"

/** The Cache API store of the bundle, which the service worker reads and never deletes. */
export const OFFLINE_SCHEDULES_CACHE_NAME = "gobusgo-offline-schedules-v1"

/** The path the bundle's index is stored under. */
export const INDEX_PATH = "/offline-schedules/index.json"

/** The path the bundle's own manifest is stored under. */
export const BUNDLE_MANIFEST_PATH = "/offline-schedules/manifest.json"

/** The header, and its value, that mark the service worker's answer for a file no bundle holds and no network gives. */
export const NOT_SAVED_HEADER = Object.freeze({name: NOT_SAVED_HEADER_NAME, value: NOT_SAVED_HEADER_VALUE})

/** Whether `response` is the service worker's answer for a file that is not saved. */
export function isNotSaved(response) {
  return response.headers.get(NOT_SAVED_HEADER_NAME) === NOT_SAVED_HEADER_VALUE
}

/** The most shards a date's trip path index may name; 380 are measured for a weekday of the whole region. */
export const TRIP_PATH_SHARD_COUNT_MAX = 1000

/** The most bytes a date's expanded trip path index may hold; about 100 KB is measured. */
export const TRIP_PATH_INDEX_EXPANDED_BYTES_MAX = MEBIBYTE_BYTES

/** The prefix of every path the routing snapshot files are served under. */
export const ROUTING_PATH_PREFIX = "/routing/"

/** The kinds of the shards a date's trip path index gives: its files, or the reason it is refused. */
export const ShardPlanKind = Object.freeze({shards: "shards", refused: "refused"})

/** Why a date's trip paths are not saved. */
export const ShardRefusal = Object.freeze({tooManyShards: "tooManyShards", badPath: "badPath", unreadable: "unreadable"})

/** The kinds of a bundle plan. */
export const PlanKind = Object.freeze({bundle: "bundle", nothingToSave: "nothingToSave"})

/**
 * The kinds of the places file a bundle saves: a file the places manifest
 * names, the file a saved bundle holds already, kept while no manifest can
 * be read, or none.
 */
export const PlacesFileKind = Object.freeze({file: "file", kept: "kept", none: "none"})

/** The places file of a bundle that keeps `path`, the places file its saved index names, or none for the empty path. */
export function keptPlacesFile(path) {
  if (path.startsWith(PLACES_PATH_PREFIX)) {
    return {kind: PlacesFileKind.kept, path}
  }

  return NO_PLACES_FILE
}

/** The places file of a bundle that saves none. */
export const NO_PLACES_FILE = Object.freeze({kind: PlacesFileKind.none})

/** The prefix of every path the places file is served under. */
export const PLACES_PATH_PREFIX = "/places/"

/**
 * The places file a bundle saves from the places manifest's `file` entry,
 * `{path, byteSize}`, its path as stored, with no leading slash, or as an
 * address: the file at its address under PLACES_PATH_PREFIX, or none for
 * a path outside it or a size that is not a positive whole number.
 */
export function placesFileOf({path, byteSize}) {
  let address = path

  if (!path.startsWith("/")) {
    address = "/" + path
  }

  const isPlaces = address.startsWith(PLACES_PATH_PREFIX)
  const isSized = Number.isSafeInteger(byteSize) && byteSize > 0
  const isSaved = isPlaces && isSized

  if (isSaved) {
    return {kind: PlacesFileKind.file, path: address, byteSize}
  }

  return NO_PLACES_FILE
}

/** The kinds of a read of the saved index. */
export const IndexKind = Object.freeze({found: "found", none: "none"})

/** The kinds of a saved bundle's status. */
export const StatusKind = Object.freeze({saved: "saved", incomplete: "incomplete", notSaved: "notSaved"})

// The instant `entry`'s last connection departs, in milliseconds since the
// Unix epoch.
function lastDepartureMs(entry) {
  let lastDepartureS = 0

  for (const chunk of entry.connectionChunks) {
    lastDepartureS = Math.max(lastDepartureS, chunk.departureSMax)
  }

  return entry.serviceDayStartMs + lastDepartureS * SECOND_MS
}

function snapshotPaths(entry) {
  const {stops, trips, transfers, positions, names} = entry.files
  const paths = [stops.path, trips.path, transfers.path, positions.path, names.path]

  for (const chunk of entry.connectionChunks) {
    paths.push(chunk.path)
  }

  return paths
}

function tripPathIndexOf(entry) {
  const {tripPaths} = entry.files

  if (tripPaths === undefined) {
    return []
  }

  return [{serviceDate: entry.serviceDate, path: tripPaths.path, byteSize: tripPaths.byteSize}]
}

// Service dates are ISO 8601, so their text sorts in date order.
function byServiceDate(left, right) {
  return left.serviceDate.localeCompare(right.serviceDate)
}

function summaryOf(entry) {
  return {
    serviceDate: entry.serviceDate,
    builtAt: entry.builtAt,
    sourceFetchedAtNewest: entry.sourceFetchedAt.newest,
    validUntilMs: lastDepartureMs(entry),
  }
}

/**
 * The bundle to save at `nowMs` from `manifest`, with `tileArchivePath`, the
 * address of the current tile archive, or the empty string where the page
 * names none, and `placesFile`, the places file to save from `placesFileOf`
 * or `keptPlacesFile`, or NO_PLACES_FILE: the summaries of its service dates, every file it
 * holds, `sizedFiles`, the files it holds whose size it knows apart from
 * the trip path indexes, the tile archive's and the places file's
 * addresses, and its own manifest, `manifest` with the chosen snapshots
 * alone.
 */
export function planBundle({manifest, nowMs, tileArchivePath, placesFile}) {
  const current = []

  for (const entry of manifest.snapshots) {
    if (lastDepartureMs(entry) > nowMs) {
      current.push(entry)
    }
  }

  current.sort(byServiceDate)
  const chosen = current.slice(0, BUNDLE_DATE_COUNT_MAX)

  if (chosen.length === 0) {
    return {kind: PlanKind.nothingToSave}
  }

  const paths = []
  const tripPathIndexes = []

  for (const entry of chosen) {
    for (const path of snapshotPaths(entry)) {
      paths.push(path)
    }

    for (const index of tripPathIndexOf(entry)) {
      paths.push(index.path)
      tripPathIndexes.push(index)
    }
  }

  if (tileArchivePath !== "") {
    paths.push(tileArchivePath)
  }

  const sizedFiles = []
  let placesPath = ""

  switch (placesFile.kind) {
    case PlacesFileKind.file:
      paths.push(placesFile.path)
      sizedFiles.push({path: placesFile.path, byteSize: placesFile.byteSize})
      placesPath = placesFile.path
      break
    case PlacesFileKind.kept:
      paths.push(placesFile.path)
      placesPath = placesFile.path
      break
    case PlacesFileKind.none:
      break
    default:
      unreachable(placesFile.kind, "offline bundle: a places file of unknown kind")
  }

  const bundleManifest = {...manifest, snapshots: chosen}
  const dates = Array.from(chosen, summaryOf)
  return {kind: PlanKind.bundle, formatVersion: manifest.formatVersion, dates, paths, tripPathIndexes, sizedFiles, tileArchivePath, placesPath, manifest: bundleManifest}
}

/**
 * The shards `entries`, the entries of a decoded trip path index, name:
 * `{kind: "shards", files}`, each file a `{path, byteSize}` and a path that
 * two routes share named once, or `{kind: "refused", reason}` for an index
 * naming more than TRIP_PATH_SHARD_COUNT_MAX routes or a path outside the
 * routing files.
 */
export function tripPathShardPlan(entries) {
  if (entries.length > TRIP_PATH_SHARD_COUNT_MAX) {
    return {kind: ShardPlanKind.refused, reason: ShardRefusal.tooManyShards}
  }

  const files = []
  const named = new Set()

  for (const entry of entries) {
    const isRouting = entry.path.startsWith(ROUTING_PATH_PREFIX)

    if (!isRouting) {
      return {kind: ShardPlanKind.refused, reason: ShardRefusal.badPath}
    }

    if (!named.has(entry.path)) {
      named.add(entry.path)
      files.push({path: entry.path, byteSize: entry.byteSize})
    }
  }

  return {kind: ShardPlanKind.shards, files}
}

function withoutTripPaths(entry) {
  const files = {}

  for (const [name, file] of Object.entries(entry.files)) {
    if (name !== "tripPaths") {
      files[name] = file
    }
  }

  return {...entry, files}
}

/**
 * `plan` with the shards of its dates: `shardPlans` holds, for each of the
 * plan's `tripPathIndexes`, its `serviceDate` and its `shardPlan`, from
 * `tripPathShardPlan`. A date whose shards are refused is saved without its
 * index and shards, and its entry in the bundle's manifest drops
 * `files.tripPaths`, so the manifest names no file the bundle lacks. The
 * result carries `shardFiles`, every shard to save, and `paths`, every file
 * the bundle holds.
 */
export function bundleWithTripPaths({plan, shardPlans}) {
  const refusedDates = new Set()
  const shardFiles = []
  const named = new Set()

  for (const {serviceDate, shardPlan} of shardPlans) {
    if (shardPlan.kind === ShardPlanKind.refused) {
      refusedDates.add(serviceDate)
      continue
    }

    for (const file of shardPlan.files) {
      if (!named.has(file.path)) {
        named.add(file.path)
        shardFiles.push(file)
      }
    }
  }

  const droppedPaths = new Set()

  for (const index of plan.tripPathIndexes) {
    if (refusedDates.has(index.serviceDate)) {
      droppedPaths.add(index.path)
    }
  }

  const paths = []

  for (const path of plan.paths) {
    if (!droppedPaths.has(path)) {
      paths.push(path)
    }
  }

  for (const file of shardFiles) {
    paths.push(file.path)
  }

  const snapshots = []

  for (const entry of plan.manifest.snapshots) {
    if (refusedDates.has(entry.serviceDate)) {
      snapshots.push(withoutTripPaths(entry))
    } else {
      snapshots.push(entry)
    }
  }

  return {...plan, paths, shardFiles, manifest: {...plan.manifest, snapshots}}
}

/**
 * The index saved with the bundle `plan` at `savedAtMs`: what the bundle
 * holds, and where its manifest, its tile archive, and its places file are
 * stored, an address being the empty string where it holds none.
 */
export function savedIndex({plan, savedAtMs}) {
  return {
    savedAtMs,
    formatVersion: plan.formatVersion,
    dates: plan.dates,
    paths: plan.paths,
    manifestPath: BUNDLE_MANIFEST_PATH,
    tileArchivePath: plan.tileArchivePath,
    placesPath: plan.placesPath
  }
}

/**
 * What a rider is told about a saved bundle: `savedIndex` is a read of the
 * saved index, and `presentPaths` the paths the browser still holds, which
 * it may have evicted. A bundle whose every date has ended is not saved for
 * any time still to come.
 */
export function bundleStatus({savedIndex, presentPaths, nowMs}) {
  if (savedIndex.kind === IndexKind.none) {
    return {kind: StatusKind.notSaved}
  }

  const {index} = savedIndex
  const present = new Set(presentPaths)
  let missingCount = 0

  for (const path of index.paths) {
    if (!present.has(path)) {
      missingCount += 1
    }
  }

  const validDates = []

  for (const date of index.dates) {
    if (date.validUntilMs > nowMs) {
      validDates.push(date)
    }
  }

  if (validDates.length === 0) {
    return {kind: StatusKind.notSaved}
  }

  if (missingCount > 0) {
    return {kind: StatusKind.incomplete, dates: validDates, missingCount}
  }

  return {kind: StatusKind.saved, dates: validDates}
}

/**
 * The kinds of the browser's answer to a request to keep the page's storage:
 * kept until the rider removes it, open to eviction, or no answer from a
 * browser that cannot be asked.
 */
export const PersistenceKind = Object.freeze({granted: "granted", notGranted: "notGranted", unknown: "unknown"})

/** The sentence of the status line that says whether the browser keeps a saved bundle. */
export function persistenceText(kind) {
  switch (kind) {
    case PersistenceKind.granted:
      return "Your browser keeps them until you remove them."
    case PersistenceKind.notGranted:
      return "Your browser can remove them when the device runs short of space."
    case PersistenceKind.unknown:
      return "Your browser does not say whether it keeps them."
    default:
      return unreachable(kind, "persistence kind")
  }
}

/**
 * The kinds of the setting the status line speaks of: off, on, or in a
 * browser that cannot save.
 */
export const SettingKind = Object.freeze({off: "off", on: "on", unsupported: "unsupported"})

const OFF_MESSAGE = Object.freeze({headline: "Schedules not saved", caption: "Turn this on to plan trips offline."})
const UNSUPPORTED_MESSAGE = Object.freeze({headline: "Can't save schedules", caption: "This browser can't save them for offline use."})

function fileCountText(count) {
  if (count === 1) {
    return "1 file"
  }

  return `${count} files`
}

/**
 * The status line's headline and caption for `setting`. A setting that is
 * on carries its bundle's `status`, the browser's `persistence`, and the
 * texts of the status's dates, `datesText`, of their newest build,
 * `updatedText`, and of the stored size, `sizeText`.
 */
export function statusMessage(setting) {
  switch (setting.kind) {
    case SettingKind.off:
      return OFF_MESSAGE
    case SettingKind.unsupported:
      return UNSUPPORTED_MESSAGE
    case SettingKind.on:
      return onMessage(setting)
    default:
      return unreachable(setting.kind, "offline schedules setting kind")
  }
}

function onMessage({status, persistence, datesText, updatedText, sizeText}) {
  const kept = persistenceText(persistence)

  switch (status.kind) {
    case StatusKind.saved:
      return {headline: "Schedules saved for offline use", caption: `For ${datesText}, updated ${updatedText}, ${sizeText}. ${kept}`}
    case StatusKind.incomplete:
      return {
        headline: "Schedules partly saved",
        caption: `Your browser removed ${fileCountText(status.missingCount)} of ${datesText}. They're saved again while you're online. ${kept}`
      }
    case StatusKind.notSaved:
      return {headline: "No schedules saved yet", caption: `They're saved while you're online. ${kept}`}
    default:
      return unreachable(status.kind, "offline schedules status kind")
  }
}

/** The paths a store holds that `index` no longer names, which can go. */
export function stalePaths({index, storedPaths}) {
  const kept = new Set(index.paths)
  const stale = []

  for (const path of storedPaths) {
    if (!kept.has(path)) {
      stale.push(path)
    }
  }

  return stale
}
