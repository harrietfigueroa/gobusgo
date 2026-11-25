// Saves the schedules of the region for offline use in the browser's Cache
// API, reads what the store holds, and deletes it.
//
// A save fetches one file at a time at low priority. A date's trip path
// shards are named by its trip path index, so the index is stored and read
// before its shards are. Every file of a bundle is stored before the index
// that names them, so a save that stops part way leaves the
// previous complete bundle in use, and the files the new index no longer
// names are deleted only after it is written. The bundle's own manifest is
// written just before the index, so the service worker's offline answer for
// the manifest names the dates of the bundle that index describes. A file
// the browser evicted is missing from the store and is fetched again by the
// next save.

import {
  BUNDLE_MANIFEST_PATH,
  INDEX_PATH,
  IndexKind,
  NO_PLACES_FILE,
  OFFLINE_SCHEDULES_CACHE_NAME,
  PlanKind,
  ShardPlanKind,
  ShardRefusal,
  TRIP_PATH_INDEX_EXPANDED_BYTES_MAX,
  bundleStatus,
  bundleWithTripPaths,
  keptPlacesFile,
  placesFileOf,
  planBundle,
  savedIndex,
  stalePaths,
  SettingKind,
  statusMessage,
  tripPathShardPlan
} from "#core/offline_bundle.js"
import {AssertionError} from "#core/assert.js"
import {PackedOutcome} from "#core/packed_container.js"
import {expandStream} from "./packed_stream.js"
import {decodeTripPathIndex, indexEntries} from "#core/trip_path_shard.js"

const MANIFEST_PATH = "/api/routing/manifest"
const PLACES_MANIFEST_PATH = "/places/manifest.json"

/** The outcomes of one save. */
const SaveKind = Object.freeze({saved: "saved", nothingToSave: "nothingToSave", stopped: "stopped", failed: "failed"})

/** The kinds of a fetch of the routing manifest: the manifest, or the status that refused it. */
const ManifestKind = Object.freeze({found: "found", refused: "refused"})

const dateFormat = new Intl.DateTimeFormat(undefined, {weekday: "short", month: "short", day: "numeric", timeZone: "UTC"})
const timeFormat = new Intl.DateTimeFormat(undefined, {month: "short", day: "numeric", hour: "numeric", minute: "2-digit"})

function isSupported() {
  return "caches" in window
}

function tileArchivePath() {
  const element = document.getElementById("route-stop-tiles")

  if (element === null) {
    return ""
  }

  const archiveUrl = element.dataset.archiveUrl

  if (archiveUrl === undefined) {
    return ""
  }

  return archiveUrl
}

function pathOf(request) {
  return new URL(request.url).pathname
}

async function indexOf(response) {
  if (response === undefined) {
    return {kind: IndexKind.none}
  }

  const index = await response.json()
  return {kind: IndexKind.found, index}
}

async function readIndex(cache) {
  const response = await cache.match(INDEX_PATH)
  return await indexOf(response)
}

/**
 * A read of the saved index of the offline schedules, which reads the
 * browser's store alone and so answers offline: none where the browser
 * cannot save schedules or holds no saved bundle. A match with the store's
 * name opens no cache, so a read never makes a store a deletion removed.
 */
export async function readSavedIndex() {
  if (!isSupported()) {
    return {kind: IndexKind.none}
  }

  const response = await caches.match(INDEX_PATH, {cacheName: OFFLINE_SCHEDULES_CACHE_NAME})
  return await indexOf(response)
}

async function storedPaths(cache) {
  const requests = await cache.keys()
  return Array.from(requests, pathOf)
}

// Stores `path` unless the store holds it already, and says whether it is
// stored, within the bound of `deadline`. A file whose `byteSize` is known
// is stored only when the answer holds that many bytes.
async function storeFile({cache, path, byteSize, deadline}) {
  const stored = await cache.match(path)

  if (stored !== undefined) {
    return true
  }

  return await deadline.withinBound(() => fetchAndStore({cache, path, byteSize, signal: deadline.signal}))
}

async function fetchAndStore({cache, path, byteSize, signal}) {
  const response = await fetch(path, {signal, priority: "low"})

  if (!response.ok) {
    return false
  }

  if (byteSize !== undefined) {
    const bytes = await response.clone().arrayBuffer()

    if (bytes.byteLength !== byteSize) {
      return false
    }
  }

  await cache.put(path, response)
  return true
}

// The files of `plan`, each with the size a manifest gives it where it
// gives one, which is the trip path indexes' and the places file's.
function filesOf(plan) {
  const sizes = new Map()

  for (const index of plan.tripPathIndexes) {
    sizes.set(index.path, index.byteSize)
  }

  for (const file of plan.sizedFiles) {
    sizes.set(file.path, file.byteSize)
  }

  const files = []

  for (const path of plan.paths) {
    if (sizes.has(path)) {
      files.push({path, byteSize: sizes.get(path)})
    } else {
      files.push({path})
    }
  }

  return files
}

// What the trip path index stored at `path` names: the plan of its shards,
// refused where the index cannot be read.
async function shardPlanOf({cache, path}) {
  const stored = await cache.match(path)

  if (stored === undefined) {
    return {kind: ShardPlanKind.refused, reason: ShardRefusal.unreadable}
  }

  const compressed = await stored.arrayBuffer()
  const expanded = await expandStream(new Uint8Array(compressed), {expandedByteSizeMax: TRIP_PATH_INDEX_EXPANDED_BYTES_MAX})

  if (expanded.kind !== PackedOutcome.expanded) {
    return {kind: ShardPlanKind.refused, reason: ShardRefusal.unreadable}
  }

  const decoded = decodeTripPathIndex(expanded.bytes)

  if (decoded.kind !== PackedOutcome.decoded) {
    return {kind: ShardPlanKind.refused, reason: ShardRefusal.unreadable}
  }

  return tripPathShardPlan(indexEntries(decoded.index))
}

// Stores each of `files`, a `{path, byteSize}`, and says what stopped it, or
// nothing where every one is stored.
async function storeFiles({cache, files, deadline}) {
  for (const {path, byteSize} of files) {
    if (deadline.signal.aborted) {
      return {kind: SaveKind.stopped}
    }

    const isStored = await storeFile({cache, path, byteSize, deadline})

    if (!isStored) {
      return {kind: SaveKind.failed, reason: path + " could not be fetched or differs from the size the manifest gives"}
    }
  }

  return {kind: SaveKind.saved}
}

// The places file the places manifest names, which the bundle saves for
// the Trip tab's search, or none where the server publishes none. A
// manifest that cannot be fetched, as offline, keeps the places file the
// saved bundle holds, so a save offline deletes nothing it cannot fetch
// again.
async function currentPlacesFile({cache, deadline}) {
  try {
    return await deadline.withinBound(() => fetchPlacesFile(deadline.signal))
  } catch (error) {
    // A save the bound or a turn-off stopped ends here, and its caller logs
    // or passes the abort.
    if (deadline.signal.aborted) {
      throw error
    }

    console.warn("Places manifest not fetched; the saved places file is kept", error)
    const saved = await readIndex(cache)
    const isFound = saved.kind === IndexKind.found
    const hasPlacesPath = isFound && typeof saved.index.placesPath === "string"

    if (hasPlacesPath) {
      return keptPlacesFile(saved.index.placesPath)
    }

    return NO_PLACES_FILE
  }
}

async function fetchPlacesFile(signal) {
  const response = await fetch(PLACES_MANIFEST_PATH, {cache: "no-cache", signal, priority: "low"})

  if (!response.ok) {
    return NO_PLACES_FILE
  }

  const placesManifest = await response.json()
  return placesFileOf(placesManifest.file)
}

// The routing manifest, or the status it answered with.
async function fetchManifest(signal) {
  const response = await fetch(MANIFEST_PATH, {cache: "no-cache", signal, priority: "low"})

  if (!response.ok) {
    return {kind: ManifestKind.refused, status: response.status}
  }

  const manifest = await response.json()
  return {kind: ManifestKind.found, manifest}
}

async function save(deadline) {
  const {signal} = deadline
  const manifestRead = await deadline.withinBound(() => fetchManifest(signal))

  if (manifestRead.kind === ManifestKind.refused) {
    return {kind: SaveKind.failed, reason: "the manifest answered " + manifestRead.status}
  }

  const {manifest} = manifestRead
  // Opening the store makes it, so a save stopped meanwhile, as by a
  // turn-off that deleted the store, opens none.
  signal.throwIfAborted()
  const cache = await caches.open(OFFLINE_SCHEDULES_CACHE_NAME)
  const placesFile = await currentPlacesFile({cache, deadline})
  const plan = planBundle({manifest, nowMs: Date.now(), tileArchivePath: tileArchivePath(), placesFile})

  if (plan.kind === PlanKind.nothingToSave) {
    return {kind: SaveKind.nothingToSave}
  }

  const tablesOutcome = await storeFiles({cache, files: filesOf(plan), deadline})

  if (tablesOutcome.kind !== SaveKind.saved) {
    return tablesOutcome
  }

  const shardPlans = []

  for (const {serviceDate, path} of plan.tripPathIndexes) {
    const shardPlan = await shardPlanOf({cache, path})
    shardPlans.push({serviceDate, shardPlan})

    if (shardPlan.kind === ShardPlanKind.refused) {
      console.warn("Trip paths not saved for offline use", serviceDate, shardPlan.reason)
    }
  }

  const bundle = bundleWithTripPaths({plan, shardPlans})
  const shardsOutcome = await storeFiles({cache, files: bundle.shardFiles, deadline})

  if (shardsOutcome.kind !== SaveKind.saved) {
    return shardsOutcome
  }

  const jsonHeaders = {"content-type": "application/json"}
  const manifestText = JSON.stringify(bundle.manifest)
  const manifestCopy = new Response(manifestText, {headers: jsonHeaders})
  await deadline.withinBound(() => cache.put(BUNDLE_MANIFEST_PATH, manifestCopy))
  const index = savedIndex({plan: bundle, savedAtMs: Date.now()})
  const indexText = JSON.stringify(index)
  const indexResponse = new Response(indexText, {headers: jsonHeaders})
  await deadline.withinBound(() => cache.put(INDEX_PATH, indexResponse))
  const present = await storedPaths(cache)
  const keptPaths = [INDEX_PATH, BUNDLE_MANIFEST_PATH, ...bundle.paths]
  const stale = stalePaths({index: {paths: keptPaths}, storedPaths: present})

  for (const path of stale) {
    await cache.delete(path)
  }

  return {kind: SaveKind.saved}
}

function dateText(date) {
  const [year, month, day] = date.serviceDate.split("-")
  const monthIndex = Number(month) - 1
  const startMs = Date.UTC(Number(year), monthIndex, Number(day))
  return dateFormat.format(new Date(startMs))
}

function datesText(dates) {
  return Array.from(dates, dateText).join(" and ")
}

function newestBuild(dates) {
  let newest = ""

  for (const date of dates) {
    if (date.builtAt > newest) {
      newest = date.builtAt
    }
  }

  return timeFormat.format(new Date(newest))
}

/**
 * Saves the region's schedules in the store, each file within the bound of
 * `deadline`, logging a save that fails or passes the bound; a save its
 * controller aborts ends quietly and leaves the previous bundle in use.
 */
export async function saveSchedules(deadline) {
  try {
    const outcome = await save(deadline)

    if (outcome.kind === SaveKind.failed) {
      console.warn("Offline schedules not saved", outcome.reason)
    }
  } catch (error) {
    if (error instanceof AssertionError) {
      throw error
    }

    if (error.name !== "AbortError") {
      console.warn("Offline schedules not saved", error)
    }
  }
}

/** Deletes the store of the saved schedules and every file in it. */
export async function deleteSavedSchedules() {
  await caches.delete(OFFLINE_SCHEDULES_CACHE_NAME)
}

/**
 * The status line of the saved schedules while the setting is on, from
 * `savedIndex`, a read of the saved index, `presentPaths`, the paths the
 * store holds, and `persistence`, the browser's answer to keeping the
 * page's storage: the dates the store holds and whether the browser keeps
 * them. It reads no store.
 */
export function describeSchedules({savedIndex, presentPaths, persistence}) {
  const status = bundleStatus({savedIndex, presentPaths, nowMs: Date.now()})
  let dates = []

  if (Object.hasOwn(status, "dates")) {
    dates = status.dates
  }

  const datesShown = datesText(dates)
  let updatedText = ""

  if (dates.length > 0) {
    updatedText = newestBuild(dates)
  }

  return statusMessage({kind: SettingKind.on, status, persistence, datesText: datesShown, updatedText})
}
