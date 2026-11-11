// Saves the schedules of the region for offline use in the browser's Cache
// API, and keeps the rider's setting for it through the stored settings
// module, on unless the rider turns it off.
//
// A save never competes with the page: it starts once the page has loaded
// and the browser is idle, fetches one file at a time at low priority, and
// runs again while the page stays open. A date's trip path shards are
// named by its trip path index, so the index is stored and read before its
// shards are. Every file of a bundle is stored
// before the index that names them, so a save that stops part way leaves the
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
  SettingKind,
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
  statusMessage,
  tripPathShardPlan
} from "./offline_bundle"
import {writeMessage} from "./message"
import {PackedOutcome, expandStream} from "./packed_container"
import {requestPersistence} from "./storage_persistence"
import {storedSettings} from "./stored_settings"
import {decodeTripPathIndex, indexEntries} from "./trip_path_shard"

const MANIFEST_PATH = "/api/routing/manifest"
const PLACES_MANIFEST_PATH = "/places/manifest.json"
const REFRESH_INTERVAL_MS = 30 * 60 * 1000
const IDLE_TIMEOUT_MS = 10 * 1000
const MEBIBYTE_BYTES = 1024 * 1024

/** The outcomes of one save. */
const SaveKind = Object.freeze({saved: "saved", nothingToSave: "nothingToSave", stopped: "stopped", failed: "failed"})

const dateFormat = new Intl.DateTimeFormat(undefined, {weekday: "short", month: "short", day: "numeric", timeZone: "UTC"})
const timeFormat = new Intl.DateTimeFormat(undefined, {month: "short", day: "numeric", hour: "numeric", minute: "2-digit"})

function isSupported() {
  return "caches" in window
}

function isEnabled() {
  return storedSettings.readOfflineSchedulesEnabled()
}

function storeEnabled(enabled) {
  storedSettings.writeOfflineSchedulesEnabled(enabled)
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

async function readIndex(cache) {
  const response = await cache.match(INDEX_PATH)

  if (response === undefined) {
    return {kind: IndexKind.none}
  }

  const index = await response.json()
  return {kind: IndexKind.found, index}
}

/**
 * A read of the saved index of the offline schedules, which reads the
 * browser's store alone and so answers offline: none where the browser
 * cannot save schedules or holds no saved bundle.
 */
export async function readSavedIndex() {
  if (!isSupported()) {
    return {kind: IndexKind.none}
  }

  const hasStore = await caches.has(OFFLINE_SCHEDULES_CACHE_NAME)

  if (!hasStore) {
    return {kind: IndexKind.none}
  }

  const cache = await caches.open(OFFLINE_SCHEDULES_CACHE_NAME)
  return await readIndex(cache)
}

async function storedPaths(cache) {
  const requests = await cache.keys()
  return Array.from(requests, pathOf)
}

// Stores `path` unless the store holds it already, and says whether it is
// stored. A file whose `byteSize` is known is stored only when the answer
// holds that many bytes.
async function storeFile({cache, path, byteSize, signal}) {
  const stored = await cache.match(path)

  if (stored !== undefined) {
    return true
  }

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
async function storeFiles({cache, files, signal}) {
  for (const {path, byteSize} of files) {
    if (signal.aborted) {
      return {kind: SaveKind.stopped}
    }

    const isStored = await storeFile({cache, path, byteSize, signal})

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
async function currentPlacesFile({cache, signal}) {
  try {
    const response = await fetch(PLACES_MANIFEST_PATH, {cache: "no-cache", signal, priority: "low"})

    if (!response.ok) {
      return NO_PLACES_FILE
    }

    const placesManifest = await response.json()
    return placesFileOf(placesManifest.file)
  } catch (error) {
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

async function save(signal) {
  const manifestResponse = await fetch(MANIFEST_PATH, {cache: "no-cache", signal, priority: "low"})

  if (!manifestResponse.ok) {
    return {kind: SaveKind.failed, reason: "the manifest answered " + manifestResponse.status}
  }

  const manifest = await manifestResponse.json()
  const cache = await caches.open(OFFLINE_SCHEDULES_CACHE_NAME)
  const placesFile = await currentPlacesFile({cache, signal})
  const plan = planBundle({manifest, nowMs: Date.now(), tileArchivePath: tileArchivePath(), placesFile})

  if (plan.kind === PlanKind.nothingToSave) {
    return {kind: SaveKind.nothingToSave}
  }

  const tablesOutcome = await storeFiles({cache, files: filesOf(plan), signal})

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
  const shardsOutcome = await storeFiles({cache, files: bundle.shardFiles, signal})

  if (shardsOutcome.kind !== SaveKind.saved) {
    return shardsOutcome
  }

  const jsonHeaders = {"content-type": "application/json"}
  const manifestText = JSON.stringify(bundle.manifest)
  const manifestCopy = new Response(manifestText, {headers: jsonHeaders})
  await cache.put(BUNDLE_MANIFEST_PATH, manifestCopy)
  const index = savedIndex({plan: bundle, savedAtMs: Date.now()})
  const indexText = JSON.stringify(index)
  const indexResponse = new Response(indexText, {headers: jsonHeaders})
  await cache.put(INDEX_PATH, indexResponse)
  const present = await storedPaths(cache)
  const keptPaths = [INDEX_PATH, BUNDLE_MANIFEST_PATH, ...bundle.paths]
  const stale = stalePaths({index: {paths: keptPaths}, storedPaths: present})

  for (const path of stale) {
    await cache.delete(path)
  }

  return {kind: SaveKind.saved}
}

async function storedBytes(cache) {
  const requests = await cache.keys()
  let bytes = 0

  for (const request of requests) {
    const response = await cache.match(request)
    const blob = await response.blob()
    bytes += blob.size
  }

  return bytes
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

async function describe(persistence) {
  const cache = await caches.open(OFFLINE_SCHEDULES_CACHE_NAME)
  const savedIndex = await readIndex(cache)
  const present = await storedPaths(cache)
  const status = bundleStatus({savedIndex, presentPaths: present, nowMs: Date.now()})
  const bytes = await storedBytes(cache)
  let dates = []

  if (Object.hasOwn(status, "dates")) {
    dates = status.dates
  }

  const sizeText = (bytes / MEBIBYTE_BYTES).toFixed(1) + " MB"
  const datesShown = datesText(dates)
  let updatedText = ""

  if (dates.length > 0) {
    updatedText = newestBuild(dates)
  }

  return statusMessage({kind: SettingKind.on, status, persistence, datesText: datesShown, updatedText, sizeText})
}

// Keeps the region's schedules saved while the setting is on, and shows
// what is saved. The checkbox is the setting, and the status element says
// what the store holds.
export const OfflineSchedules = {
  mounted() {
    this.checkbox = this.el.querySelector("input[type=checkbox]")
    this.status = this.el.querySelector("[data-offline-status]")
    this.controller = null
    this.timer = null
    this.persistence = null

    if (!isSupported()) {
      this.checkbox.checked = false
      this.checkbox.disabled = true
      writeMessage({element: this.status, message: statusMessage({kind: SettingKind.unsupported})})
      return
    }

    this.checkbox.checked = isEnabled()
    this.onChange = () => this.changed()
    this.onOnline = () => this.start()
    this.checkbox.addEventListener("change", this.onChange)
    window.addEventListener("online", this.onOnline)
    this.timer = window.setInterval(this.onOnline, REFRESH_INTERVAL_MS)
    this.show()
    this.whenIdle()
  },

  destroyed() {
    window.clearInterval(this.timer)
    window.removeEventListener("online", this.onOnline)
    this.stop()
  },

  // Starts the first save once the page has loaded and the browser is idle.
  whenIdle() {
    const idle = () => {
      if (typeof window.requestIdleCallback === "function") {
        window.requestIdleCallback(() => this.start(), {timeout: IDLE_TIMEOUT_MS})
      } else {
        window.setTimeout(() => this.start(), 0)
      }
    }

    if (document.readyState === "complete") {
      idle()
    } else {
      window.addEventListener("load", idle, {once: true})
    }
  },

  changed() {
    const enabled = this.checkbox.checked
    storeEnabled(enabled)

    if (enabled) {
      this.start()
    } else {
      this.clear()
    }
  },

  async start() {
    const isRunning = this.controller !== null
    const isOff = !isEnabled()

    const isBusyOrOff = isRunning || isOff

    if (isBusyOrOff) {
      return
    }

    this.controller = new AbortController()

    try {
      const outcome = await save(this.controller.signal)

      if (outcome.kind === SaveKind.failed) {
        console.warn("Offline schedules not saved", outcome.reason)
      }
    } catch (error) {
      if (error.name !== "AbortError") {
        console.warn("Offline schedules not saved", error)
      }
    } finally {
      this.controller = null
    }

    await this.show()
  },

  stop() {
    if (this.controller !== null) {
      this.controller.abort()
    }
  },

  async clear() {
    this.stop()
    await caches.delete(OFFLINE_SCHEDULES_CACHE_NAME)
    writeMessage({element: this.status, message: statusMessage({kind: SettingKind.off})})
  },

  async show() {
    if (!isEnabled()) {
      writeMessage({element: this.status, message: statusMessage({kind: SettingKind.off})})
      return
    }

    try {
      // Asked once per page, while the setting is on.
      if (this.persistence === null) {
        this.persistence = requestPersistence()
      }

      const persistence = await this.persistence
      const message = await describe(persistence)
      writeMessage({element: this.status, message})
    } catch (error) {
      console.warn("Offline schedules status not read", error)
    }
  },
}
