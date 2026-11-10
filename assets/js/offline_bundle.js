// What the browser saves for offline use, decided from the routing manifest
// and the time. Everything here is pure: it names the files of a bundle and
// reads a saved index back into what a rider is told about it, and touches
// no storage.
//
// A bundle holds the routing snapshots of the service dates that have not
// ended, at most BUNDLE_DATE_COUNT_MAX of them, each with its names file,
// and the route and stop tile archive, which holds the stops and route
// shapes a snapshot leaves out. A service date ends at its last departure,
// which can be past midnight. A bundle also holds a manifest of its own,
// which names its dates alone, so that a page reading it offline asks for
// no file the bundle lacks.

import {unreachable} from "./assert.js"

const BUNDLE_DATE_COUNT_MAX = 2
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

/** The kinds of a bundle plan. */
export const PlanKind = Object.freeze({bundle: "bundle", nothingToSave: "nothingToSave"})

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
 * names none: the summaries of its service dates, every file it holds, the
 * tile archive's address, and its own manifest, `manifest` with the chosen
 * snapshots alone.
 */
export function planBundle({manifest, nowMs, tileArchivePath}) {
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

  for (const entry of chosen) {
    for (const path of snapshotPaths(entry)) {
      paths.push(path)
    }
  }

  if (tileArchivePath !== "") {
    paths.push(tileArchivePath)
  }

  const bundleManifest = {...manifest, snapshots: chosen}
  const dates = Array.from(chosen, summaryOf)
  return {kind: PlanKind.bundle, formatVersion: manifest.formatVersion, dates, paths, tileArchivePath, manifest: bundleManifest}
}

/**
 * The index saved with the bundle `plan` at `savedAtMs`: what the bundle
 * holds, and where its manifest and its tile archive are stored, the
 * archive's address being the empty string where it holds none.
 */
export function savedIndex({plan, savedAtMs}) {
  return {
    savedAtMs,
    formatVersion: plan.formatVersion,
    dates: plan.dates,
    paths: plan.paths,
    manifestPath: BUNDLE_MANIFEST_PATH,
    tileArchivePath: plan.tileArchivePath
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
