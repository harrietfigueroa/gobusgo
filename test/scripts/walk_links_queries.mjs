// The walk queries of the shared golden fixture test/fixtures/walk_links/v1/,
// answered by the browser's core over the shards of test/fixtures/walk_graph/v1/.
// The points are the fixture's crossings, its sidewalk, steps, island, and
// shard boundary, each also offset from the street, so every pair of them
// covers a path, a detour, an island, an end off the graph, and ends too far
// apart. The Elixir search reads the same file and must agree within
// TOLERANCE_METERS.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {PackedOutcome} from "../../assets/js/core/packed_container.js"
import {UNITS_PER_DEGREE, decodeWalkGraphIndex, decodeWalkGraphShard, tileKey} from "../../assets/js/core/walk_graph_file.js"
import {WALK_LIMITS, WalkPathKind, findWalkPath, walkTilesNeeded} from "../../assets/js/core/walk_path.js"

export const TOLERANCE_METERS = 0.1
const FIXTURE_DIRECTORY = fileURLToPath(new URL("../fixtures/walk_graph/v1/", import.meta.url))
const WEST_TILE_KEY = "4761_-8156"
const EAST_TILE_KEY = "4761_-8155"

// The points, in units of the graph: [name, latitude, longitude].
const POINTS = Object.freeze([
  ["north west", 4_761_450, -12_233_600],
  ["north middle", 4_761_450, -12_233_400],
  ["north east", 4_761_450, -12_233_200],
  ["south west", 4_761_300, -12_233_600],
  ["south middle", 4_761_300, -12_233_400],
  ["south east", 4_761_300, -12_233_200],
  ["sidewalk middle", 4_761_380, -12_233_600],
  ["crossing middle", 4_761_380, -12_233_200],
  ["island west", 4_761_800, -12_233_600],
  ["island middle", 4_761_800, -12_233_400],
  ["steps", 4_761_130, -12_233_600],
  ["east shard start", 4_761_300, -12_232_400],
  ["east shard end", 4_761_300, -12_231_800],
  ["north west off street", 4_761_460, -12_233_580],
  ["south middle off street", 4_761_288, -12_233_385],
  ["east shard off street", 4_761_308, -12_231_830],
  ["off the graph", 4_761_600, -12_233_400],
  ["far north", 4_763_450, -12_233_600]
])

function read(name) {
  return new Uint8Array(readFileSync(FIXTURE_DIRECTORY + name))
}

function decodedShard(name) {
  const decoded = decodeWalkGraphShard(read(name))

  if (decoded.kind !== PackedOutcome.decoded) {
    throw new Error("the fixture shard " + name + " is refused: " + decoded.reason)
  }

  return decoded.table
}

function degrees(latUnits, lonUnits) {
  return {lat: latUnits / UNITS_PER_DEGREE, lon: lonUnits / UNITS_PER_DEGREE}
}

function answerOf({from, to, shardsByKey, index}) {
  const needed = walkTilesNeeded({from, to, index, limits: WALK_LIMITS})

  if (needed.kind !== "tiles") {
    return {tiles: [], kind: "tooFar"}
  }

  const shards = []

  for (const tile of needed.tiles) {
    const shard = shardsByKey.get(tileKey(tile))

    if (shard !== undefined) {
      shards.push(shard)
    }
  }

  const tiles = Array.from(needed.tiles, (tile) => [tile.row, tile.column])
  const found = findWalkPath({from, to, shards, limits: WALK_LIMITS})

  if (found.kind === WalkPathKind.found) {
    return {tiles, kind: "found", meters: found.meters}
  }

  return {tiles, kind: "noPath", reason: found.reason}
}

/** The index's tile keys and the answer to each pair of points, as the golden file holds them. */
export function goldenQueries() {
  const indexTable = decodeWalkGraphIndex(read("index.bin")).table
  const shardsByKey = new Map([[WEST_TILE_KEY, decodedShard("shard-west.bin")], [EAST_TILE_KEY, decodedShard("shard-east.bin")]])
  const queries = []

  for (let first = 0; first < POINTS.length; first += 1) {
    for (let second = first + 1; second < POINTS.length; second += 1) {
      const from = degrees(POINTS[first][1], POINTS[first][2])
      const to = degrees(POINTS[second][1], POINTS[second][2])
      const answer = answerOf({from, to, shardsByKey, index: indexTable.tileKeys})
      queries.push({name: POINTS[first][0] + " to " + POINTS[second][0], from, to, ...answer})
    }
  }

  return {
    limits: WALK_LIMITS,
    indexTileKeys: Array.from(indexTable.tileKeys).sort(),
    shardTileKeys: [WEST_TILE_KEY, EAST_TILE_KEY],
    queries
  }
}
