// What the browser saves for offline use, decided from the routing manifest
// and the time. Everything here is pure: it names the files of a bundle and
// reads a saved index back into what a rider is told about it, and touches
// no storage.
//
// A bundle holds the routing snapshots of the service dates that have not
// ended, at most BUNDLE_DATE_COUNT_MAX of them, and the route and stop tile
// archive, which holds the stops and route shapes a snapshot leaves out. A
// service date ends at its last departure, which can be past midnight.

const BUNDLE_DATE_COUNT_MAX = 2
const SECOND_MS = 1000

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
  const paths = [entry.files.stops.path, entry.files.trips.path, entry.files.transfers.path, entry.files.positions.path]

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
 * names none: the summaries of its service dates and every file it holds.
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

  return {kind: PlanKind.bundle, formatVersion: manifest.formatVersion, dates: Array.from(chosen, summaryOf), paths}
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
