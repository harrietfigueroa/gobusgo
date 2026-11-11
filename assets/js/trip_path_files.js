// How the vehicle page reads trip paths from the files of the routing
// snapshot's manifest, as pure functions of the files' state, the page's path
// cache, the trips it wants, and the time: the manifest entry of a trip's
// service date, that entry's index of route shards, and the shard of the
// trip's route. A trip these files cannot serve, a date with no entry, a
// route with no shard, a trip its shard lacks, or a file that failed
// repeatedly, has no path: it is held back until its retry time and then
// decided again, since the manifest or a file can arrive meanwhile.
// Nothing here fetches, waits, or keeps time: the page runs the fetches this
// asks for and hands each outcome back.

import {assertCondition, unreachable} from "./assert.js"
import {PackedOutcome} from "./packed_container.js"
import {tripPathKey} from "./trip_path.js"
import {TripPathLookup, decodeTripPathIndex, decodeTripPathShard, tripPathFromShard} from "./trip_path_shard.js"

/** How long a trip with no path is left out before it is decided again. */
export const MISSING_PATH_RETRY_MS = 2 * 60 * 1000

/** The most trips with no path held at once, the earliest leaving first. */
export const MISSING_TRIP_COUNT_MAX = 300

/** How long a file fetch is waited for before it counts as failed. */
export const FILE_FETCH_TIMEOUT_MS = 20 * 1000

/** How long after a failed file fetch the page fetches it again. */
export const FILE_RETRY_MS = 15 * 1000

/** How soon the manifest is asked for again after an ask, for a date it lacks or after a failure. */
export const MANIFEST_RETRY_MS = 60 * 1000

/** The most index and shard fetches in flight at once: a downtown view needs 17 to 38 shards. */
export const SHARD_FETCH_PARALLEL_MAX = 4

/** The failed fetches of one file after which its trips have no path. */
export const SHARD_FAILURE_COUNT_MAX = 3

/** The most shard entries held, decoded or not, the least recently used leaving first. */
export const SHARD_COUNT_MAX = 64

/** The most service dates whose index the page holds: the manifest's own count. */
export const INDEX_COUNT_MAX = 3

/** The most bytes a shard may expand to: the largest of 380 held 10.3 KB gzipped. */
export const SHARD_EXPANDED_BYTES_MAX = 1024 * 1024

/** The most bytes an index may expand to: the index of 380 routes held 32.3 KB gzipped. */
export const INDEX_EXPANDED_BYTES_MAX = 1024 * 1024

// The fewest points and stops a path the prediction takes holds.
const PATH_PART_COUNT_MIN = 2

/** The files a plan asks for. */
export const FileKind = Object.freeze({manifest: "manifest", index: "index", shard: "shard"})

/** Why a file did not arrive. */
export const FileFailure = Object.freeze({
  decode: "decode",
  fetch: "fetch",
  sizeMismatch: "sizeMismatch",
  timeout: "timeout"
})

/** What a fetch of the manifest handed back. */
export const ManifestOutcomeKind = Object.freeze({changed: "changed", failed: "failed", unchanged: "unchanged"})

/** What a fetch of an index or a shard handed back. */
export const FileOutcomeKind = Object.freeze({expanded: "expanded", failed: "failed"})

const EntryState = Object.freeze({failed: "failed", pending: "pending", ready: "ready"})
const Verdict = Object.freeze({found: "found", missing: "missing", waiting: "waiting"})
const DatesKind = Object.freeze({dates: "dates", refused: "refused"})
const NO_STARTS = Object.freeze([])

function assertTime(nowMs) {
  assertCondition(Number.isFinite(nowMs), `a time ${nowMs} is a number`)
}

/** The state of a page that has fetched no file. */
export function emptyTripPathFiles() {
  return Object.freeze({
    manifest: null,
    manifestAskedAtMs: null,
    manifestPending: false,
    indexes: new Map(),
    shards: new Map(),
    missingUntilMs: new Map()
  })
}

function shardKeyOf({serviceDateMs, routeId}) {
  return serviceDateMs + "/" + routeId
}

function isTripPathsEntry(entry) {
  const isObject = typeof entry === "object" && entry !== null

  if (!isObject) {
    return false
  }

  const isNamed = typeof entry.path === "string" && typeof entry.sha256 === "string"
  const isSized = Number.isSafeInteger(entry.byteSize)
  return isNamed && isSized
}

function isDated(snapshot) {
  const isObject = typeof snapshot === "object" && snapshot !== null

  if (!isObject) {
    return false
  }

  return Number.isSafeInteger(snapshot.serviceDayStartMs)
}

function newestFirst(left, right) {
  return right.serviceDayStartMs - left.serviceDayStartMs
}

// The newest INDEX_COUNT_MAX dates of a manifest, each with the entry of its
// index or none, or a refusal for a body that is not a manifest.
function datesOf(manifest) {
  const isObject = typeof manifest === "object" && manifest !== null

  if (!isObject) {
    return {kind: DatesKind.refused}
  }

  if (!Array.isArray(manifest.snapshots)) {
    return {kind: DatesKind.refused}
  }

  const snapshots = []

  for (const snapshot of manifest.snapshots) {
    if (isDated(snapshot)) {
      snapshots.push(snapshot)
    }
  }

  // The list is copied first: `sort` orders in place and the manifest is not this function's to change.
  const newest = Array.from(snapshots).sort(newestFirst)
  const dates = new Map()

  for (const snapshot of newest.slice(0, INDEX_COUNT_MAX)) {
    const entry = snapshot.files?.tripPaths

    if (isTripPathsEntry(entry)) {
      dates.set(snapshot.serviceDayStartMs, Object.freeze({...entry}))
    } else {
      dates.set(snapshot.serviceDayStartMs, null)
    }
  }

  return {kind: DatesKind.dates, dates}
}

function isSameIndex({entry, index}) {
  const isAbsent = entry === undefined || entry === null

  if (isAbsent) {
    return false
  }

  return entry.sha256 === index.sha256
}

// The held indexes and shards that the dates `dates` still name with the
// same index file.
function keptFor({files, dates}) {
  const indexes = new Map()
  const shards = new Map()

  for (const [serviceDateMs, index] of files.indexes) {
    if (isSameIndex({entry: dates.get(serviceDateMs), index})) {
      indexes.set(serviceDateMs, index)
    }
  }

  for (const [key, shard] of files.shards) {
    if (indexes.has(shard.serviceDateMs)) {
      shards.set(key, shard)
    }
  }

  return {indexes, shards}
}

/**
 * The state after a fetch of the manifest settled with `outcome`: `{kind:
 * "changed", manifest, etag}` for a new body, `{kind: "unchanged"}` for a
 * 304, or `{kind: "failed"}`. A body that is not a manifest counts as a
 * failure. The indexes and shards of a date whose index file changed or left
 * the manifest are dropped.
 */
export function manifestFetched({files, outcome, nowMs}) {
  assertTime(nowMs)
  const settled = {...files, manifestAskedAtMs: nowMs, manifestPending: false}

  switch (outcome.kind) {
    case ManifestOutcomeKind.unchanged:
    case ManifestOutcomeKind.failed:
      return Object.freeze(settled)
    case ManifestOutcomeKind.changed: {
      const parsed = datesOf(outcome.manifest)

      if (parsed.kind === DatesKind.refused) {
        return Object.freeze(settled)
      }

      const {indexes, shards} = keptFor({files, dates: parsed.dates})
      const manifest = Object.freeze({dates: parsed.dates, etag: outcome.etag})
      return Object.freeze({...settled, manifest, indexes, shards})
    }
    default:
      return unreachable(outcome.kind, "manifest outcome")
  }
}

/** Whether a fetched file is of the size the manifest or the index names. */
export function hasExpectedSize({fetch, byteLength}) {
  return fetch.byteSize === byteLength
}

function failureOf({previous, nowMs}) {
  return Object.freeze({
    kind: EntryState.failed,
    failureCount: previous.failureCount + 1,
    retryAtMs: nowMs + FILE_RETRY_MS
  })
}

// The shards, oldest first, with the least recently used leaving past
// SHARD_COUNT_MAX; a fetch in flight stays.
function boundedShards(shards) {
  const next = new Map(shards)

  for (const [key, shard] of next) {
    if (next.size <= SHARD_COUNT_MAX) {
      break
    }

    if (shard.kind !== EntryState.pending) {
      next.delete(key)
    }
  }

  return next
}

function isAwaited(entry) {
  if (entry === undefined) {
    return false
  }

  return entry.kind === EntryState.pending
}

function decodedIndexOf(outcome) {
  if (outcome.kind === FileOutcomeKind.failed) {
    return {kind: PackedOutcome.refused}
  }

  return decodeTripPathIndex(outcome.bytes)
}

function decodedShardOf(outcome) {
  if (outcome.kind === FileOutcomeKind.failed) {
    return {kind: PackedOutcome.refused}
  }

  return decodeTripPathShard(outcome.bytes)
}

function indexFetched({files, fetch, outcome, nowMs}) {
  const previous = files.indexes.get(fetch.serviceDateMs)

  if (!isAwaited(previous)) {
    return files
  }

  const indexes = new Map(files.indexes)
  const decoded = decodedIndexOf(outcome)

  if (decoded.kind === PackedOutcome.refused) {
    indexes.set(fetch.serviceDateMs, Object.freeze({...failureOf({previous, nowMs}), sha256: fetch.sha256}))
  } else {
    indexes.set(fetch.serviceDateMs, Object.freeze({kind: EntryState.ready, index: decoded.index, sha256: fetch.sha256}))
  }

  return Object.freeze({...files, indexes})
}

function shardFetched({files, fetch, outcome, nowMs}) {
  const key = shardKeyOf(fetch)
  const previous = files.shards.get(key)

  if (!isAwaited(previous)) {
    return files
  }

  const shards = new Map(files.shards)
  shards.delete(key)
  const decoded = decodedShardOf(outcome)
  const identity = {serviceDateMs: fetch.serviceDateMs}

  if (decoded.kind === PackedOutcome.refused) {
    shards.set(key, Object.freeze({...failureOf({previous, nowMs}), ...identity}))
  } else {
    shards.set(key, Object.freeze({kind: EntryState.ready, shard: decoded.shard, ...identity}))
  }

  return Object.freeze({...files, shards: boundedShards(shards)})
}

/**
 * The state after the fetch `fetch`, as a plan named it, settled with
 * `outcome`: `{kind: "expanded", bytes}`, the expanded file, or `{kind:
 * "failed", reason}`. A file that does not decode counts as failed; a fetch
 * the state no longer waits for changes nothing.
 */
export function fileFetched({files, fetch, outcome, nowMs}) {
  assertTime(nowMs)

  switch (fetch.kind) {
    case FileKind.index:
      return indexFetched({files, fetch, outcome, nowMs})
    case FileKind.shard:
      return shardFetched({files, fetch, outcome, nowMs})
    default:
      return unreachable(fetch.kind, "file fetch")
  }
}

function isPreparable(path) {
  const hasPoints = path.points.length >= PATH_PART_COUNT_MIN
  const hasStops = path.stops.length >= PATH_PART_COUNT_MIN
  return hasPoints && hasStops
}

function boundedMissing({missingUntilMs, keys, untilMs}) {
  const next = new Map(missingUntilMs)

  for (const key of keys) {
    next.delete(key)
    next.set(key, untilMs)
  }

  for (const key of next.keys()) {
    if (next.size <= MISSING_TRIP_COUNT_MAX) {
      break
    }
    next.delete(key)
  }

  return next
}

function pendingOf({fetch, previous}) {
  let failureCount = 0

  if (previous !== undefined) {
    failureCount = previous.failureCount
  }

  return Object.freeze({kind: EntryState.pending, failureCount, sha256: fetch.sha256, serviceDateMs: fetch.serviceDateMs})
}

// The verdict for an index or shard slot `previous`, absent or not ready,
// and the fetch it starts where a slot is free.
function slotVerdict({previous, fetch, inFlight, nowMs}) {
  const isSlotFree = inFlight < SHARD_FETCH_PARALLEL_MAX
  let starts = NO_STARTS

  if (isSlotFree) {
    starts = Object.freeze([fetch])
  }

  if (previous === undefined) {
    return {kind: Verdict.waiting, starts}
  }

  if (previous.kind === EntryState.pending) {
    return {kind: Verdict.waiting, starts: NO_STARTS}
  }

  assertCondition(previous.kind === EntryState.failed, "an entry is pending, failed, or ready")

  if (previous.failureCount >= SHARD_FAILURE_COUNT_MAX) {
    return {kind: Verdict.missing, starts: NO_STARTS}
  }

  if (nowMs >= previous.retryAtMs) {
    return {kind: Verdict.waiting, starts}
  }

  return {kind: Verdict.waiting, starts: NO_STARTS}
}

// The manifest entry of a trip's date, or missing, and whether the
// manifest is asked for.
function manifestVerdict({files, trip, nowMs}) {
  const hasAsked = files.manifestAskedAtMs !== null
  const isRetryDue = hasAsked && nowMs >= files.manifestAskedAtMs + MANIFEST_RETRY_MS
  const isAskable = !hasAsked || isRetryDue
  const isAskDue = !files.manifestPending && isAskable

  if (files.manifest === null) {
    return noManifestVerdict({files, isAskDue, hasAsked})
  }

  const hasDate = files.manifest.dates.has(trip.serviceDateMs)

  if (!hasDate) {
    return {kind: Verdict.missing, asksManifest: isAskDue}
  }

  const entry = files.manifest.dates.get(trip.serviceDateMs)

  if (entry === null) {
    return {kind: Verdict.missing, asksManifest: false}
  }

  return {kind: Verdict.found, entry, asksManifest: false}
}

// A trip waits for the first ask of the manifest, and is missing
// once an ask has failed.
function noManifestVerdict({files, isAskDue, hasAsked}) {
  if (files.manifestPending) {
    return {kind: Verdict.waiting, asksManifest: false}
  }

  if (!hasAsked) {
    return {kind: Verdict.waiting, asksManifest: true}
  }

  return {kind: Verdict.missing, asksManifest: isAskDue}
}

function indexVerdict({indexes, trip, entry, inFlight, nowMs}) {
  const previous = indexes.get(trip.serviceDateMs)

  const isHeld = previous !== undefined && previous.kind === EntryState.ready

  if (isHeld) {
    return {kind: Verdict.found, index: previous.index, starts: NO_STARTS}
  }

  const fetch = {kind: FileKind.index, serviceDateMs: trip.serviceDateMs, path: entry.path, byteSize: entry.byteSize, sha256: entry.sha256}
  return slotVerdict({previous, fetch, inFlight, nowMs})
}

function shardVerdict({shards, trip, index, inFlight, nowMs}) {
  const shardEntry = index.entryOf(trip.routeId)

  if (shardEntry.kind === TripPathLookup.missing) {
    return {kind: Verdict.missing, starts: NO_STARTS}
  }

  const previous = shards.get(shardKeyOf(trip))

  const isHeld = previous !== undefined && previous.kind === EntryState.ready

  if (isHeld) {
    return {kind: Verdict.found, shard: previous.shard, starts: NO_STARTS}
  }

  const fetch = {
    kind: FileKind.shard,
    serviceDateMs: trip.serviceDateMs,
    routeId: trip.routeId,
    path: shardEntry.path,
    byteSize: shardEntry.byteSize,
    sha256: shardEntry.sha256
  }

  return slotVerdict({previous, fetch, inFlight, nowMs})
}

function pathVerdict({shard, trip}) {
  const path = tripPathFromShard(shard, trip)

  if (path.kind === TripPathLookup.missing) {
    return {kind: Verdict.missing}
  }

  if (!isPreparable(path)) {
    return {kind: Verdict.missing}
  }

  return {kind: Verdict.found, path}
}

function isHeldBack({files, key, nowMs}) {
  const untilMs = files.missingUntilMs.get(key)

  if (untilMs === undefined) {
    return false
  }

  return nowMs < untilMs
}

// One plan's working state: copies of the maps the plan changes, and what it
// has decided so far. Its methods are the only places the state changes.
class PlanWork {
  constructor(files) {
    this.indexes = new Map(files.indexes)
    this.shards = new Map(files.shards)
    this.inFlight = 0
    this.asksManifest = false
    this.fetches = []
    this.paths = []
    this.missingKeys = []

    for (const entry of [...files.indexes.values(), ...files.shards.values()]) {
      if (entry.kind === EntryState.pending) {
        this.inFlight += 1
      }
    }
  }

  askManifest(isAsk) {
    if (isAsk) {
      this.asksManifest = true
    }
  }

  // Records the fetches a verdict starts as in flight.
  start(starts) {
    for (const fetch of starts) {
      if (fetch.kind === FileKind.index) {
        this.indexes.set(fetch.serviceDateMs, pendingOf({fetch, previous: this.indexes.get(fetch.serviceDateMs)}))
      } else {
        const key = shardKeyOf(fetch)
        this.shards.set(key, pendingOf({fetch, previous: this.shards.get(key)}))
      }

      this.inFlight += 1
      this.fetches.push(Object.freeze(fetch))
    }
  }

  // Marks a shard read as most recently used.
  touchShard(trip) {
    const key = shardKeyOf(trip)
    const held = this.shards.get(key)
    this.shards.delete(key)
    this.shards.set(key, held)
  }

  addPath(path) {
    this.paths.push(path)
  }

  addMissing(trip) {
    this.missingKeys.push(tripPathKey(trip))
  }
}

// Decides one trip against the files and records what follows in `work`.
function planTrip({files, work, trip, nowMs}) {
  const dated = manifestVerdict({files, trip, nowMs})
  work.askManifest(dated.asksManifest)

  if (dated.kind === Verdict.waiting) {
    return
  }

  if (dated.kind === Verdict.missing) {
    work.addMissing(trip)
    return
  }

  const indexed = indexVerdict({indexes: work.indexes, trip, entry: dated.entry, inFlight: work.inFlight, nowMs})
  work.start(indexed.starts)

  if (indexed.kind === Verdict.missing) {
    work.addMissing(trip)
  }

  if (indexed.kind === Verdict.found) {
    planShard({work, trip, index: indexed.index, nowMs})
  }
}

function planShard({work, trip, index, nowMs}) {
  const sharded = shardVerdict({shards: work.shards, trip, index, inFlight: work.inFlight, nowMs})
  work.start(sharded.starts)

  if (sharded.kind === Verdict.missing) {
    work.addMissing(trip)
  }

  if (sharded.kind === Verdict.found) {
    work.touchShard(trip)
    planPath({work, trip, shard: sharded.shard})
  }
}

function planPath({work, trip, shard}) {
  const read = pathVerdict({shard, trip})

  if (read.kind === Verdict.found) {
    work.addPath(read.path)
  }

  if (read.kind === Verdict.missing) {
    work.addMissing(trip)
  }
}

function etagOf(files) {
  if (files.manifest === null) {
    return ""
  }

  return files.manifest.etag
}

/**
 * What to do now for `trips`, each with its `tripId`, `routeId`, and
 * `serviceDateMs`: `paths`, the decoded paths of trips the held shards
 * serve, to put in the path cache; `fetches`, the files to
 * fetch now, each `{kind, path, byteSize, sha256}` with the date and route
 * it serves, at most SHARD_FETCH_PARALLEL_MAX in flight; `manifest`, whether
 * to fetch the manifest and the etag to revalidate it with, empty before it
 * is held; and the `files` state that follows. A trip `cache` holds, or
 * with no path until its retry time, is left out; a trip with no path now is
 * held back in `files`, and a trip whose files are in flight is in none of
 * the lists.
 */
export function planTripPathFiles({files, cache, trips, nowMs}) {
  assertTime(nowMs)
  const work = new PlanWork(files)
  const seen = new Set()

  for (const trip of trips) {
    const key = tripPathKey(trip)
    const isRepeat = seen.has(key)
    seen.add(key)
    const isLeftOut = isRepeat || cache.has(key)

    const isWanted = !isLeftOut && !isHeldBack({files, key, nowMs})

    if (isWanted) {
      planTrip({files, work, trip, nowMs})
    }
  }

  const untilMs = nowMs + MISSING_PATH_RETRY_MS
  const missingUntilMs = boundedMissing({missingUntilMs: files.missingUntilMs, keys: work.missingKeys, untilMs})
  const manifestPending = files.manifestPending || work.asksManifest
  const next = Object.freeze({...files, indexes: work.indexes, shards: work.shards, missingUntilMs, manifestPending})

  return Object.freeze({
    files: next,
    paths: Object.freeze(work.paths),
    fetches: Object.freeze(work.fetches),
    manifest: Object.freeze({ask: work.asksManifest, etag: etagOf(files)})
  })
}
