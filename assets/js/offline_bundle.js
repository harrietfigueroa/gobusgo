// What the browser saves for offline use, decided from the routing manifest
// and the time. Everything here is pure: it names the files of a bundle in
// the order to fetch them and reads a saved index back into what a rider is
// told about it, and touches no storage.
//
// A bundle holds the routing snapshots of the service dates that have not
// ended, at most BUNDLE_DATE_COUNT_MAX of them, and the route and stop tile
// archive, which holds the stops and route shapes a snapshot leaves out. A
// service date ends at its last departure, which can be past midnight.
//
// A snapshot file is stored under the SHA-256 the manifest gives it rather
// than under its address, which changes when the server writes the same
// content again on a later day, so a save fetches only content it lacks. The
// tile archive's name is its build, so its address is its key.
//
// The order makes a bundle usable soonest: the tile archive first, then each
// date's tables, then its connection chunks from the hour of the save
// onward, and the hours already past last.

const BUNDLE_DATE_COUNT_MAX = 2
const SECOND_MS = 1000
const CONTENT_KEY_PREFIX = "/offline-schedules/content/"

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

function contentFile(file) {
  return {key: CONTENT_KEY_PREFIX + file.sha256, path: file.path}
}

// The chunks of `entry` in the order to fetch them at `nowMs`: those still
// to depart in hour order, then those already past.
function orderedChunks({entry, nowMs}) {
  const nowS = (nowMs - entry.serviceDayStartMs) / SECOND_MS
  const coming = []
  const past = []

  for (const chunk of entry.connectionChunks) {
    if (chunk.departureSMax >= nowS) {
      coming.push(chunk)
    } else {
      past.push(chunk)
    }
  }

  return [...coming, ...past]
}

function snapshotFiles({entry, nowMs}) {
  const files = [contentFile(entry.files.stops), contentFile(entry.files.trips), contentFile(entry.files.transfers)]

  for (const chunk of orderedChunks({entry, nowMs})) {
    files.push(contentFile(chunk))
  }

  return files
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
 * names none: the summaries of its service dates and its files in the order
 * to fetch them, each with the key it is stored under and the address it is
 * fetched from. A file two dates share is named once.
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

  const files = []
  const keys = new Set()

  if (tileArchivePath !== "") {
    files.push({key: tileArchivePath, path: tileArchivePath})
    keys.add(tileArchivePath)
  }

  for (const entry of chosen) {
    for (const file of snapshotFiles({entry, nowMs})) {
      if (!keys.has(file.key)) {
        files.push(file)
        keys.add(file.key)
      }
    }
  }

  return {kind: PlanKind.bundle, formatVersion: manifest.formatVersion, dates: Array.from(chosen, summaryOf), files}
}

/**
 * What a rider is told about a saved bundle: `savedIndex` is a read of the
 * saved index, and `presentKeys` the keys the browser still holds, which it
 * may have evicted. A bundle whose every date has ended is not saved for any
 * time still to come.
 */
export function bundleStatus({savedIndex, presentKeys, nowMs}) {
  if (savedIndex.kind === IndexKind.none) {
    return {kind: StatusKind.notSaved}
  }

  const {index} = savedIndex
  const present = new Set(presentKeys)
  let missingCount = 0

  for (const file of index.files) {
    if (!present.has(file.key)) {
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

/** The keys a store holds that none of `keptKeys` names, which can go. */
export function staleKeys({keptKeys, storedKeys}) {
  const kept = new Set(keptKeys)
  const stale = []

  for (const key of storedKeys) {
    if (!kept.has(key)) {
      stale.push(key)
    }
  }

  return stale
}
