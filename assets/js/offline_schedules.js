// Saves the schedules of the region for offline use in the browser's Cache
// API, and keeps the rider's setting for it in local storage, on unless the
// rider turns it off.
//
// A save never competes with the page: it starts once the page has loaded
// and the browser is idle, fetches one file at a time at low priority, and
// runs again while the page stays open. Every file of a bundle is stored
// before the index that names them, so a save that stops part way leaves the
// previous complete bundle in use, and the files the new index no longer
// names are deleted only after it is written. A file the browser evicted is
// missing from the store and is fetched again by the next save.

import {IndexKind, PersistenceKind, PlanKind, StatusKind, bundleStatus, persistenceText, planBundle, stalePaths} from "./offline_bundle"

const CACHE_NAME = "gobusgo-offline-schedules-v1"
const INDEX_PATH = "/offline-schedules/index.json"
const MANIFEST_PATH = "/api/routing/manifest"
const SETTING_KEY = "gobusgo:offline-schedules"
const SETTING_OFF = "off"
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

// Whether the rider keeps the setting on. Storage that throws, as in a
// private window, reads as the default, on.
function isEnabled() {
  try {
    return window.localStorage.getItem(SETTING_KEY) !== SETTING_OFF
  } catch (error) {
    console.warn("Offline schedules setting not readable", error)
    return true
  }
}

function storeEnabled(enabled) {
  try {
    if (enabled) {
      window.localStorage.removeItem(SETTING_KEY)
    } else {
      window.localStorage.setItem(SETTING_KEY, SETTING_OFF)
    }
  } catch (error) {
    console.warn("Offline schedules setting not stored", error)
  }
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

async function storedPaths(cache) {
  const requests = await cache.keys()
  return Array.from(requests, pathOf)
}

// Stores `path` unless the store holds it already, and says whether it is stored.
async function storeFile({cache, path, signal}) {
  const stored = await cache.match(path)

  if (stored !== undefined) {
    return true
  }

  const response = await fetch(path, {signal, priority: "low"})

  if (!response.ok) {
    return false
  }

  await cache.put(path, response)
  return true
}

async function save(signal) {
  const manifestResponse = await fetch(MANIFEST_PATH, {cache: "no-cache", signal, priority: "low"})

  if (!manifestResponse.ok) {
    return {kind: SaveKind.failed, reason: "the manifest answered " + manifestResponse.status}
  }

  const manifest = await manifestResponse.json()
  const plan = planBundle({manifest, nowMs: Date.now(), tileArchivePath: tileArchivePath()})

  if (plan.kind === PlanKind.nothingToSave) {
    return {kind: SaveKind.nothingToSave}
  }

  const cache = await caches.open(CACHE_NAME)

  for (const path of plan.paths) {
    if (signal.aborted) {
      return {kind: SaveKind.stopped}
    }

    const isStored = await storeFile({cache, path, signal})

    if (!isStored) {
      return {kind: SaveKind.failed, reason: path + " could not be fetched"}
    }
  }

  const index = {savedAtMs: Date.now(), formatVersion: plan.formatVersion, dates: plan.dates, paths: plan.paths}
  const indexText = JSON.stringify(index)
  const indexResponse = new Response(indexText, {headers: {"content-type": "application/json"}})
  await cache.put(INDEX_PATH, indexResponse)
  const present = await storedPaths(cache)
  const keptPaths = [INDEX_PATH, ...plan.paths]
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

// The status line for a saved bundle's `status`, of `bytes` stored.
function statusText({status, bytes}) {
  const size = (bytes / MEBIBYTE_BYTES).toFixed(1) + " MB"

  switch (status.kind) {
    case StatusKind.saved:
      return "Saved for offline use: schedules for " + datesText(status.dates) + ", updated " + newestBuild(status.dates) + ", " + size + "."
    case StatusKind.incomplete:
      return "Partly saved: schedules for " + datesText(status.dates) + ", with " + status.missingCount + " files the browser removed. They are saved again while you are online."
    case StatusKind.notSaved:
      return "No schedules are saved for offline use yet. They are saved while you are online."
    default:
      return "Offline schedules: " + String(status.kind)
  }
}

// Asks the browser to keep the page's storage, so the saved schedules are
// not evicted, and returns its answer. WebKit grants it by heuristics that
// favor a page opened as a Home Screen web app.
// https://webkit.org/?p=14403 — checked 2026-11-08
async function requestPersistence() {
  const storage = navigator.storage
  const isAskable = storage !== undefined && typeof storage.persist === "function"

  if (!isAskable) {
    return PersistenceKind.unknown
  }

  try {
    const persisted = await storage.persisted()

    if (persisted) {
      return PersistenceKind.granted
    }

    const granted = await storage.persist()

    if (granted) {
      return PersistenceKind.granted
    }

    return PersistenceKind.notGranted
  } catch (error) {
    console.warn("Persistent storage not requested", error)
    return PersistenceKind.unknown
  }
}

async function describe(persistence) {
  const cache = await caches.open(CACHE_NAME)
  const savedIndex = await readIndex(cache)
  const present = await storedPaths(cache)
  const status = bundleStatus({savedIndex, presentPaths: present, nowMs: Date.now()})
  const bytes = await storedBytes(cache)
  return statusText({status, bytes}) + " " + persistenceText(persistence)
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
      this.status.textContent = "This browser cannot save schedules for offline use."
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
    await caches.delete(CACHE_NAME)
    this.status.textContent = "Schedules are not saved for offline use."
  },

  async show() {
    if (!isEnabled()) {
      this.status.textContent = "Schedules are not saved for offline use."
      return
    }

    try {
      // Asked once per page, while the setting is on.
      if (this.persistence === null) {
        this.persistence = requestPersistence()
      }

      const persistence = await this.persistence
      this.status.textContent = await describe(persistence)
    } catch (error) {
      console.warn("Offline schedules status not read", error)
    }
  },
}
