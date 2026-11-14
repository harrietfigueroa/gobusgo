// The lines a journey's walks are drawn along, read on demand from the walk
// graph's shards. `request` names the walks wanted, `lines` gives the line of
// every walk that has one by `walkKey`, and `onWalks` runs when files that
// arrive after a request bring lines the page did not hold. The tiles a walk
// needs and the path along them are decided by the pure `planWalk`; each
// fetch it asks for runs here. A walk whose files are not held, fail to
// load, or hold no path between its ends has no line, and the page keeps
// the straight one. Rider positions are only ever arguments of the pure
// plan, so a fetch carries a tile's name and never a position.

import {assertCondition, unreachable} from "./core/assert.js"
import {tileKey, walkGraphShardName} from "./core/walk_graph_file.js"
import {WALK_LIMITS, WalkPathKind, planWalk} from "./core/walk_path.js"
import {walkKey} from "./core/trip_plan.js"
import {FetchKind, fetchWalkIndex, fetchWalkManifest, fetchWalkShard} from "./walk_graph_fetch.js"

/** The most walks one request names: a journey has a handful. */
export const REQUEST_WALK_COUNT_MAX = 16

/** The most decoded tiles held; the oldest is dropped past it. */
export const HELD_TILE_COUNT_MAX = 64

const SOURCE_RETRY_MS = 60 * 1000
const MANIFEST_PATH = "/api/walk-graph/manifest"
const PATH_SEPARATOR = "/"
const SourceKind = Object.freeze({idle: "idle", loading: "loading", ready: "ready", failed: "failed"})

// Keeps an error that no fetch outcome maps, a programmer error, a visible
// crash of the page instead of a silent rejection.
function surfaceError(error) {
  reportError(error)
}

function directoryOf(path) {
  return path.slice(0, path.lastIndexOf(PATH_SEPARATOR) + 1)
}

/**
 * A reader of walk lines from the files `fileOrigin` serves, the scheme and
 * host in front of each path, or "" for the page's own. `onWalks` runs after
 * a request, once files that arrived give lines for walks that had none.
 */
export function createWalkPathReader({fileOrigin, onWalks}) {
  let source = {kind: SourceKind.idle, failedAtMs: 0}
  const held = new Map()
  const inflight = new Set()
  const failed = new Set()
  let lines = new Map()
  let declined = new Set()
  let wanted = []
  let wantedKeys = ""
  let isDestroyed = false

  function keep({key, table}) {
    held.delete(key)
    held.set(key, table)

    while (held.size > HELD_TILE_COUNT_MAX) {
      const [oldest] = held.keys()
      held.delete(oldest)
    }
  }

  // Plans each wanted walk that has no line yet and starts the fetches the
  // plans ask for; the count of lines found.
  function evaluate() {
    if (source.kind !== SourceKind.ready) {
      return 0
    }

    let foundCount = 0

    for (const walk of wanted) {
      const key = walkKey(walk)

      const isFound = lines.has(key)
      const isDeclined = declined.has(key)
      const isSettled = isFound || isDeclined

      if (isSettled) {
        continue
      }

      const plan = planWalk({from: walk.from, to: walk.to, index: source.index.tileKeys, loaded: held, limits: WALK_LIMITS})

      switch (plan.kind) {
        case WalkPathKind.found:
          lines.set(key, plan.coordinates)
          foundCount += 1
          break
        case WalkPathKind.noPath:
          declined.add(key)
          break
        case WalkPathKind.notLoaded:
          for (const tile of plan.tiles) {
            startShard(tile).catch(surfaceError)
          }

          break
        default:
          unreachable(plan.kind, "walk path reader: a plan of unknown kind")
      }
    }

    return foundCount
  }

  function settled() {
    if (isDestroyed) {
      return
    }

    const foundCount = evaluate()

    if (foundCount > 0) {
      onWalks()
    }
  }

  async function startShard(tile) {
    const key = tileKey(tile)
    const isHeld = held.has(key)
    const isFetching = isHeld || inflight.has(key)
    const isBusy = isFetching || failed.has(key)

    if (isBusy) {
      return
    }

    inflight.add(key)
    const path = directoryOf(source.indexPath) + walkGraphShardName({buildId: source.buildId, tile})
    const outcome = await fetchWalkShard({origin: fileOrigin, path})
    inflight.delete(key)

    if (isDestroyed) {
      return
    }

    if (outcome.kind === FetchKind.fetched) {
      keep({key, table: outcome.table})
    } else {
      failed.add(key)
    }

    settled()
  }

  async function load() {
    source = {kind: SourceKind.loading, failedAtMs: 0}
    const manifest = await fetchWalkManifest({origin: fileOrigin, path: MANIFEST_PATH})

    if (isDestroyed) {
      return
    }

    if (manifest.kind !== FetchKind.fetched) {
      source = {kind: SourceKind.failed, failedAtMs: performance.now()}
      return
    }

    const {accepted} = manifest
    const index = await fetchWalkIndex({origin: fileOrigin, path: accepted.indexPath, byteSize: accepted.indexByteSize})

    if (isDestroyed) {
      return
    }

    if (index.kind !== FetchKind.fetched) {
      source = {kind: SourceKind.failed, failedAtMs: performance.now()}
      return
    }

    source = {kind: SourceKind.ready, failedAtMs: 0, index: index.table, indexPath: accepted.indexPath, buildId: index.table.buildId}
    settled()
  }

  function isSourceRetryDue() {
    const isFailed = source.kind === SourceKind.failed
    const failedForMs = performance.now() - source.failedAtMs
    return isFailed && failedForMs >= SOURCE_RETRY_MS
  }

  return {
    // Names the walks, each `{from, to}` in degrees, whose lines are wanted
    // in place of the last request's, and starts the fetches they need. A
    // line already held is in `lines` on return.
    request(walks) {
      assertCondition(walks.length <= REQUEST_WALK_COUNT_MAX, "walk path reader: a request names at most " + REQUEST_WALK_COUNT_MAX + " walks, not " + walks.length)
      const keys = Array.from(walks, walkKey).join("|")
      const isNewRequest = keys !== wantedKeys

      if (isNewRequest) {
        failed.clear()
        declined = new Set()
        lines = new Map()
      }

      wanted = walks
      wantedKeys = keys
      const isIdle = source.kind === SourceKind.idle

      const isLoadDue = isIdle || isSourceRetryDue()

      if (isLoadDue) {
        load().catch(surfaceError)
      }

      evaluate()
    },

    // Every line held, by `walkKey`.
    lines() {
      return lines
    },

    destroy() {
      isDestroyed = true
      wanted = []
    }
  }
}
