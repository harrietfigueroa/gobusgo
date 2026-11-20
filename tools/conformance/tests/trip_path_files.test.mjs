// Checks how the vehicle page reads trip paths from the snapshot's files: the
// manifest entry of a trip's service date and its re-ask for a date it
// lacks, one index fetch per date, one shard fetch per route and at most four
// fetches in flight, the least recently used shard leaving past the bound, a
// file of another size than the manifest names refused, a failed or timed-out
// fetch retried and then given up, and a trip held back as missing, until its
// retry time, for each of a date with no entry, a route with no shard, and a
// trip its shard lacks. Each case runs the pure functions over the shared
// shard and index fixtures and plain manifests, with times as plain numbers.
// The planning is a sequence of states, each built from the one before, so
// each implementation builds the sequence once and every test reads it.

import {beforeAll, describe, expect, test} from "vitest"
import {fixtureBytes} from "../fixtures.mjs"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const FIXTURE_DIRECTORY = "routing/trip-paths-v1/"
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
const NAMED_BYTE_SIZE = 120
const OTHER_BYTE_SIZE = 121
const EMPTY_CACHE = new Map()

const loopTrip = {tripId: "1_1137791", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}
const absentTrip = {tripId: "1_absent", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}
const unindexedTrip = {tripId: "1_9", routeId: "1_not_in_index", serviceDateMs: SERVICE_DATE_MS}
const otherDay = {...loopTrip, serviceDateMs: OTHER_DATE_MS}

let shardBytes = null
let indexBytes = null

beforeAll(async () => {
  const shardBuffer = await fixtureBytes(FIXTURE_DIRECTORY + "shard.bin")
  const indexBuffer = await fixtureBytes(FIXTURE_DIRECTORY + "index.bin")
  shardBytes = new Uint8Array(shardBuffer)
  indexBytes = new Uint8Array(indexBuffer)
})

function snapshotOf(serviceDayStartMs) {
  return {serviceDayStartMs, files: {tripPaths: INDEX_ENTRY}}
}

function manifestOf(dates) {
  return {formatVersion: 2, snapshots: Array.from(dates, snapshotOf)}
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

function fetchSummary(fetch) {
  return [fetch.kind, fetch.path, fetch.serviceDateMs]
}

describe.each(IMPLEMENTATIONS)("trip path files ($name)", (implementation) => {
  const {AssertionError, scheduledPath, tripPath, tripPathFiles, tripPathShard} = implementation
  const {
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
    isTripHeldBack,
    manifestFetched,
    planTripPathFiles
  } = tripPathFiles
  const {isFallbackDue} = scheduledPath

  function changed(manifest, etag = '"e1"') {
    return {kind: ManifestOutcomeKind.changed, manifest, etag}
  }

  function planAt({files, trips, nowMs}) {
    return planTripPathFiles({files, cache: EMPTY_CACHE, trips, nowMs})
  }

  function isHeldBack({files, trip}) {
    const key = tripPath.tripPathKey(trip)
    return files.missingUntilMs.has(key)
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

  // A date with a stub index naming every route, so many shards can be asked
  // for; a stub's entries are what a decoded index returns.
  function withStubIndex() {
    function entryOf(routeId) {
      return {path: `/routing/${routeId}.bin.gz`, byteSize: 10, sha256: "bb"}
    }

    const ready = {kind: "ready", index: Object.freeze({routeCount: 0, entryOf}), sha256: INDEX_ENTRY.sha256}
    const manifest = {dates: new Map([[SERVICE_DATE_MS, INDEX_ENTRY]]), etag: '"e1"'}
    const empty = emptyTripPathFiles()
    return Object.freeze({...empty, manifest, indexes: new Map([[SERVICE_DATE_MS, ready]])})
  }

  // A scheduled vehicle of the saved schedule takes the fallback path where the shards cannot serve its trip.
  function savedMarkerOf({trip, isSavedSchedule = true, serviceDateMs = trip.serviceDateMs}) {
    return {is_saved_schedule: isSavedSchedule, trip_id: trip.tripId, route_id: trip.routeId, service_date_ms: serviceDateMs}
  }

  // The states of the sequence, each built from the one before.
  const states = {}

  beforeAll(() => {
    const emptyFiles = emptyTripPathFiles()
    states.first = plan(emptyFiles, [loopTrip])
    states.askFailed = manifestFetched({files: states.first.files, outcome: {kind: ManifestOutcomeKind.failed}, nowMs: START_MS})
    const firstManifest = manifestOf([SERVICE_DATE_MS])
    states.withManifest = manifestFetched({files: states.first.files, outcome: changed(firstManifest), nowMs: START_MS})
    states.indexPlan = plan(states.withManifest, [loopTrip, absentTrip])
    const indexOutcome = expandedOutcome(indexBytes)
    states.withIndex = fileFetched({files: states.indexPlan.files, fetch: states.indexPlan.fetches[0], outcome: indexOutcome, nowMs: START_MS})
    states.shardPlan = plan(states.withIndex, [loopTrip, absentTrip])
    const shardOutcome = expandedOutcome(shardBytes)
    states.held = fileFetched({files: states.shardPlan.files, fetch: states.shardPlan.fetches[0], outcome: shardOutcome, nowMs: START_MS})
    states.served = plan(states.held, [loopTrip, absentTrip])
    states.reAsk = planAt({files: states.held, trips: [otherDay], nowMs: START_MS + MANIFEST_RETRY_MS})
    const unchangedOutcome = {kind: ManifestOutcomeKind.unchanged}
    states.unchanged = manifestFetched({files: states.reAsk.files, outcome: unchangedOutcome, nowMs: START_MS + MANIFEST_RETRY_MS})
  })

  // No manifest: the first plan asks for it once and holds the trips.
  test("a first plan asks for the manifest and holds the trips", () => {
    const {first} = states
    expect(first.manifest.ask).toBe(true)
    expect(first.manifest.etag).toBe("")
    const heldBack = isHeldBack({files: first.files, trip: loopTrip})
    expect([heldBack, first.paths.length, first.fetches.length]).toStrictEqual([false, 0, 0])
    const later = planAt({files: first.files, trips: [loopTrip], nowMs: START_MS + STEP_MS})
    expect(later.manifest.ask).toBe(false)
  })

  // A failed ask leaves the trips with no path and is repeated after its retry time.
  test("a failed manifest ask is repeated at its retry time", () => {
    const afterFailure = planAt({files: states.askFailed, trips: [loopTrip], nowMs: START_MS + STEP_MS})
    expect(isHeldBack({files: afterFailure.files, trip: loopTrip})).toBe(true)
    expect(afterFailure.manifest.ask).toBe(false)
    const atRetry = planAt({files: states.askFailed, trips: [loopTrip], nowMs: START_MS + MANIFEST_RETRY_MS})
    expect(atRetry.manifest.ask).toBe(true)
  })

  // With the manifest, the index of the date is fetched once.
  test("one index fetch per date", () => {
    const indexFetchSummaries = Array.from(states.indexPlan.fetches, fetchSummary)
    expect(indexFetchSummaries).toStrictEqual([[FileKind.index, INDEX_ENTRY.path, SERVICE_DATE_MS]])
    const again = plan(states.indexPlan.files, [loopTrip])
    expect(again.fetches).toStrictEqual([])
  })

  // With the index, one shard fetch for the route, named by the index.
  test("one shard fetch per route, named by the index", () => {
    const {shardPlan} = states
    expect(shardPlan.fetches.length).toBe(1)
    expect(shardPlan.fetches[0].kind).toBe(FileKind.shard)
    expect(shardPlan.fetches[0].routeId).toBe(ROUTE_ID)
    expect(isHeldBack({files: shardPlan.files, trip: loopTrip})).toBe(false)
  })

  // A route the index lacks is held back at once.
  test("a route with no shard is held back", () => {
    const unindexedPlan = plan(states.withIndex, [unindexedTrip])
    expect(isHeldBack({files: unindexedPlan.files, trip: unindexedTrip})).toBe(true)
  })

  // With the shard, the trip is read from it; a trip it lacks is held back.
  test("the shard serves its trip and holds back a trip it lacks", () => {
    const {served} = states
    expect(served.paths.length).toBe(1)
    const {shard} = tripPathShard.decodeTripPathShard(shardBytes)
    const fromShard = tripPathShard.tripPathFromShard(shard, loopTrip)
    expect(served.paths[0]).toStrictEqual(fromShard)
    expect(isHeldBack({files: served.files, trip: absentTrip})).toBe(true)
    expect(isHeldBack({files: served.files, trip: loopTrip})).toBe(false)
    expect(served.fetches).toStrictEqual([])
  })

  // A trip the path cache holds is left out.
  test("a cached trip is left out", () => {
    const loopKey = tripPath.tripPathKey(loopTrip)
    const cache = new Map([[loopKey, {}]])
    const cached = planTripPathFiles({files: states.held, cache, trips: [loopTrip, absentTrip], nowMs: START_MS})
    const heldBack = isHeldBack({files: cached.files, trip: loopTrip})
    expect([cached.paths.length, heldBack]).toStrictEqual([0, false])
  })

  // A trip held back is left out until its retry time and decided again then.
  test("a held back trip is decided again at its retry time", () => {
    const {served} = states
    const heldBack = planAt({files: served.files, trips: [absentTrip], nowMs: START_MS + MISSING_PATH_RETRY_MS - STEP_MS})
    expect(heldBack.files.missingUntilMs).toStrictEqual(served.files.missingUntilMs)
    const decidedAgain = planAt({files: served.files, trips: [absentTrip], nowMs: START_MS + MISSING_PATH_RETRY_MS})
    const decidedAgainUntilMs = Array.from(decidedAgain.files.missingUntilMs.values())
    expect(decidedAgainUntilMs).toStrictEqual([START_MS + MISSING_PATH_RETRY_MS + MISSING_PATH_RETRY_MS])
  })

  // A trip is held back to its retry time, and not after it.
  test("isTripHeldBack holds a trip back to its retry time and not after", () => {
    const {served} = states
    expect(isTripHeldBack({files: served.files, trip: absentTrip, nowMs: START_MS + MISSING_PATH_RETRY_MS - STEP_MS})).toBe(true)
    expect(isTripHeldBack({files: served.files, trip: absentTrip, nowMs: START_MS + MISSING_PATH_RETRY_MS})).toBe(false)
    expect(isTripHeldBack({files: served.files, trip: loopTrip, nowMs: START_MS})).toBe(false)
  })

  test("isFallbackDue takes the fallback path where the shards cannot serve a trip", () => {
    const {first, served} = states
    const heldNowMs = START_MS + MISSING_PATH_RETRY_MS - STEP_MS
    const absentMarker = savedMarkerOf({trip: absentTrip})
    const loopMarker = savedMarkerOf({trip: loopTrip})
    const unsavedDateMarker = savedMarkerOf({trip: loopTrip, serviceDateMs: null})
    const serverMarker = savedMarkerOf({trip: absentTrip, isSavedSchedule: false})
    expect(isFallbackDue({marker: absentMarker, files: served.files, nowMs: heldNowMs})).toBe(true)
    expect(isFallbackDue({marker: absentMarker, files: served.files, nowMs: START_MS + MISSING_PATH_RETRY_MS})).toBe(false)
    expect(isFallbackDue({marker: loopMarker, files: served.files, nowMs: START_MS})).toBe(false)
    expect(isFallbackDue({marker: loopMarker, files: first.files, nowMs: START_MS})).toBe(false)
    expect(isFallbackDue({marker: unsavedDateMarker, files: first.files, nowMs: START_MS})).toBe(true)
    expect(isFallbackDue({marker: serverMarker, files: served.files, nowMs: heldNowMs})).toBe(false)
  })

  // A date with no entry is held back and asks for the manifest again at most once per retry time.
  test("a date with no entry re-asks for the manifest once per retry time", () => {
    const {held, reAsk} = states
    const missingDate = planAt({files: held, trips: [otherDay], nowMs: START_MS + MANIFEST_RETRY_MS - STEP_MS})
    expect(isHeldBack({files: missingDate.files, trip: otherDay})).toBe(true)
    expect(missingDate.manifest.ask).toBe(false)
    expect(reAsk.manifest).toStrictEqual({ask: true, etag: '"e1"'})
    const next = planAt({files: reAsk.files, trips: [otherDay], nowMs: START_MS + MANIFEST_RETRY_MS + STEP_MS})
    expect(next.manifest.ask).toBe(false)
  })

  // An unchanged manifest keeps what is held; a new one drops the files of a date whose index changed.
  test("a manifest whose index changed drops that date's shards", () => {
    const {unchanged} = states
    const unchangedPlan = plan(unchanged, [loopTrip])
    expect(unchangedPlan.paths.length).toBe(1)
    const newIndexManifest = {snapshots: [{serviceDayStartMs: SERVICE_DATE_MS, files: {tripPaths: {...INDEX_ENTRY, sha256: "cc"}}}]}
    const replacedOutcome = changed(newIndexManifest, '"e2"')
    const replaced = manifestFetched({files: unchanged, outcome: replacedOutcome, nowMs: START_MS})
    const replacedPlan = plan(replaced, [loopTrip])
    expect(replacedPlan.paths.length).toBe(0)
    expect(replacedPlan.fetches[0].kind).toBe(FileKind.index)
  })

  // A date whose snapshot has no trip paths is held back.
  test("a date with no index file is held back", () => {
    const noPathsManifest = {snapshots: [{serviceDayStartMs: SERVICE_DATE_MS, files: {}}]}
    const noPathsOutcome = changed(noPathsManifest)
    const emptyFiles = emptyTripPathFiles()
    const noPaths = manifestFetched({files: emptyFiles, outcome: noPathsOutcome, nowMs: START_MS})
    const noPathsPlan = plan(noPaths, [loopTrip])
    expect(isHeldBack({files: noPathsPlan.files, trip: loopTrip})).toBe(true)
  })

  // A body that is not a manifest counts as a failure, and the manifest holds at most three dates.
  test("a body that is not a manifest is no manifest", () => {
    const notManifestOutcome = changed({snapshots: "x"})
    const emptyFiles = emptyTripPathFiles()
    const notManifest = manifestFetched({files: emptyFiles, outcome: notManifestOutcome, nowMs: START_MS})
    expect(notManifest.manifest).toBe(null)
  })

  test("the manifest's dates are bounded", () => {
    const manyDates = Array.from({length: INDEX_COUNT_MAX + EXTRA_DATE_COUNT}, dateAt)
    const manyOutcome = changed(manifestOf(manyDates))
    const emptyFiles = emptyTripPathFiles()
    const bounded = manifestFetched({files: emptyFiles, outcome: manyOutcome, nowMs: START_MS})
    expect(bounded.manifest.dates.size).toBe(INDEX_COUNT_MAX)
  })

  // At most four fetches in flight, and none past them until one settles.
  test("the fetches in flight are capped", () => {
    const routes = Array.from({length: SHARD_FETCH_PARALLEL_MAX + QUEUED_ROUTE_COUNT}, tripOfRouteAt)
    const wave = plan(withStubIndex(), routes)
    expect(wave.fetches.length).toBe(SHARD_FETCH_PARALLEL_MAX)
    const waveNext = planAt({files: wave.files, trips: routes, nowMs: START_MS + STEP_MS})
    expect(waveNext.fetches).toStrictEqual([])
    const shardOutcome = expandedOutcome(shardBytes)
    const settled = fileFetched({files: waveNext.files, fetch: wave.fetches[0], outcome: shardOutcome, nowMs: START_MS + STEP_MS})
    const afterSettled = planAt({files: settled, trips: routes, nowMs: START_MS + STEP_MS})
    expect(afterSettled.fetches.length).toBe(1)
  })

  // Shards are held to the bound, the least recently used leaving first.
  test("the shards held are bounded, the least recently used leaving first", () => {
    let stubbed = withStubIndex()
    const lruCount = SHARD_COUNT_MAX + EXTRA_ROUTE_COUNT

    for (let step = 0; step < lruCount; step += 1) {
      // Each step is a retry time after the one before, so the trips it held back are decided again.
      const stepMs = START_MS + step * MISSING_PATH_RETRY_MS
      const stepTrip = tripOfRoute(step)
      const stepPlan = planAt({files: stubbed, trips: [stepTrip], nowMs: stepMs})
      stubbed = stepPlan.files

      for (const fetch of stepPlan.fetches) {
        const shardOutcome = expandedOutcome(shardBytes)
        stubbed = fileFetched({files: stubbed, fetch, outcome: shardOutcome, nowMs: stepMs})
      }

      const firstTrip = tripOfRoute(0)
      stubbed = planAt({files: stubbed, trips: [firstTrip], nowMs: stepMs}).files
    }

    expect(stubbed.shards.size).toBe(SHARD_COUNT_MAX)
    expect(stubbed.shards.has(`${SERVICE_DATE_MS}/1_r0`)).toBe(true)
    expect(stubbed.shards.has(`${SERVICE_DATE_MS}/1_r1`)).toBe(false)
  })

  // A file of another size than named is refused by the rule the page applies before expanding it.
  test("a file of another size than named is refused", () => {
    const sized = {byteSize: NAMED_BYTE_SIZE}
    expect(hasExpectedSize({fetch: sized, byteLength: NAMED_BYTE_SIZE})).toBe(true)
    expect(hasExpectedSize({fetch: sized, byteLength: OTHER_BYTE_SIZE})).toBe(false)
  })

  // A failed or timed-out fetch is retried after its time, and given up after the count.
  test("a failed fetch is retried, then given up after the count", () => {
    const failureReasons = [FileFailure.timeout, FileFailure.sizeMismatch, FileFailure.fetch]
    let flaky = withStubIndex()
    const flakyTrip = tripOfRoute(0)

    for (let failure = 1; failure <= SHARD_FAILURE_COUNT_MAX; failure += 1) {
      const nowMs = START_MS + failure * FILE_RETRY_MS
      const attempt = planAt({files: flaky, trips: [flakyTrip], nowMs})
      expect(attempt.fetches.length).toBe(1)
      const failedReason = failedOutcome(failureReasons[failure - 1])
      flaky = fileFetched({files: attempt.files, fetch: attempt.fetches[0], outcome: failedReason, nowMs})
      const waiting = planAt({files: flaky, trips: [flakyTrip], nowMs: nowMs + FILE_RETRY_MS - STEP_MS})

      if (failure < SHARD_FAILURE_COUNT_MAX) {
        const heldBack = isHeldBack({files: waiting.files, trip: flakyTrip})
        expect([waiting.fetches.length, heldBack]).toStrictEqual([0, false])
      }
    }

    const givenUp = planAt({files: flaky, trips: [flakyTrip], nowMs: START_MS + LATER_RETRY_COUNT * FILE_RETRY_MS})
    expect(isHeldBack({files: givenUp.files, trip: flakyTrip})).toBe(true)
    expect(givenUp.fetches).toStrictEqual([])
  })

  // A file that does not decode counts as a failure.
  test("a file that does not decode is failed and waits its retry time", () => {
    const flakyTrip = tripOfRoute(0)
    const badPlan = plan(withStubIndex(), [flakyTrip])
    const notContainer = new Uint8Array(NOT_A_CONTAINER_BYTE_COUNT)
    const badOutcome = expandedOutcome(notContainer)
    const bad = fileFetched({files: badPlan.files, fetch: badPlan.fetches[0], outcome: badOutcome, nowMs: START_MS})
    const afterBad = planAt({files: bad, trips: [flakyTrip], nowMs: START_MS + STEP_MS})
    expect(afterBad.fetches).toStrictEqual([])
    expect(bad.shards.get(`${SERVICE_DATE_MS}/1_r0`).kind).toBe("failed")
  })

  // The trips held back are bounded, the earliest leaving first.
  test("the trips held back are bounded, the earliest leaving first", () => {
    const unindexedTrips = Array.from({length: MISSING_TRIP_COUNT_MAX + EXTRA_ROUTE_COUNT}, unindexedTripAt)
    const overflowed = plan(states.withIndex, unindexedTrips)
    expect(overflowed.files.missingUntilMs.size).toBe(MISSING_TRIP_COUNT_MAX)
    expect(isHeldBack({files: overflowed.files, trip: unindexedTrips[0]})).toBe(false)
  })

  // A time that is not a number is a programmer error.
  test("a time that is not a number", () => {
    const emptyFiles = emptyTripPathFiles()
    expect(() => planAt({files: emptyFiles, trips: [loopTrip], nowMs: NOT_A_TIME})).toThrow(AssertionError)
  })
})
