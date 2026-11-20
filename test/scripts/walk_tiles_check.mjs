// Checks the page's store of walk graph tiles over a stand-in for `fetch`
// that serves the walk graph fixture's gzip streams and holds a response back
// until the check lets it go, over an `AbortSignal.timeout` and a clock the
// check moves by hand: the race of a window against its
// deadline, one fetch for a tile however many ask, a failed tile fetched by the
// next window and by no bare ask, the oldest tile dropped past the bound and
// no tile a window waits for, and the source retried after SOURCE_RETRY_MS. Run it with `node test/scripts/walk_tiles_check.mjs`; it
// exits non-zero on the first case that differs.

import {readFileSync} from "node:fs"
import {setTimeout as sleep} from "node:timers/promises"
import {fileURLToPath} from "node:url"
import {deepStrictEqual, ok, strictEqual} from "node:assert/strict"
import {TILE_LAT_UNITS, TILE_LON_UNITS, UNITS_PER_DEGREE, tileKey, walkGraphShardName} from "../../assets/js/core/walk_graph_file.js"
import {HELD_TILE_COUNT_MAX, SourceKind, WindowFailure, WindowKind, createWalkTiles} from "../../assets/js/walk_tiles.js"

const directory = fileURLToPath(new URL("../fixtures/walk_graph/v1/", import.meta.url))
const BUILD_ID = "0123456789abcdef"
const KIND_VERSION = 1
const WINDOW_TILE_COUNT = 2
const INDEX_PATH = "/intersections/walk-graph-index-aa.bin.gz"
const MANIFEST_URL = "/api/walk-graph/manifest"
const SOURCE_RETRY_MS = 60 * 1000
const DEADLINE_MS = 1234
const POSITION = {lat: 47.6145, lon: -122.334}
const WEST_TILE = {row: 4761, column: -8156}

function bytesOf(name) {
  const buffer = readFileSync(directory + name)
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength)
}

const shardBytes = bytesOf("shard-west.bin.gz")
const indexBytes = bytesOf("index.bin.gz")
const manifest = {
  buildId: BUILD_ID,
  index: {path: INDEX_PATH, byteSize: indexBytes.byteLength, sha256: "aa"},
  tile: {latUnits: TILE_LAT_UNITS, lonUnits: TILE_LON_UNITS},
  kindVersion: KIND_VERSION,
  unitsPerDegree: UNITS_PER_DEGREE
}

// The stand-in's state: each request it saw, the paths it answers 503 to, and
// the gates that hold a response back until released.
const requests = []
const refused = new Set()
const gates = new Map()
const timers = []
let nowMs = 0

Object.defineProperty(globalThis, "performance", {value: {now: () => nowMs}, configurable: true})

AbortSignal.timeout = function timeoutFor(ms) {
  const controller = new AbortController()
  timers.push({ms, fire: () => controller.abort()})
  return controller.signal
}

function responseOf(body) {
  return {ok: true, status: 200, json: async () => body, arrayBuffer: async () => body}
}

globalThis.fetch = async function fetchStandIn(url) {
  requests.push(url)
  const gate = gates.get(url)

  if (gate !== undefined) {
    await gate.promise
  }

  if (refused.has(url)) {
    return {ok: false, status: 503}
  }

  if (url === MANIFEST_URL) {
    return responseOf(manifest)
  }

  if (url === INDEX_PATH) {
    return responseOf(indexBytes)
  }

  return responseOf(shardBytes)
}

function hold(url) {
  let release = null
  const promise = new Promise((resolve) => { release = resolve })
  gates.set(url, {promise, release})
}

function release(url) {
  gates.get(url).release()
  gates.delete(url)
}

function countOf(url) {
  return requests.filter((requested) => requested === url).length
}

function shardUrlOf({buildId, tile}) {
  const directoryOfIndex = INDEX_PATH.slice(0, INDEX_PATH.lastIndexOf("/") + 1)
  return directoryOfIndex + walkGraphShardName({buildId, tile})
}

const tiles = createWalkTiles({fileOrigin: ""})
const sourced = await tiles.ensureSource()
strictEqual(sourced.kind, SourceKind.ready)
const shardUrl = shardUrlOf({buildId: sourced.buildId, tile: WEST_TILE})

// A window ready: the fixture's index holds two tiles around the position.
const ready = await tiles.fetchWindow({position: POSITION, deadlineMs: DEADLINE_MS})
strictEqual(ready.kind, WindowKind.ready)
strictEqual(ready.loaded.size, WINDOW_TILE_COUNT, "the window's indexed tiles")
strictEqual(tiles.held().size, WINDOW_TILE_COUNT)

// The deadline wins the race against a tile held back; the fetch goes on and
// the tile is held when it arrives.
const slow = createWalkTiles({fileOrigin: ""})
await slow.ensureSource()
hold(shardUrl)
timers.length = 0
const racing = slow.fetchWindow({position: POSITION, deadlineMs: DEADLINE_MS})
await Promise.resolve()
const deadline = timers.find((timer) => timer.ms === DEADLINE_MS)
ok(deadline !== undefined, "the window set its deadline")
deadline.fire()
const expired = await racing
deepStrictEqual(expired, {kind: WindowKind.failed, reason: WindowFailure.timeout})
release(shardUrl)
const POLL_COUNT_MAX = 100
const POLL_MS = 5

for (let poll = 0; poll < POLL_COUNT_MAX; poll += 1) {
  if (slow.held().size > 0) {
    break
  }

  await sleep(POLL_MS)
}

ok(slow.held().size > 0, "a tile that arrives after the deadline is held")

// One fetch for a tile however many ask at once.
const shared = createWalkTiles({fileOrigin: ""})
await shared.ensureSource()
const before = countOf(shardUrl)
hold(shardUrl)
const first = shared.fetchTile(WEST_TILE)
const second = shared.fetchTile(WEST_TILE)
release(shardUrl)
await Promise.allSettled([first, second])
strictEqual(countOf(shardUrl) - before, 1, "two askers, one fetch")

// A failed tile is not fetched again until a window asks, which fetches it again.
const flaky = createWalkTiles({fileOrigin: ""})
await flaky.ensureSource()
refused.add(shardUrl)
await flaky.fetchTile(WEST_TILE)
const westKey = tileKey(WEST_TILE)
strictEqual(flaky.hasFailed(westKey), true)
const failedCount = countOf(shardUrl)
await flaky.fetchTile(WEST_TILE)
strictEqual(countOf(shardUrl), failedCount, "a failed tile is not fetched again by a bare ask")
const failedWindow = await flaky.fetchWindow({position: POSITION, deadlineMs: DEADLINE_MS})
deepStrictEqual(failedWindow, {kind: WindowKind.failed, reason: WindowFailure.tiles})
refused.delete(shardUrl)
const retried = await flaky.fetchWindow({position: POSITION, deadlineMs: DEADLINE_MS})
strictEqual(retried.kind, WindowKind.ready, "the next window fetches the failed tile again")

// Past the bound the oldest tile goes first.
const crowded = createWalkTiles({fileOrigin: ""})
await crowded.ensureSource()

for (let row = 0; row <= HELD_TILE_COUNT_MAX; row += 1) {
  await crowded.fetchTile({row, column: 0})
}

strictEqual(crowded.held().size, HELD_TILE_COUNT_MAX)
const oldestKey = tileKey({row: 0, column: 0})
const newestKey = tileKey({row: HELD_TILE_COUNT_MAX, column: 0})
strictEqual(crowded.held().has(oldestKey), false, "the oldest tile was dropped")
strictEqual(crowded.held().has(newestKey), true, "the newest tile is held")

// A window's tile is not the one dropped while the window waits: with the
// store full, the tiles of a window held back are fetched last and kept.
const pinned = createWalkTiles({fileOrigin: ""})
await pinned.ensureSource()

for (let row = 0; row < HELD_TILE_COUNT_MAX; row += 1) {
  await pinned.fetchTile({row, column: 0})
}

hold(shardUrl)
const waiting = pinned.fetchWindow({position: POSITION, deadlineMs: DEADLINE_MS})
await Promise.resolve()
await Promise.resolve()
release(shardUrl)
const kept = await waiting
strictEqual(kept.kind, WindowKind.ready, "a window over a full store keeps its own tiles")
strictEqual(kept.loaded.size, WINDOW_TILE_COUNT)

// The source is tried again only after SOURCE_RETRY_MS.
const retrying = createWalkTiles({fileOrigin: ""})
refused.add(MANIFEST_URL)
const failed = await retrying.ensureSource()
strictEqual(failed.kind, SourceKind.failed)
const manifestCount = countOf(MANIFEST_URL)
nowMs = SOURCE_RETRY_MS - 1
await retrying.ensureSource()
strictEqual(countOf(MANIFEST_URL), manifestCount, "no retry before the interval")
nowMs = SOURCE_RETRY_MS
refused.delete(MANIFEST_URL)
const again = await retrying.ensureSource()
strictEqual(again.kind, SourceKind.ready, "a retry after the interval")
strictEqual(countOf(MANIFEST_URL), manifestCount + 1)

console.log("walk tiles: every case passed")
