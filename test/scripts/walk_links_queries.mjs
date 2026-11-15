// The walk queries of the golden file, answered by the browser's core over
// the walk graph fixture's shards. The points are the fixture's crossings,
// its sidewalk, steps, island, and shard boundary, each also offset from the
// street, so the pairs of them cover a path, a detour, an island, an end off
// the graph, and ends too far apart.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {PackedOutcome} from "../../assets/js/core/packed_container.js"
import {UNITS_PER_DEGREE, decodeWalkGraphIndex, decodeWalkGraphShard, tileKey} from "../../assets/js/core/walk_graph_file.js"
import {NoPathReason, WALK_LIMITS, WalkPathKind, planWalk, walkTilesNeeded} from "../../assets/js/core/walk_path.js"

export const TOLERANCE_METERS = 0.1
const FIXTURE_DIRECTORY = fileURLToPath(new URL("../fixtures/walk_graph/v1/", import.meta.url))
const WEST_TILE_KEY = "4761_-8156"
const EAST_TILE_KEY = "4761_-8155"

// The fixture's streets, in units of the graph.
const NORTH = 4_761_450
const SOUTH = 4_761_300
const SIDEWALK_LAT = 4_761_380
const STEPS_LAT = 4_761_130
const ISLAND_LAT = 4_761_800
const OFF_GRAPH_LAT = 4_761_600
const FAR_NORTH_LAT = 4_763_450
const WEST_COLUMN = -12_233_600
const MIDDLE_COLUMN = -12_233_400
const EAST_COLUMN = -12_233_200
const BEYOND_COLUMN = -12_232_400
const FAR_COLUMN = -12_231_800
const OFFSET_NORTH_UNITS = 10
const OFFSET_SOUTH_UNITS = -12
const OFFSET_EAST_UNITS = 8
const OFFSET_WEST_COLUMN_UNITS = 20
const OFFSET_MIDDLE_COLUMN_UNITS = 15
const OFFSET_FAR_COLUMN_UNITS = -30

// Two shards of the golden file's own, in tiles of the index the fixture
// shards leave empty: tile (-3, -5) holds two parallel streets 20 m north
// and south of a pair of ends, the northern one with a bump between them, so
// the street a tie picks changes the length, and the start of a long street
// that runs on into tile (-3, -4). Each piece is `[class, [latitude,
// longitude], ...]` in units.
const EXTRA_STREET_CLASS = 4
const TIE_NORTH_LAT = -2_482
const TIE_BUMP_LAT = -2_382
const TIE_SOUTH_LAT = -2_518
const TIE_WEST_COLUMN = -7_100
const TIE_FIRST_COLUMN = -7_000
const TIE_SECOND_COLUMN = -6_800
const TIE_EAST_COLUMN = -6_700
const TIE_ENDS_LAT = -2_500
const LONG_LAT = -2_560
const LONG_START_COLUMN = -6_400
const LONG_TILE_COLUMN = -6_000
const LONG_END_COLUMN = -5_000
const LONG_NEAR_LAT = -2_540
const LONG_NEAR_COLUMN = -6_300
const LONG_FAR_LAT = -2_300
const LONG_STOP_COLUMN = -5_200
const EXTRA_SHARDS = Object.freeze([
  {
    tile: [-3, -5],
    pieces: [
      [EXTRA_STREET_CLASS, [TIE_NORTH_LAT, TIE_WEST_COLUMN], [TIE_NORTH_LAT, TIE_FIRST_COLUMN], [TIE_BUMP_LAT, TIE_FIRST_COLUMN], [TIE_BUMP_LAT, TIE_SECOND_COLUMN], [TIE_NORTH_LAT, TIE_SECOND_COLUMN], [TIE_NORTH_LAT, TIE_EAST_COLUMN]],
      [EXTRA_STREET_CLASS, [TIE_SOUTH_LAT, TIE_WEST_COLUMN], [TIE_SOUTH_LAT, TIE_EAST_COLUMN]],
      [EXTRA_STREET_CLASS, [LONG_LAT, LONG_START_COLUMN], [LONG_LAT, LONG_TILE_COLUMN]]
    ]
  },
  {tile: [-3, -4], pieces: [[EXTRA_STREET_CLASS, [LONG_LAT, LONG_TILE_COLUMN], [LONG_LAT, LONG_END_COLUMN]]]}
])

// The points of the extra shards, each `[name, latitude, longitude]` in
// units.
const EXTRA_POINTS = Object.freeze([
  ["tie first", TIE_ENDS_LAT, TIE_FIRST_COLUMN],
  ["tie second", TIE_ENDS_LAT, TIE_SECOND_COLUMN],
  ["long start", LONG_LAT, LONG_START_COLUMN],
  ["long stop", LONG_LAT, LONG_STOP_COLUMN],
  ["long near", LONG_NEAR_LAT, LONG_NEAR_COLUMN],
  ["long off the graph", LONG_FAR_LAT, LONG_NEAR_COLUMN]
])

// The points, each `[name, latitude, longitude]` in units.
const POINTS = Object.freeze([
  ["north west", NORTH, WEST_COLUMN],
  ["north middle", NORTH, MIDDLE_COLUMN],
  ["north east", NORTH, EAST_COLUMN],
  ["south west", SOUTH, WEST_COLUMN],
  ["south middle", SOUTH, MIDDLE_COLUMN],
  ["south east", SOUTH, EAST_COLUMN],
  ["sidewalk middle", SIDEWALK_LAT, WEST_COLUMN],
  ["crossing middle", SIDEWALK_LAT, EAST_COLUMN],
  ["island west", ISLAND_LAT, WEST_COLUMN],
  ["island middle", ISLAND_LAT, MIDDLE_COLUMN],
  ["steps", STEPS_LAT, WEST_COLUMN],
  ["east shard start", SOUTH, BEYOND_COLUMN],
  ["east shard end", SOUTH, FAR_COLUMN],
  ["north west off street", NORTH + OFFSET_NORTH_UNITS, WEST_COLUMN + OFFSET_WEST_COLUMN_UNITS],
  ["south middle off street", SOUTH + OFFSET_SOUTH_UNITS, MIDDLE_COLUMN + OFFSET_MIDDLE_COLUMN_UNITS],
  ["east shard off street", SOUTH + OFFSET_EAST_UNITS, FAR_COLUMN + OFFSET_FAR_COLUMN_UNITS],
  ["off the graph", OFF_GRAPH_LAT, MIDDLE_COLUMN],
  ["far north", FAR_NORTH_LAT, WEST_COLUMN]
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

function rowAndColumn(tile) {
  return [tile.row, tile.column]
}

function answerOf({from, to, shardsByKey, index}) {
  const needed = walkTilesNeeded({from, to, index, limits: WALK_LIMITS})
  const tiles = Array.from(needed.tiles ?? [], rowAndColumn)
  const planned = planWalk({from, to, index, loaded: shardsByKey, limits: WALK_LIMITS})

  if (planned.kind === WalkPathKind.found) {
    return {tiles, kind: "found", meters: planned.meters}
  }

  if (planned.kind === WalkPathKind.noPath && planned.reason === NoPathReason.tooFar) {
    return {tiles, kind: "tooFar"}
  }

  if (planned.kind === WalkPathKind.notLoaded) {
    throw new Error("a golden pair reads a tile the fixture lacks: " + JSON.stringify(planned.tiles))
  }

  return {tiles, kind: "noPath", reason: planned.reason}
}

// The decoded table of the pieces of an extra shard.
function tableOfPieces(pieces) {
  const classes = []
  const pieceStarts = [0]
  const points = []

  for (const [pieceClass, ...positions] of pieces) {
    classes.push(pieceClass)
    pieceStarts.push(pieceStarts[pieceStarts.length - 1] + positions.length)

    for (const [latUnits, lonUnits] of positions) {
      points.push(latUnits, lonUnits)
    }
  }

  return {pieceCount: classes.length, classes: Uint8Array.from(classes), pieceStarts: Uint32Array.from(pieceStarts), points: Int32Array.from(points)}
}

function extraShardRecord({tile, pieces}) {
  const records = Array.from(pieces, ([pieceClass, ...positions]) => ({class: pieceClass, points: positions}))
  return {tile, pieces: records}
}

function pairsOf({points, shardsByKey, index}) {
  const queries = []

  for (let first = 0; first < points.length; first += 1) {
    for (let second = first + 1; second < points.length; second += 1) {
      const from = degrees(points[first][1], points[first][2])
      const to = degrees(points[second][1], points[second][2])
      const answer = answerOf({from, to, shardsByKey, index})
      queries.push({name: points[first][0] + " to " + points[second][0], from, to, ...answer})
    }
  }

  return queries
}

/** The index's tile keys and the answer to each pair of points, as the golden file holds them. */
export function goldenQueries() {
  const indexTable = decodeWalkGraphIndex(read("index.bin")).table
  const shardsByKey = new Map([[WEST_TILE_KEY, decodedShard("shard-west.bin")], [EAST_TILE_KEY, decodedShard("shard-east.bin")]])
  for (const shard of EXTRA_SHARDS) {
    shardsByKey.set(tileKey({row: shard.tile[0], column: shard.tile[1]}), tableOfPieces(shard.pieces))
  }

  const index = indexTable.tileKeys
  const queries = [...pairsOf({points: POINTS, shardsByKey, index}), ...pairsOf({points: EXTRA_POINTS, shardsByKey, index})]

  return {
    limits: WALK_LIMITS,
    indexTileKeys: Array.from(indexTable.tileKeys).sort(),
    shardTileKeys: [WEST_TILE_KEY, EAST_TILE_KEY],
    extraShards: Array.from(EXTRA_SHARDS, extraShardRecord),
    queries
  }
}
