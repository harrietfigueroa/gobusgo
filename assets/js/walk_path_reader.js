// The lines a journey's walks are drawn along, read on demand from the walk
// graph's shards. `request` names the walks wanted, `lines` gives the line of
// every walk that has one by `walkKey`, and `onWalks` runs when files that
// arrive after a request bring lines the page did not hold. The tiles a walk
// needs and the path along them are decided by the pure `planWalk`; each
// fetch it asks for runs in `walkTiles`, the tile store the page's planning
// of its walks shares. A walk whose files are not held, fail to load, or hold
// no path between its ends has no line, and the page keeps the straight one.
// Rider positions are only ever arguments of the pure plan, so a fetch
// carries a tile's name and never a position.

import {assertCondition, unreachable} from "#core/assert.js"
import {tileKey} from "#core/walk_graph_file.js"
import {WALK_LIMITS, WalkPathKind, planWalk, walkTilesNeeded} from "#core/walk_path.js"
import {walkKey} from "#core/trip_plan.js"
import {HELD_TILE_COUNT_MAX, REQUEST_WALK_COUNT_MAX, SourceKind} from "./walk_tiles.js"

// Keeps an error that no fetch outcome maps, a programmer error, a visible
// crash of the page instead of a silent rejection.
function surfaceError(error) {
  reportError(error)
}

/**
 * A reader of walk lines over `walkTiles`, a tile store of `createWalkTiles`.
 * `onWalks` runs after a request, once files that arrived give lines for
 * walks that had none.
 */
export function createWalkPathReader({walkTiles, onWalks}) {
  let lines = new Map()
  let declined = new Set()
  let wanted = []
  let wantedKeys = ""
  let isDestroyed = false

  // Marks the tiles a walk reads as the most recently used, so the oldest
  // tiles of earlier requests are the ones dropped.
  function touchTiles(walk) {
    const needed = walkTilesNeeded({from: walk.from, to: walk.to, index: walkTiles.source().index.tileKeys, limits: WALK_LIMITS})

    if (needed.kind !== "tiles") {
      return
    }

    for (const tile of needed.tiles) {
      walkTiles.touch(tileKey(tile))
    }
  }

  // Plans each wanted walk that has no line yet and starts the fetches the
  // plans ask for; the count of lines found.
  function evaluate() {
    const source = walkTiles.source()

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

      const plan = planWalk({from: walk.from, to: walk.to, index: source.index.tileKeys, loaded: walkTiles.held(), limits: WALK_LIMITS})
      touchTiles(walk)

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

  // Fetches `tile` unless the page holds it or it failed, and plans the
  // walks again once it settles. A failed tile is not fetched again until
  // the walks asked for change, so a plan that finds it missing stops here.
  async function startShard(tile) {
    const key = tileKey(tile)
    const isHeld = walkTiles.held().has(key)
    const isBusy = isHeld || walkTiles.hasFailed(key)

    if (isBusy) {
      return
    }

    await walkTiles.fetchTile(tile)
    settled()
  }

  async function loadSource() {
    await walkTiles.ensureSource()
    settled()
  }

  return {
    // Names the walks, each `{from, to}` in degrees, whose lines are wanted
    // in place of the last request's, and starts the fetches they need. A
    // line already held is in `lines` on return.
    request(walks) {
      assertCondition(walks.length <= REQUEST_WALK_COUNT_MAX, "walk path reader: a request names at most " + REQUEST_WALK_COUNT_MAX + " walks, not " + walks.length)
      const tilesNeededMax = walks.length * WALK_LIMITS.tileCountMax
      assertCondition(tilesNeededMax <= HELD_TILE_COUNT_MAX, "walk path reader: a request reads at most " + tilesNeededMax + " tiles and the page holds " + HELD_TILE_COUNT_MAX)
      const keys = Array.from(walks, walkKey).join("|")
      const isNewRequest = keys !== wantedKeys

      if (isNewRequest) {
        walkTiles.clearFailed()
        declined = new Set()
        lines = new Map()
      }

      wanted = walks
      wantedKeys = keys
      const isReady = walkTiles.source().kind === SourceKind.ready

      if (!isReady) {
        loadSource().catch(surfaceError)
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
