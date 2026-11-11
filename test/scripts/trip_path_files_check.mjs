// Checks how the vehicle page reads trip paths from the snapshot's files: the
// manifest entry of a trip's service date and its re-ask for a date it
// lacks, one index fetch per date, one shard fetch per route and at most four
// fetches in flight, the least recently used shard leaving past the bound, a
// file of another size than the manifest names refused, a failed or timed-out
// fetch retried and then given up, and a trip held back as missing, until its
// retry time, for each of a date with no entry, a route with no shard, and a
// trip its shard lacks. Each case runs
// the pure functions over the shared shard and index fixtures and plain
// manifests, with times as plain numbers. Run it with
// `node test/scripts/trip_path_files_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {AssertionError} from "../../assets/js/assert.js"
import {tripPathKey} from "../../assets/js/trip_path.js"
import {
  FILE_RETRY_MS,
  FileFailure,
  FileKind,
  FileOutcomeKind,
  INDEX_COUNT_MAX,
  MANIFEST_RETRY_MS,
  ManifestOutcomeKind,
  MISSING_PATH_RETRY_MS,
  MISSING_TRIP_COUNT_MAX,
  SHARD_COUNT_MAX,
  SHARD_FAILURE_COUNT_MAX,
  SHARD_FETCH_PARALLEL_MAX,
  emptyTripPathFiles,
  fileFetched,
  hasExpectedSize,
  manifestFetched,
  planTripPathFiles
} from "../../assets/js/trip_path_files.js"
import {decodeTripPathShard, tripPathFromShard} from "../../assets/js/trip_path_shard.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/routing/trip-paths-v1/", import.meta.url))
const shardBytes = new Uint8Array(readFileSync(fixtureDirectory + "shard.bin"))
const indexBytes = new Uint8Array(readFileSync(fixtureDirectory + "index.bin"))
const DAY_MS = 24 * 60 * 60 * 1000
const SERVICE_DATE_MS = 1_794_211_200_000
const OTHER_DATE_MS = SERVICE_DATE_MS + DAY_MS
const START_MS = 1000
const STEP_MS = 1
const DATE_STEP_MS = 1000
const ROUTE_ID = "1_7994"
const INDEX_ENTRY = {path: "/routing/snapshots/dt=2026-11-09/trip-paths-index-aa.bin.gz", byteSize: 120, sha256: "aa"}
const EXTRA_ROUTE_COUNT = 10
const EXTRA_DATE_COUNT = 2
const QUEUED_ROUTE_COUNT = 3
const LATER_RETRY_COUNT = 10
const NOT_A_TIME = Number.NaN
// Shorter than a container's header, so it is not one.
const NOT_A_CONTAINER_BYTE_COUNT = 4
const empty = new Map()

const loopTrip = {tripId: "1_1137791", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}
const absentTrip = {tripId: "1_absent", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}
const unindexedTrip = {tripId: "1_9", routeId: "1_not_in_index", serviceDateMs: SERVICE_DATE_MS}

function snapshotOf(serviceDayStartMs) {
  return {serviceDayStartMs, files: {tripPaths: INDEX_ENTRY}}
}

function manifestOf(dates) {
  return {formatVersion: 2, snapshots: Array.from(dates, snapshotOf)}
}

function changed(manifest, etag = '"e1"') {
  return {kind: ManifestOutcomeKind.changed, manifest, etag}
}

function planAt({files, trips, nowMs}) {
  return planTripPathFiles({files, cache: empty, trips, nowMs})
}

function isHeldBack({files, trip}) {
  return files.missingUntilMs.has(tripPathKey(trip))
}

function plan(files, trips) {
  return planAt({files, trips, nowMs: START_MS})
}

function expandedOutcome(bytes) {
  return {kind: FileOutcomeKind.expanded, bytes}
}

function failedOutcome(reason) {
  return {kind: FileOutcomeKind.failed, reason}
}

// The files a page holds once the manifest, the index, and the loop route's
// shard have been fetched, one step at a time as the page does.
function withLoopShard() {
  let files = plan(emptyTripPathFiles(), [loopTrip]).files
  files = manifestFetched({files, outcome: changed(manifestOf([SERVICE_DATE_MS])), nowMs: START_MS})
  const indexPlan = plan(files, [loopTrip])
  files = fileFetched({files: indexPlan.files, fetch: indexPlan.fetches[0], outcome: expandedOutcome(indexBytes), nowMs: START_MS})
  const shardPlan = plan(files, [loopTrip])
  return fileFetched({files: shardPlan.files, fetch: shardPlan.fetches[0], outcome: expandedOutcome(shardBytes), nowMs: START_MS})
}

// A date with a stub index naming every route, so many shards can be asked
// for; a stub's entries are what a decoded index returns.
function withStubIndex() {
  function entryOf(routeId) {
    return {path: `/routing/${routeId}.bin.gz`, byteSize: 10, sha256: "bb"}
  }

  const ready = {kind: "ready", index: Object.freeze({routeCount: 0, entryOf}), sha256: INDEX_ENTRY.sha256}
  const manifest = {dates: new Map([[SERVICE_DATE_MS, INDEX_ENTRY]]), etag: '"e1"'}
  return Object.freeze({...emptyTripPathFiles(), manifest, indexes: new Map([[SERVICE_DATE_MS, ready]])})
}

function tripOfRoute(index) {
  return {tripId: `1_t${index}`, routeId: `1_r${index}`, serviceDateMs: SERVICE_DATE_MS}
}

function tripOfRouteAt(_unused, index) {
  return tripOfRoute(index)
}

function unindexedTripAt(_unused, index) {
  return {tripId: `1_u${index}`, routeId: `1_not_in_index_${index}`, serviceDateMs: SERVICE_DATE_MS}
}

function dateAt(_unused, index) {
  return SERVICE_DATE_MS + index * DATE_STEP_MS
}

function planAtNoTime() {
  return planAt({files: emptyTripPathFiles(), trips: [loopTrip], nowMs: NOT_A_TIME})
}

function fetchSummary(fetch) {
  return [fetch.kind, fetch.path, fetch.serviceDateMs]
}

// No manifest: the first plan asks for it once and holds the trips.
const first = plan(emptyTripPathFiles(), [loopTrip])
deepStrictEqual(first.manifest.ask, true, "the manifest is asked for first")
deepStrictEqual(first.manifest.etag, "", "a first ask names no etag")
deepStrictEqual([isHeldBack({files: first.files, trip: loopTrip}), first.paths.length, first.fetches.length], [false, 0, 0], "a trip waits for the manifest")
deepStrictEqual(planAt({files: first.files, trips: [loopTrip], nowMs: START_MS + STEP_MS}).manifest.ask, false, "the manifest is not asked for while an ask runs")

// A failed ask leaves the trips with no path and is repeated after its retry time.
const askFailed = manifestFetched({files: first.files, outcome: {kind: ManifestOutcomeKind.failed}, nowMs: START_MS})
const afterFailure = planAt({files: askFailed, trips: [loopTrip], nowMs: START_MS + STEP_MS})
ok(isHeldBack({files: afterFailure.files, trip: loopTrip}), "a trip is held back with no manifest")
deepStrictEqual(afterFailure.manifest.ask, false, "a failed ask waits its retry time")
deepStrictEqual(planAt({files: askFailed, trips: [loopTrip], nowMs: START_MS + MANIFEST_RETRY_MS}).manifest.ask, true, "a failed ask is repeated at its retry time")

// With the manifest, the index of the date is fetched once.
const withManifest = manifestFetched({files: first.files, outcome: changed(manifestOf([SERVICE_DATE_MS])), nowMs: START_MS})
const indexPlan = plan(withManifest, [loopTrip, absentTrip])
const indexFetchSummaries = Array.from(indexPlan.fetches, fetchSummary)
deepStrictEqual(indexFetchSummaries, [[FileKind.index, INDEX_ENTRY.path, SERVICE_DATE_MS]], "one index fetch for two trips of one date")
deepStrictEqual(plan(indexPlan.files, [loopTrip]).fetches, [], "the index is not fetched again while it is fetched")

// With the index, one shard fetch for the route, named by the index.
const withIndex = fileFetched({files: indexPlan.files, fetch: indexPlan.fetches[0], outcome: expandedOutcome(indexBytes), nowMs: START_MS})
const shardPlan = plan(withIndex, [loopTrip, absentTrip])
deepStrictEqual(shardPlan.fetches.length, 1, "one shard fetch for two trips of one route")
deepStrictEqual(shardPlan.fetches[0].kind, FileKind.shard, "the fetch is a shard's")
deepStrictEqual(shardPlan.fetches[0].routeId, ROUTE_ID, "the shard is the route's")
ok(!isHeldBack({files: shardPlan.files, trip: loopTrip}), "trips wait for the shard")

// A route the index lacks is held back at once.
ok(isHeldBack({files: plan(withIndex, [unindexedTrip]).files, trip: unindexedTrip}), "a route with no shard is held back")

// With the shard, the trip is read from it; a trip it lacks is held back.
const held = withLoopShard()
const served = plan(held, [loopTrip, absentTrip])
deepStrictEqual(served.paths.length, 1, "the shard serves its trip")
deepStrictEqual(served.paths[0], tripPathFromShard(decodeTripPathShard(shardBytes).shard, loopTrip), "the path is the shard's")
ok(isHeldBack({files: served.files, trip: absentTrip}), "a trip its shard lacks is held back")
ok(!isHeldBack({files: served.files, trip: loopTrip}), "a trip found in a shard is not held back")
deepStrictEqual(served.fetches, [], "a held shard is not fetched again")

// A trip the path cache holds is left out.
const cache = new Map([[tripPathKey(loopTrip), {}]])
const cached = planTripPathFiles({files: held, cache, trips: [loopTrip, absentTrip], nowMs: START_MS})
deepStrictEqual([cached.paths.length, isHeldBack({files: cached.files, trip: loopTrip})], [0, false], "a cached trip is left out")

// A trip held back is left out until its retry time and decided again then.
const heldBack = planAt({files: served.files, trips: [absentTrip], nowMs: START_MS + MISSING_PATH_RETRY_MS - STEP_MS})
deepStrictEqual(heldBack.files.missingUntilMs, served.files.missingUntilMs, "a held back trip is not decided again before its retry time")
const decidedAgain = planAt({files: served.files, trips: [absentTrip], nowMs: START_MS + MISSING_PATH_RETRY_MS})
deepStrictEqual(Array.from(decidedAgain.files.missingUntilMs.values()), [START_MS + 2 * MISSING_PATH_RETRY_MS], "a trip is held back again for a full retry time")

// A date with no entry is held back and asks for the manifest again at most once per retry time.
const otherDay = {...loopTrip, serviceDateMs: OTHER_DATE_MS}
const missingDate = planAt({files: held, trips: [otherDay], nowMs: START_MS + MANIFEST_RETRY_MS - STEP_MS})
ok(isHeldBack({files: missingDate.files, trip: otherDay}), "a date with no entry is held back")
deepStrictEqual(missingDate.manifest.ask, false, "the manifest is not asked for again before its retry time")
const reAsk = planAt({files: held, trips: [otherDay], nowMs: START_MS + MANIFEST_RETRY_MS})
deepStrictEqual(reAsk.manifest, {ask: true, etag: '"e1"'}, "the manifest is revalidated with its etag at the retry time")
deepStrictEqual(planAt({files: reAsk.files, trips: [otherDay], nowMs: START_MS + MANIFEST_RETRY_MS + STEP_MS}).manifest.ask, false, "one ask at a time")

// An unchanged manifest keeps what is held; a new one drops the files of a date whose index changed.
const unchanged = manifestFetched({files: reAsk.files, outcome: {kind: ManifestOutcomeKind.unchanged}, nowMs: START_MS + MANIFEST_RETRY_MS})
deepStrictEqual(plan(unchanged, [loopTrip]).paths.length, 1, "an unchanged manifest keeps the shards")
const newIndexManifest = {snapshots: [{serviceDayStartMs: SERVICE_DATE_MS, files: {tripPaths: {...INDEX_ENTRY, sha256: "cc"}}}]}
const replaced = manifestFetched({files: unchanged, outcome: changed(newIndexManifest, '"e2"'), nowMs: START_MS})
deepStrictEqual(plan(replaced, [loopTrip]).paths.length, 0, "a date whose index changed drops its shards")
deepStrictEqual(plan(replaced, [loopTrip]).fetches[0].kind, FileKind.index, "and fetches the new index")

// A date whose snapshot has no trip paths is held back.
const noPathsManifest = {snapshots: [{serviceDayStartMs: SERVICE_DATE_MS, files: {}}]}
const noPaths = manifestFetched({files: emptyTripPathFiles(), outcome: changed(noPathsManifest), nowMs: START_MS})
ok(isHeldBack({files: plan(noPaths, [loopTrip]).files, trip: loopTrip}), "a date with no index file is held back")

// A body that is not a manifest counts as a failure, and the manifest holds at most three dates.
const notManifest = manifestFetched({files: emptyTripPathFiles(), outcome: changed({snapshots: "x"}), nowMs: START_MS})
deepStrictEqual(notManifest.manifest, null, "a body that is not a manifest is no manifest")
const manyDates = Array.from({length: INDEX_COUNT_MAX + EXTRA_DATE_COUNT}, dateAt)
const bounded = manifestFetched({files: emptyTripPathFiles(), outcome: changed(manifestOf(manyDates)), nowMs: START_MS})
deepStrictEqual(bounded.manifest.dates.size, INDEX_COUNT_MAX, "the manifest's dates are bounded")

// At most four fetches in flight, and none past them until one settles.
const routes = Array.from({length: SHARD_FETCH_PARALLEL_MAX + QUEUED_ROUTE_COUNT}, tripOfRouteAt)
const wave = plan(withStubIndex(), routes)
deepStrictEqual(wave.fetches.length, SHARD_FETCH_PARALLEL_MAX, "the fetches in flight are capped")
const waveNext = planAt({files: wave.files, trips: routes, nowMs: START_MS + STEP_MS})
deepStrictEqual(waveNext.fetches, [], "no more fetches while the cap is held")
const settled = fileFetched({files: waveNext.files, fetch: wave.fetches[0], outcome: expandedOutcome(shardBytes), nowMs: START_MS + STEP_MS})
deepStrictEqual(planAt({files: settled, trips: routes, nowMs: START_MS + STEP_MS}).fetches.length, 1, "a settled fetch frees one slot")

// Shards are held to the bound, the least recently used leaving first.
let stubbed = withStubIndex()
const lruCount = SHARD_COUNT_MAX + EXTRA_ROUTE_COUNT

for (let step = 0; step < lruCount; step += 1) {
  // Each step is a retry time after the one before, so the trips it held back are decided again.
  const stepMs = START_MS + step * MISSING_PATH_RETRY_MS
  const stepPlan = planAt({files: stubbed, trips: [tripOfRoute(step)], nowMs: stepMs})
  stubbed = stepPlan.files

  for (const fetch of stepPlan.fetches) {
    stubbed = fileFetched({files: stubbed, fetch, outcome: expandedOutcome(shardBytes), nowMs: stepMs})
  }

  stubbed = planAt({files: stubbed, trips: [tripOfRoute(0)], nowMs: stepMs}).files
}

deepStrictEqual(stubbed.shards.size, SHARD_COUNT_MAX, "the shards held are bounded")
ok(stubbed.shards.has(`${SERVICE_DATE_MS}/1_r0`), "a shard in use stays")
ok(!stubbed.shards.has(`${SERVICE_DATE_MS}/1_r1`), "the least recently used shard leaves")

// A file of another size than named is refused by the rule the page applies before expanding it.
const sized = {byteSize: 120}
deepStrictEqual(hasExpectedSize({fetch: sized, byteLength: 120}), true, "the named size is accepted")
deepStrictEqual(hasExpectedSize({fetch: sized, byteLength: 121}), false, "another size is refused")

// A failed or timed-out fetch is retried after its time, and given up after the count.
const failureReasons = [FileFailure.timeout, FileFailure.sizeMismatch, FileFailure.fetch]
let flaky = withStubIndex()
const flakyTrip = tripOfRoute(0)

for (let failure = 1; failure <= SHARD_FAILURE_COUNT_MAX; failure += 1) {
  const nowMs = START_MS + failure * FILE_RETRY_MS
  const attempt = planAt({files: flaky, trips: [flakyTrip], nowMs: nowMs})
  deepStrictEqual(attempt.fetches.length, 1, `attempt ${failure} fetches the shard`)
  flaky = fileFetched({files: attempt.files, fetch: attempt.fetches[0], outcome: failedOutcome(failureReasons[failure - 1]), nowMs})
  const waiting = planAt({files: flaky, trips: [flakyTrip], nowMs: nowMs + FILE_RETRY_MS - STEP_MS})

  if (failure < SHARD_FAILURE_COUNT_MAX) {
    deepStrictEqual([waiting.fetches.length, isHeldBack({files: waiting.files, trip: flakyTrip})], [0, false], `failure ${failure} waits its retry time`)
  }
}

const givenUp = planAt({files: flaky, trips: [flakyTrip], nowMs: START_MS + LATER_RETRY_COUNT * FILE_RETRY_MS})
ok(isHeldBack({files: givenUp.files, trip: flakyTrip}), "a file that failed three times leaves its trips with no path")
deepStrictEqual(givenUp.fetches, [], "and is not fetched again")

// A file that does not decode counts as a failure.
const badPlan = plan(withStubIndex(), [flakyTrip])
const bad = fileFetched({files: badPlan.files, fetch: badPlan.fetches[0], outcome: expandedOutcome(new Uint8Array(NOT_A_CONTAINER_BYTE_COUNT)), nowMs: START_MS})
deepStrictEqual(planAt({files: bad, trips: [flakyTrip], nowMs: START_MS + STEP_MS}).fetches, [], "a file that does not decode waits its retry time")
deepStrictEqual(bad.shards.get(`${SERVICE_DATE_MS}/1_r0`).kind, "failed", "a file that does not decode is failed")

// The trips held back are bounded, the earliest leaving first.
const unindexedTrips = Array.from({length: MISSING_TRIP_COUNT_MAX + EXTRA_ROUTE_COUNT}, unindexedTripAt)
const overflowed = plan(withIndex, unindexedTrips)
deepStrictEqual(overflowed.files.missingUntilMs.size, MISSING_TRIP_COUNT_MAX, "the trips held back are bounded")
ok(!isHeldBack({files: overflowed.files, trip: unindexedTrips[0]}), "the trip held back earliest leaves first")

// A time that is not a number is a programmer error.
throws(planAtNoTime, AssertionError, "a time that is not a number")

console.log("trip path files check passed")
