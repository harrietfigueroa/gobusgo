// Which shared vehicle tiles a map's view needs. Everything here is pure: it
// takes the view's bounds and an index's tiles and fetches nothing, so the
// hook asks for exactly the tiles in view that it does not already hold.
// The tiles are Web Mercator tiles of the index's zoom, numbered as
// `Gobusgo.Gbfs.VehicleTileSet` numbers them.

import {DEGREES_PER_HALF_TURN, DEGREES_PER_TURN, radians} from "./math/angles.js"
import {clamp} from "./math/interpolation.js"
import {tileKey} from "./shared_vehicle_format.js"

const HALVING_DIVISOR = 2
const TILE_BASE = 2

/** The most tiles one view asks for; a view that needs more shows none. */
export const VIEW_TILE_COUNT_MAX = 64

/** The kinds of the tiles a view needs. */
export const ViewKind = Object.freeze({tiles: "tiles", tooMany: "tooMany"})

/** The tile of zoom `zoom` that holds the position `lat`, `lon`. */
export function tileOf({lat, lon, zoom}) {
  const tileCount = TILE_BASE ** zoom
  const latRadians = radians(lat)
  const mercator = Math.log(Math.tan(latRadians) + 1 / Math.cos(latRadians))
  const x = Math.floor((lon + DEGREES_PER_HALF_TURN) / DEGREES_PER_TURN * tileCount)
  const y = Math.floor((1 - mercator / Math.PI) / HALVING_DIVISOR * tileCount)
  const indexMax = tileCount - 1
  return {x: clamp({value: x, min: 0, max: indexMax}), y: clamp({value: y, min: 0, max: indexMax})}
}

/**
 * The tiles of zoom `zoom` that the view `bounds`, its `west`, `south`,
 * `east`, and `north` in degrees, covers, as `ViewKind.tiles`, or
 * `ViewKind.tooMany` for a view that covers more than
 * `VIEW_TILE_COUNT_MAX`. A view across the antimeridian is not handled:
 * the shared vehicle systems are all far from it.
 */
export function tilesInView({bounds, zoom}) {
  const northWest = tileOf({lat: bounds.north, lon: bounds.west, zoom})
  const southEast = tileOf({lat: bounds.south, lon: bounds.east, zoom})
  const columnCount = southEast.x - northWest.x + 1
  const rowCount = southEast.y - northWest.y + 1
  const tileCount = columnCount * rowCount

  if (tileCount > VIEW_TILE_COUNT_MAX) {
    return {kind: ViewKind.tooMany, tileCount}
  }

  const tiles = []

  for (let x = northWest.x; x <= southEast.x; x += 1) {
    for (let y = northWest.y; y <= southEast.y; y += 1) {
      tiles.push({x, y})
    }
  }

  return {kind: ViewKind.tiles, tiles}
}

/**
 * The names of the files to fetch for the tiles `tiles` of a view, of the
 * tiles an index lists by key, `listed`, leaving out a tile the index does
 * not list, which holds no vehicle, and a file `isHeld` says is held.
 */
export function namesToFetch({tiles, listed, isHeld}) {
  const names = []

  for (const tile of tiles) {
    const entry = listed.get(tileKey(tile))
    const isWanted = entry !== undefined && !isHeld(entry.name)

    if (isWanted) {
      names.push(entry.name)
    }
  }

  return names
}
