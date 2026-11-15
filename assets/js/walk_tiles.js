// The walk graph's tiles a page holds, fetched on demand, which every reader
// of the graph on the page shares, so a tile one reader fetched is held for
// the next. The manifest and the index are fetched once per page, and each
// shard once, whoever asks. A fetch names a tile and never a position: what a
// request reveals is decided by which tiles a caller names.

import {assertCondition} from "./core/assert.js"
import {tileKey, walkGraphShardName} from "./core/walk_graph_file.js"
import {WALK_LIMITS, walkWindowTiles} from "./core/walk_path.js"
import {FetchKind, fetchWalkIndex, fetchWalkManifest, fetchWalkShard} from "./walk_graph_fetch.js"

/** The most walks one request of the drawn lines names: a journey has a handful. */
export const REQUEST_WALK_COUNT_MAX = 16

/** The most decoded tiles held; the oldest is dropped past it. */
export const HELD_TILE_COUNT_MAX = REQUEST_WALK_COUNT_MAX * WALK_LIMITS.tileCountMax

/** The kinds of what a page holds of the walk graph's source, its manifest and index. */
export const SourceKind = Object.freeze({idle: "idle", loading: "loading", ready: "ready", failed: "failed"})

/** The kinds of the answer to a window of tiles. */
export const WindowKind = Object.freeze({ready: "ready", failed: "failed"})

/** Why a window of tiles is not ready. */
export const WindowFailure = Object.freeze({source: "source", tiles: "tiles", timeout: "timeout"})

const SOURCE_RETRY_MS = 60 * 1000
const MANIFEST_PATH = "/api/walk-graph/manifest"
const PATH_SEPARATOR = "/"

function directoryOf(path) {
  return path.slice(0, path.lastIndexOf(PATH_SEPARATOR) + 1)
}

// Resolves on the failure a window gets once `signal` aborts.
function expiryOf(signal) {
  return new Promise(function awaitExpiry(resolve) {
    function resolveExpired() {
      resolve({kind: WindowKind.failed, reason: WindowFailure.timeout})
    }

    signal.addEventListener("abort", resolveExpired, {once: true})
  })
}

/**
 * The walk graph's tiles as the files `fileOrigin` serves them, the scheme
 * and host in front of each path, or "" for the page's own. `held()` is the
 * Map of decoded tiles by `tileKey`, which a caller reads and never writes.
 */
export function createWalkTiles({fileOrigin}) {
  let source = {kind: SourceKind.idle, failedAtMs: 0}
  let sourcePending = null
  const held = new Map()
  const inflight = new Map()
  const failed = new Set()
  const pinned = new Set()

  function keep({key, table}) {
    held.delete(key)
    held.set(key, table)

    // A tile a window is waiting for is never the one dropped; the oldest
    // tile no window holds goes first.
    for (const oldest of held.keys()) {
      if (held.size <= HELD_TILE_COUNT_MAX) {
        break
      }

      if (!pinned.has(oldest)) {
        held.delete(oldest)
      }
    }
  }

  async function loadSource() {
    source = {kind: SourceKind.loading, failedAtMs: 0}
    const manifest = await fetchWalkManifest({origin: fileOrigin, path: MANIFEST_PATH})

    if (manifest.kind !== FetchKind.fetched) {
      source = {kind: SourceKind.failed, failedAtMs: performance.now()}
      return source
    }

    const {accepted} = manifest
    const index = await fetchWalkIndex({origin: fileOrigin, path: accepted.indexPath, byteSize: accepted.indexByteSize})

    if (index.kind !== FetchKind.fetched) {
      source = {kind: SourceKind.failed, failedAtMs: performance.now()}
      return source
    }

    source = {kind: SourceKind.ready, failedAtMs: 0, index: index.table, indexPath: accepted.indexPath, buildId: index.table.buildId}
    return source
  }

  function isSourceRetryDue() {
    const isFailed = source.kind === SourceKind.failed
    const failedForMs = performance.now() - source.failedAtMs
    return isFailed && failedForMs >= SOURCE_RETRY_MS
  }

  async function shardOf(tile) {
    const key = tileKey(tile)
    const path = directoryOf(source.indexPath) + walkGraphShardName({buildId: source.buildId, tile})
    const outcome = await fetchWalkShard({origin: fileOrigin, path})
    inflight.delete(key)

    if (outcome.kind === FetchKind.fetched) {
      keep({key, table: outcome.table})
    } else {
      failed.add(key)
    }
  }

  // The tiles of the 3 by 3 window around `position` that the index holds,
  // fetched where the page does not hold them, or the failure.
  async function windowOf(position) {
    const sourced = await tiles.ensureSource()

    if (sourced.kind !== SourceKind.ready) {
      return {kind: WindowKind.failed, reason: WindowFailure.source}
    }

    const needed = walkWindowTiles({position, index: sourced.index.tileKeys})
    const pending = []
    const keys = Array.from(needed, tileKey)

    for (const key of keys) {
      pinned.add(key)
    }

    try {
      for (const tile of needed) {
        failed.delete(tileKey(tile))
        pending.push(tiles.fetchTile(tile))
      }

      await Promise.allSettled(pending)
      return windowHeld({keys, index: sourced.index.tileKeys})
    } finally {
      for (const key of keys) {
        pinned.delete(key)
      }
    }
  }

  // The window's tiles as a Map of its own, each marked recently used, or the failure.
  function windowHeld({keys, index}) {
    const loaded = new Map()

    for (const key of keys) {
      const table = held.get(key)

      if (table === undefined) {
        return {kind: WindowKind.failed, reason: WindowFailure.tiles}
      }

      held.delete(key)
      held.set(key, table)
      loaded.set(key, table)
    }

    return {kind: WindowKind.ready, index, loaded}
  }

  const tiles = {
    /** The state of the source: its kind, and once ready its `index` table, `indexPath`, and `buildId`. */
    source() {
      return source
    },

    /**
     * The source once its manifest and index are fetched: ready, or failed,
     * which a later call tries again after SOURCE_RETRY_MS.
     */
    async ensureSource() {
      const isIdle = source.kind === SourceKind.idle
      const isLoadDue = isIdle || isSourceRetryDue()

      if (isLoadDue) {
        sourcePending = loadSource()
      }

      if (source.kind === SourceKind.loading) {
        return await sourcePending
      }

      return source
    },

    /** The decoded tiles held, by `tileKey`. */
    held() {
      return held
    },

    /** Whether fetching the tile `key` failed and has not been asked for again. */
    hasFailed(key) {
      return failed.has(key)
    },

    /** Forgets the failed tiles, so each is fetched again when asked for. */
    clearFailed() {
      failed.clear()
    },

    /** Marks the tile `key` the most recently used, where it is held. */
    touch(key) {
      const table = held.get(key)

      if (table !== undefined) {
        held.delete(key)
        held.set(key, table)
      }
    },

    /**
     * Fetches `tile`, `{row, column}`, once however many ask, unless it is
     * held or has failed, and settles when the page holds it or has marked it
     * failed. The source is ready.
     */
    async fetchTile(tile) {
      assertCondition(source.kind === SourceKind.ready, "walk tiles: a tile was asked for before the source was ready")
      const key = tileKey(tile)
      const isHeld = held.has(key)
      const isBusy = isHeld || failed.has(key)

      if (isBusy) {
        return
      }

      const pending = inflight.get(key)

      if (pending !== undefined) {
        await pending
        return
      }

      inflight.set(key, shardOf(tile))
      await inflight.get(key)
    },

    /**
     * The tiles of the 3 by 3 window around `position`, `{lat, lon}` in
     * degrees, fetched within `deadlineMs`: `{kind: WindowKind.ready, index,
     * loaded}`, `index` the Set of tile keys the graph holds and `loaded`
     * the window's decoded tiles by `tileKey`, a Map of its own; or
     * `{kind: WindowKind.failed, reason}`, a WindowFailure. Tiles that fail
     * are fetched again by the next call. A fetch past the deadline goes on
     * and its tile is held when it arrives.
     */
    async fetchWindow({position, deadlineMs}) {
      const signal = AbortSignal.timeout(deadlineMs)
      const expiry = expiryOf(signal)
      return await Promise.race([windowOf(position), expiry])
    }
  }

  return tiles
}
