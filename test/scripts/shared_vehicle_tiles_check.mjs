// Checks which shared vehicle tiles a map's view needs, as pure functions of
// the view's bounds and an index's tiles written out by hand. The tile
// numbers of Westlake and the University District are the ones
// `Gobusgo.Gbfs.VehicleTileSetTest` asserts, so the server and the browser
// number tiles alike. Run it with
// `node test/scripts/shared_vehicle_tiles_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {VIEW_TILE_COUNT_MAX, ViewKind, namesToFetch, tileOf, tilesInView} from "../../assets/js/shared_vehicle_tiles.js"

const TILE_ZOOM = 14
const WESTLAKE = {x: 2624, y: 5721}
const UNIVERSITY_DISTRICT = {x: 2625, y: 5718}
const MADISON_PARK = {x: 2626, y: 5720}
const TILE_BASE = 2
const LAST_TILE = TILE_BASE ** TILE_ZOOM - 1
const WESTLAKE_NAME = "tile-14-2624-5721-a.bin.gz"
const UNIVERSITY_DISTRICT_NAME = "tile-14-2625-5718-b.bin.gz"

const positionCases = [
  {name: "Westlake", lat: 47.6114, lon: -122.337, tile: WESTLAKE},
  {name: "the University District", lat: 47.6614, lon: -122.313, tile: UNIVERSITY_DISTRICT},
  {name: "Madison Park", lat: 47.635, lon: -122.278, tile: MADISON_PARK},
  {name: "past the north edge of the projection", lat: 89.9, lon: 179.99, tile: {x: LAST_TILE, y: 0}}
]

for (const positionCase of positionCases) {
  deepStrictEqual(tileOf({lat: positionCase.lat, lon: positionCase.lon, zoom: TILE_ZOOM}), positionCase.tile, positionCase.name)
}

// A phone's view of downtown at zoom 15 inside the Westlake tile, which
// runs from -122.34375 to -122.32178 and from 47.60616 to 47.62098.
const downtown = {west: -122.34, south: 47.607, east: -122.33, north: 47.62}
deepStrictEqual(tilesInView({bounds: downtown, zoom: TILE_ZOOM}), {kind: ViewKind.tiles, tiles: [WESTLAKE]}, "downtown")

// A view from Westlake to the University District spans two columns of four
// rows, in x then y order.
const northward = {west: -122.34, south: 47.61, east: -122.313, north: 47.6614}
const northwardTiles = []

for (let x = WESTLAKE.x; x <= UNIVERSITY_DISTRICT.x; x += 1) {
  for (let y = UNIVERSITY_DISTRICT.y; y <= WESTLAKE.y; y += 1) {
    northwardTiles.push({x, y})
  }
}

deepStrictEqual(tilesInView({bounds: northward, zoom: TILE_ZOOM}), {kind: ViewKind.tiles, tiles: northwardTiles}, "northward")

// The whole region is past the bound.
const region = {west: -123, south: 47, east: -121.5, north: 48.3}
const regionView = tilesInView({bounds: region, zoom: TILE_ZOOM})
deepStrictEqual(regionView.kind, ViewKind.tooMany, "a region")
deepStrictEqual(regionView.tileCount > VIEW_TILE_COUNT_MAX, true, "a region's count")

const listed = new Map([
  ["2624/5721", {...WESTLAKE, count: 4, name: WESTLAKE_NAME}],
  ["2625/5718", {...UNIVERSITY_DISTRICT, count: 1, name: UNIVERSITY_DISTRICT_NAME}]
])

function isHeldNone() {
  return false
}

function isHeldWestlake(name) {
  return name === WESTLAKE_NAME
}

const viewTiles = [WESTLAKE, UNIVERSITY_DISTRICT, MADISON_PARK]

deepStrictEqual(
  namesToFetch({tiles: viewTiles, listed, isHeld: isHeldNone}),
  [WESTLAKE_NAME, UNIVERSITY_DISTRICT_NAME],
  "every listed tile in view, and no unlisted one"
)

deepStrictEqual(namesToFetch({tiles: viewTiles, listed, isHeld: isHeldWestlake}), [UNIVERSITY_DISTRICT_NAME], "only the tiles not held")

console.log("shared vehicle tiles: every case matches")
