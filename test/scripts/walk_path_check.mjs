// Checks the walk graph in the browser's core: the decoders against the shared
// fixtures of test/fixtures/walk_graph/v1/ (a shard and an index, expanded and
// as gzip streams) and each refusal as a value, then the walk path over the
// fixture's two shards: the path around a missing link, a path across the
// boundary of two shards, both ends on one piece, and the answers where
// there is no path (an island, an end past the snap bound, a search past its
// cap, ends too far apart, no shard at all) or the tiles are not loaded. A
// random grid compares the search's length with a Dijkstra search over the
// same grid. Run it with `node test/scripts/walk_path_check.mjs`; it exits
// non-zero on the first result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual, ok, strictEqual} from "node:assert/strict"
import {PackedKind, PackedOutcome, PackedRefusal, KINDS} from "../../assets/js/core/packed_container.js"
import {metersPerDegreeLongitude, METERS_PER_DEGREE} from "../../assets/js/core/math/geodesy.js"
import {
  ManifestKind,
  ManifestRefusal,
  TILE_LAT_UNITS,
  TILE_LON_UNITS,
  UNITS_PER_DEGREE,
  WalkGraphRefusal,
  acceptWalkManifest,
  decodeWalkGraphIndex,
  decodeWalkGraphShard,
  tileKey,
  tileOf,
  walkGraphShardName
} from "../../assets/js/core/walk_graph_file.js"
import {NoPathReason, WALK_LIMITS, WalkPathKind, findWalkPath, planWalk, walkTilesNeeded} from "../../assets/js/core/walk_path.js"
import {expandStream} from "../../assets/js/packed_stream.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/walk_graph/v1/", import.meta.url))
const BUILD_ID = "0123456789abcdef"
const SHARD_CLASS_OFFSET = 28
const SHARD_COUNT_OFFSET = 41
const INDEX_BUILD_ID_OFFSET = 25
const INDEX_FIRST_LENGTH_OFFSET = 77
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const SECOND_VERSION = 2
const BAD_CLASS = 5
const ONE_POSITION = 1
const THREE_POSITIONS = 3
const UPPER_G = 0x47
const EXPANDED_BYTES_MAX = 1024 * 1024
const METERS_TOLERANCE = 0.6
const DEGREE_TOLERANCE = 1e-7
const INDEX_BYTE_SIZE = 3318
const KIND_VERSION = 1
const MIDDLE_LAT_UNITS = 4_761_375
const WINDOW_RADIUS = 1
const WINDOW_TILE_COUNT = 9
const ISLAND_LAT_UNITS = 20
const ISLAND_FIRST_UNITS = 100
const ISLAND_LAST_UNITS = 300
const MAIN_SPAN_UNITS = 400
const FROM_OFFSET_UNITS = 50
const TO_OFFSET_UNITS = 200
const TO_LAT_UNITS = 12
const LOOP_SIDE_UNITS = 100
const EAST_LAST_DELTA_OFFSET_FROM_END = 2
const OVERLONG_ZERO_FIRST_BYTE = 0x80
const ZERO_DELTA_BYTES = [OVERLONG_ZERO_FIRST_BYTE, 0]
const EXPECTED_TILE_LAT_UNITS = 1_000
const EXPECTED_TILE_LON_UNITS = 1_500

// The fixture's streets, in units of the graph: two rows and four columns.
const NORTH = 4_761_450
const SOUTH = 4_761_300
const WEST_COLUMN = -12_233_600
const FAR_ISLAND_LAT = 4_761_800
const OFF_GRAPH_LAT = 4_761_600
const FAR_NORTH_LAT = 4_763_450
const SHARED_LAT_DEGREES = 47.613
const SHARED_LON_DEGREES = -122.324
const SIDEWALK_MIDDLE_LAT_DEGREES = 47.6138
const SIDEWALK_MIDDLE_LON_DEGREES = -122.336
const DETOUR_LON_UNITS = 100
const DETOUR_ROW_UNITS = 150
const NEAR_WEST = WEST_COLUMN + DETOUR_LON_UNITS
const NEAR_MIDDLE_EAST = -12_233_300
const MIDDLE_EAST_SPAN_UNITS = 1_300
const FAR_EAST_COLUMN = -12_232_000
const FAR_EAST_TILE_COLUMN = -12_231_000
const ONE_PIECE_FIRST = -12_233_550
const ONE_PIECE_LAST = -12_233_450
const ONE_PIECE_SPAN_UNITS = 100
const MIDDLE_COLUMN = -12_233_400
const WEST_TILE = {row: 4761, column: -8156}
const EAST_TILE = {row: 4761, column: -8155}
const TRIAL_KIND_COUNT_MIN = 10
const RANDOM_TRIAL_COUNT = 150
const GRID_SIZE = 6
const GRID_COLUMN_STEP_UNITS = 200
const GRID_ROW_STEP_UNITS = 150
const GRID_ORIGIN_LAT_UNITS = 4_761_000
const GRID_ORIGIN_LON_UNITS = -12_234_000
const LINEAR_CONGRUENTIAL_MULTIPLIER = 1_664_525
const LINEAR_CONGRUENTIAL_INCREMENT = 1_013_904_223
const LINEAR_CONGRUENTIAL_MODULUS = 4_294_967_296
const OMIT_PERCENT = 45
const PERCENT = 100
const HALF = 2
const GRID_STEPS = [[0, 1], [1, 0]]
const CAP_VISITED = 1
const CAP_EDGES = 1
const CAP_TILES = 1
const GRID_SEED = 7

function read(name) {
  return new Uint8Array(readFileSync(fixtureDirectory + name))
}

function degrees(latUnits, lonUnits) {
  return {lat: latUnits / UNITS_PER_DEGREE, lon: lonUnits / UNITS_PER_DEGREE}
}

function decodedShard(name) {
  const decoded = decodeWalkGraphShard(read(name))
  strictEqual(decoded.kind, PackedOutcome.decoded, name)
  return decoded.table
}

function refusalOf(decoded) {
  strictEqual(decoded.kind, PackedOutcome.refused)
  return decoded.reason
}

function shardRefusal(bytes) {
  return refusalOf(decodeWalkGraphShard(bytes))
}

function indexRefusal(bytes) {
  return refusalOf(decodeWalkGraphIndex(bytes))
}

function withByte({bytes, offset, value}) {
  const copy = new Uint8Array(bytes)
  copy[offset] = value
  return copy
}

function tableOfLines(lines) {
  const points = []
  const pieceStarts = [0]

  for (const line of lines) {
    for (const [latUnits, lonUnits] of line) {
      points.push(latUnits, lonUnits)
    }

    pieceStarts.push(pieceStarts[pieceStarts.length - 1] + line.length)
  }

  return {pieceCount: lines.length, classes: new Uint8Array(lines.length), pieceStarts: Uint32Array.from(pieceStarts), points: Int32Array.from(points)}
}

function isBeyond(tile) {
  return function isTile(other) {
    return other.row === tile.row && other.column === tile.column
  }
}

function isWalkGraphKind(kind) {
  const isShard = kind.number === PackedKind.walkGraphShard
  const isIndex = kind.number === PackedKind.walkGraphIndex
  return isShard || isIndex
}

function prefixOf(kind) {
  return kind.prefix
}

function isNear({coordinate, lon, lat}) {
  const isLonNear = Math.abs(coordinate[0] - lon) < DEGREE_TOLERANCE
  const isLatNear = Math.abs(coordinate[1] - lat) < DEGREE_TOLERANCE
  return isLonNear && isLatNear
}

function passesSidewalkMiddle(coordinate) {
  return isNear({coordinate, lon: SIDEWALK_MIDDLE_LON_DEGREES, lat: SIDEWALK_MIDDLE_LAT_DEGREES})
}

function passesSharedPosition(coordinate) {
  return isNear({coordinate, lon: SHARED_LON_DEGREES, lat: SHARED_LAT_DEGREES})
}

function metersOfUnits({lonUnits, latDegrees}) {
  return lonUnits * (metersPerDegreeLongitude(latDegrees) / UNITS_PER_DEGREE)
}

function upperCase(text) {
  return text.toUpperCase()
}

// ---- The decoders against the fixtures.

const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf8"))

for (const [name, key] of [["shard-west", "shardWest"], ["shard-east", "shardEast"]]) {
  const table = decodedShard(name + ".bin")
  strictEqual(table.pieceCount, expected[key].pieceCount, name + " piece count")
  deepStrictEqual(Array.from(table.classes), expected[key].classes, name + " classes")
  deepStrictEqual(Array.from(table.pieceStarts), expected[key].pieceStarts, name + " starts")
  deepStrictEqual(Array.from(table.points), expected[key].points, name + " points")

  const stream = read(name + ".bin.gz")
  const expanded = await expandStream(stream, {expandedByteSizeMax: EXPANDED_BYTES_MAX})
  strictEqual(expanded.kind, PackedOutcome.expanded)
  deepStrictEqual(decodeWalkGraphShard(expanded.bytes), {kind: PackedOutcome.decoded, table}, name + " gzip")
}

const indexDecoded = decodeWalkGraphIndex(read("index.bin"))
strictEqual(indexDecoded.kind, PackedOutcome.decoded)
strictEqual(indexDecoded.table.buildId, expected.index.buildId)
const decodedTileKeys = Array.from(indexDecoded.table.tileKeys).sort()
deepStrictEqual(decodedTileKeys, [...expected.index.tileKeys].sort(), "index tiles")
const index = indexDecoded.table.tileKeys

strictEqual(walkGraphShardName({buildId: BUILD_ID, tile: WEST_TILE}), "walk-graph-0123456789abcdef-4761_-8156.bin.gz", "shard file name")

const walkGraphKinds = KINDS.filter(isWalkGraphKind)
const walkGraphPrefixes = Array.from(walkGraphKinds, prefixOf)
deepStrictEqual(walkGraphPrefixes, ["walk-graph", "walk-graph-index"], "kind prefixes")

// ---- Refusals are values.

const westBytes = read("shard-west.bin")
const indexBytes = read("index.bin")
const withVersion = withByte({bytes: westBytes, offset: VERSION_OFFSET, value: SECOND_VERSION})
const withBadClass = withByte({bytes: westBytes, offset: SHARD_CLASS_OFFSET, value: BAD_CLASS})
const withShortCount = withByte({bytes: westBytes, offset: SHARD_COUNT_OFFSET, value: ONE_POSITION})
const withLongCount = withByte({bytes: westBytes, offset: SHARD_COUNT_OFFSET, value: THREE_POSITIONS})
const withTrailingByte = new Uint8Array([...westBytes, 0])
const truncated = westBytes.slice(0, westBytes.length - 1)
const withBadBuildId = withByte({bytes: indexBytes, offset: INDEX_BUILD_ID_OFFSET, value: UPPER_G})
const withEmptyRun = withByte({bytes: indexBytes, offset: INDEX_FIRST_LENGTH_OFFSET, value: 0})
const indexAsShardKind = withByte({bytes: indexBytes, offset: KIND_OFFSET, value: PackedKind.walkGraphShard})

strictEqual(shardRefusal(indexBytes), PackedRefusal.kindMismatch, "the index read as a shard")
strictEqual(indexRefusal(westBytes), PackedRefusal.kindMismatch, "the shard read as an index")
strictEqual(shardRefusal(withVersion), PackedRefusal.unsupportedVersion)
strictEqual(shardRefusal(truncated), PackedRefusal.truncated)
strictEqual(shardRefusal(withBadClass), WalkGraphRefusal.badClass)
strictEqual(shardRefusal(withShortCount), WalkGraphRefusal.badCounts)
strictEqual(shardRefusal(withLongCount), WalkGraphRefusal.countMismatch)
strictEqual(shardRefusal(withTrailingByte), PackedRefusal.trailingBytes)
strictEqual(indexRefusal(withBadBuildId), WalkGraphRefusal.badBuildId)
strictEqual(indexRefusal(withEmptyRun), WalkGraphRefusal.badRuns)
strictEqual(indexRefusal(indexAsShardKind), PackedRefusal.kindMismatch)

const tooLarge = await expandStream(read("shard-west.bin.gz"), {expandedByteSizeMax: ONE_POSITION})

// The east shard's one piece ends at its start when the last difference is zero.
const eastBytes = read("shard-east.bin")
const closedEast = new Uint8Array(eastBytes)
closedEast.set(ZERO_DELTA_BYTES, closedEast.length - EAST_LAST_DELTA_OFFSET_FROM_END)
strictEqual(shardRefusal(closedEast), WalkGraphRefusal.closedPiece, "a piece that starts and ends at one position")
deepStrictEqual(tooLarge, {kind: PackedOutcome.refused, reason: PackedRefusal.tooLarge}, "an expansion past its bound")

// ---- The walk path over the fixture's shards.

const west = decodedShard("shard-west.bin")
const east = decodedShard("shard-east.bin")
const loadedBoth = new Map([[tileKey(WEST_TILE), west], [tileKey(EAST_TILE), east]])
const loadedWest = new Map([[tileKey(WEST_TILE), west]])

function walk({from, to, loaded}) {
  return planWalk({from, to, index, loaded, limits: WALK_LIMITS})
}

// A walk around the missing link: the middle column joins no rows, so the
// path from the north street to the south one goes by the west sidewalk.
{
  const from = degrees(NORTH, NEAR_WEST)
  const to = degrees(SOUTH, NEAR_WEST)
  const found = walk({from, to, loaded: loadedBoth})
  strictEqual(found.kind, WalkPathKind.found)
  const middleLat = (from.lat + to.lat) / HALF
  const alongStreets = HALF * metersOfUnits({lonUnits: DETOUR_LON_UNITS, latDegrees: middleLat})
  const acrossRows = DETOUR_ROW_UNITS * (METERS_PER_DEGREE / UNITS_PER_DEGREE)
  const expectedMeters = alongStreets + acrossRows
  ok(Math.abs(found.meters - expectedMeters) < METERS_TOLERANCE, "the detour is " + expectedMeters + " m, not " + found.meters)
  deepStrictEqual(found.coordinates[0], [from.lon, from.lat], "the line starts at the first end")
  deepStrictEqual(found.coordinates[found.coordinates.length - 1], [to.lon, to.lat], "the line ends at the second end")
  const isSidewalkPassed = found.coordinates.some(passesSidewalkMiddle)
  ok(isSidewalkPassed, "the path passes the sidewalk's middle vertex")
}

// A path across the boundary of two shards joins at the position they share.
{
  const from = degrees(SOUTH, NEAR_MIDDLE_EAST)
  const to = degrees(SOUTH, FAR_EAST_COLUMN)
  const found = walk({from, to, loaded: loadedBoth})
  strictEqual(found.kind, WalkPathKind.found)
  const isSharedPassed = found.coordinates.some(passesSharedPosition)
  ok(isSharedPassed, "the path passes the position the shards share")
  const straight = metersOfUnits({lonUnits: MIDDLE_EAST_SPAN_UNITS, latDegrees: from.lat})
  ok(Math.abs(found.meters - straight) < METERS_TOLERANCE, "a straight street is as long as the straight line")

  const needsEast = walk({from, to, loaded: loadedWest})
  deepStrictEqual(needsEast, {kind: WalkPathKind.notLoaded, tiles: [EAST_TILE]}, "the east shard is still to load")
}

// Both ends on one piece.
{
  const from = degrees(NORTH, ONE_PIECE_FIRST)
  const to = degrees(NORTH, ONE_PIECE_LAST)
  const found = walk({from, to, loaded: loadedBoth})
  strictEqual(found.kind, WalkPathKind.found)
  const expectedMeters = metersOfUnits({lonUnits: ONE_PIECE_SPAN_UNITS, latDegrees: from.lat})
  ok(Math.abs(found.meters - expectedMeters) < METERS_TOLERANCE, "one piece: " + found.meters)
}

// The first end snaps to a piece that no other joins.
{
  const island = walk({from: degrees(FAR_ISLAND_LAT, ONE_PIECE_FIRST), to: degrees(NORTH, ONE_PIECE_FIRST), loaded: loadedBoth})
  deepStrictEqual(island, {kind: WalkPathKind.noPath, reason: NoPathReason.disconnected})
}

// An end farther than the snap bound from every piece.
{
  const off = walk({from: degrees(NORTH, MIDDLE_COLUMN), to: degrees(OFF_GRAPH_LAT, MIDDLE_COLUMN), loaded: loadedBoth})
  deepStrictEqual(off, {kind: WalkPathKind.noPath, reason: NoPathReason.offGraph})
}

const detourEnds = {from: degrees(NORTH, NEAR_WEST), to: degrees(SOUTH, NEAR_WEST)}

// A search past its cap stops.
{
  const limits = {...WALK_LIMITS, visitedNodeCountMax: CAP_VISITED}
  const capped = planWalk({...detourEnds, index, loaded: loadedBoth, limits})
  deepStrictEqual(capped, {kind: WalkPathKind.noPath, reason: NoPathReason.capReached})
}

// A graph past its piece bound stops before it is built.
{
  const limits = {...WALK_LIMITS, edgeCountMax: CAP_EDGES}
  const bounded = planWalk({...detourEnds, index, loaded: loadedBoth, limits})
  deepStrictEqual(bounded, {kind: WalkPathKind.noPath, reason: NoPathReason.capReached})
}

// Ends farther apart than the walk limit read no tile.
{
  const far = walk({from: degrees(NORTH, NEAR_WEST), to: degrees(FAR_NORTH_LAT, NEAR_WEST), loaded: loadedBoth})
  deepStrictEqual(far, {kind: WalkPathKind.noPath, reason: NoPathReason.tooFar})
}

// A box of more tiles than the bound is too far, whatever the distance.
{
  const limits = {...WALK_LIMITS, tileCountMax: CAP_TILES}
  const wide = planWalk({from: degrees(NORTH, NEAR_WEST), to: degrees(NORTH, FAR_EAST_TILE_COLUMN), index, loaded: loadedBoth, limits})
  deepStrictEqual(wide, {kind: WalkPathKind.noPath, reason: NoPathReason.tooFar})
}

// A walk reads the 3 by 3 tiles around the tile of each end, wherever in its
// tile the end stands, and no tile past them.
{
  const around = []
  const tileSpan = [-WINDOW_RADIUS, 0, WINDOW_RADIUS]

  for (const rowStep of tileSpan) {
    for (const columnStep of tileSpan) {
      around.push({row: WEST_TILE.row + rowStep, column: WEST_TILE.column + columnStep})
    }
  }

  const beyond = {row: WEST_TILE.row, column: WEST_TILE.column + WINDOW_RADIUS + 1}
  const aroundKeys = Array.from(around, tileKey)
  const beyondKey = tileKey(beyond)
  const wideIndex = new Set([...aroundKeys, beyondKey])
  const corner = degrees(NORTH, WEST_COLUMN)
  const middle = degrees(SOUTH, MIDDLE_COLUMN)
  const window = walkTilesNeeded({from: corner, to: middle, index: wideIndex, limits: WALK_LIMITS})
  strictEqual(window.kind, "tiles")
  strictEqual(window.tiles.length, WINDOW_TILE_COUNT)
  deepStrictEqual(window.tiles[0], around[0], "tiles come in row then column order")
  const isBeyondTile = isBeyond(beyond)
  const hasBeyond = window.tiles.some(isBeyondTile)
  strictEqual(hasBeyond, false, "no tile past the window")

  const sameWindow = walkTilesNeeded({from: middle, to: corner, index: wideIndex, limits: WALK_LIMITS})
  deepStrictEqual(sameWindow, window, "the ends in either order read the same tiles")

  const farEnd = degrees(SOUTH, FAR_EAST_COLUMN)
  const twoWindows = walkTilesNeeded({from: corner, to: farEnd, index: wideIndex, limits: {...WALK_LIMITS, tileCountMax: WINDOW_TILE_COUNT}})
  deepStrictEqual(twoWindows, {kind: "tooFar"}, "two windows past the tile cap")
}

// A walk where the index holds no tile has no shard.
{
  const none = planWalk({...detourEnds, index: new Set(), loaded: new Map(), limits: WALK_LIMITS})
  deepStrictEqual(none, {kind: WalkPathKind.noPath, reason: NoPathReason.noShards})
  deepStrictEqual(findWalkPath({...detourEnds, shards: [], limits: WALK_LIMITS}), none)
}

// The tiles a walk reads: those its box touches, and only the indexed ones.
{
  const needed = walkTilesNeeded({from: degrees(NORTH, NEAR_MIDDLE_EAST), to: degrees(SOUTH, FAR_EAST_COLUMN), index, limits: WALK_LIMITS})
  deepStrictEqual(needed, {kind: "tiles", tiles: [WEST_TILE, EAST_TILE]})
  deepStrictEqual(tileOf({lat: MIDDLE_LAT_UNITS, lon: NEAR_WEST}), WEST_TILE)
  strictEqual(TILE_LAT_UNITS, EXPECTED_TILE_LAT_UNITS)
  strictEqual(TILE_LON_UNITS, EXPECTED_TILE_LON_UNITS)
}

// A latitude that is not a number is a programmer error, never a value.
{
  let message = ""

  try {
    walk({from: {lat: Number.NaN, lon: 0}, to: degrees(SOUTH, NEAR_WEST), loaded: loadedBoth})
  } catch (error) {
    message = error.message
  }

  ok(message.includes("latitude"), "a NaN latitude asserts: " + message)
}

// A graph holds no piece that starts and ends at one node.
{
  const loop = [[SOUTH, WEST_COLUMN], [SOUTH, WEST_COLUMN + LOOP_SIDE_UNITS], [SOUTH + LOOP_SIDE_UNITS, WEST_COLUMN + LOOP_SIDE_UNITS], [SOUTH, WEST_COLUMN]]
  const loopEnds = {from: degrees(SOUTH, WEST_COLUMN + FROM_OFFSET_UNITS), to: degrees(SOUTH, WEST_COLUMN + TO_OFFSET_UNITS)}
  let message = ""

  try {
    findWalkPath({...loopEnds, shards: [tableOfLines([loop])], limits: WALK_LIMITS})
  } catch (error) {
    message = error.message
  }

  ok(message.includes("starts and ends at one node"), "a loop piece asserts: " + message)
}

// An end snaps into the component the other end reaches, not the nearer one.
{
  const mainLine = [[SOUTH, WEST_COLUMN], [SOUTH, WEST_COLUMN + MAIN_SPAN_UNITS]]
  const islandLine = [[SOUTH + ISLAND_LAT_UNITS, WEST_COLUMN + ISLAND_FIRST_UNITS], [SOUTH + ISLAND_LAT_UNITS, WEST_COLUMN + ISLAND_LAST_UNITS]]
  const from = degrees(SOUTH, WEST_COLUMN + FROM_OFFSET_UNITS)
  const to = degrees(SOUTH + TO_LAT_UNITS, WEST_COLUMN + TO_OFFSET_UNITS)
  const found = findWalkPath({from, to, shards: [tableOfLines([mainLine, islandLine])], limits: WALK_LIMITS})
  strictEqual(found.kind, WalkPathKind.found)
  const alongMain = metersOfUnits({lonUnits: TO_OFFSET_UNITS - FROM_OFFSET_UNITS, latDegrees: from.lat})
  const expectedMeters = alongMain + TO_LAT_UNITS * (METERS_PER_DEGREE / UNITS_PER_DEGREE)
  ok(Math.abs(found.meters - expectedMeters) < METERS_TOLERANCE, "the main street's path is " + expectedMeters + " m, not " + found.meters)
}

// ---- The manifest a reader accepts.
const MANIFEST = {
  buildId: BUILD_ID,
  index: {path: "/intersections/walk-graph-index-aa.bin.gz", byteSize: INDEX_BYTE_SIZE, sha256: "aa"},
  tile: {latUnits: TILE_LAT_UNITS, lonUnits: TILE_LON_UNITS},
  kindVersion: KIND_VERSION,
  unitsPerDegree: UNITS_PER_DEGREE
}

deepStrictEqual(
  acceptWalkManifest(MANIFEST),
  {kind: ManifestKind.accepted, buildId: BUILD_ID, indexPath: "/intersections/walk-graph-index-aa.bin.gz", indexByteSize: INDEX_BYTE_SIZE}
)

const REFUSED_MANIFESTS = [
  ["null", null, ManifestRefusal.notAnObject],
  ["an array", [], ManifestRefusal.notAnObject],
  ["other tiles", {...MANIFEST, tile: {latUnits: TILE_LAT_UNITS / HALF, lonUnits: TILE_LON_UNITS}}, ManifestRefusal.otherTiles],
  ["no tiles", {...MANIFEST, tile: undefined}, ManifestRefusal.otherTiles],
  ["other units", {...MANIFEST, unitsPerDegree: UNITS_PER_DEGREE * PERCENT}, ManifestRefusal.otherUnits],
  ["a newer kind version", {...MANIFEST, kindVersion: SECOND_VERSION}, ManifestRefusal.otherVersion],
  ["no kind version", {...MANIFEST, kindVersion: undefined}, ManifestRefusal.otherVersion],
  ["a build identifier in upper case", {...MANIFEST, buildId: upperCase(BUILD_ID)}, ManifestRefusal.badBuildId],
  ["an index path with no slash", {...MANIFEST, index: {...MANIFEST.index, path: "walk-graph-index.bin.gz"}}, ManifestRefusal.badIndex],
  ["an index of no size", {...MANIFEST, index: {...MANIFEST.index, byteSize: 0}}, ManifestRefusal.badIndex]
]

for (const [name, manifest, reason] of REFUSED_MANIFESTS) {
  deepStrictEqual(acceptWalkManifest(manifest), {kind: ManifestKind.refused, reason}, name)
}

// ---- A random grid against Dijkstra.

let seed = GRID_SEED

function random() {
  seed = (seed * LINEAR_CONGRUENTIAL_MULTIPLIER + LINEAR_CONGRUENTIAL_INCREMENT) % LINEAR_CONGRUENTIAL_MODULUS
  return seed / LINEAR_CONGRUENTIAL_MODULUS
}

function gridLatUnits(row) {
  return GRID_ORIGIN_LAT_UNITS + row * GRID_ROW_STEP_UNITS
}

function gridLonUnits(column) {
  return GRID_ORIGIN_LON_UNITS + column * GRID_COLUMN_STEP_UNITS
}

function gridPieces() {
  const pieces = []

  for (let row = 0; row < GRID_SIZE; row += 1) {
    for (let column = 0; column < GRID_SIZE; column += 1) {
      for (const [rowStep, columnStep] of GRID_STEPS) {
        const nextRow = row + rowStep
        const nextColumn = column + columnStep
        const isInside = nextRow < GRID_SIZE && nextColumn < GRID_SIZE
        const isKept = random() * PERCENT >= OMIT_PERCENT
        const isPiece = isInside && isKept

        if (isPiece) {
          pieces.push([[row, column], [nextRow, nextColumn]])
        }
      }
    }
  }

  return pieces
}

function tableOf(pieces) {
  const points = []
  const pieceStarts = [0]

  for (const [first, last] of pieces) {
    for (const [row, column] of [first, last]) {
      points.push(gridLatUnits(row), gridLonUnits(column))
    }

    pieceStarts.push(pieceStarts[pieceStarts.length - 1] + HALF)
  }

  return {pieceCount: pieces.length, classes: new Uint8Array(pieces.length), pieceStarts: Uint32Array.from(pieceStarts), points: Int32Array.from(points)}
}

function nearestUnsettled({distance, settled}) {
  let best = null

  for (const [node, meters] of distance) {
    const isUnsettled = !settled.has(node)
    const isFirst = best === null
    const isNearer = isFirst || meters < distance.get(best)
    const isChosen = isUnsettled && isNearer

    if (isChosen) {
      best = node
    }
  }

  return best
}

function relaxPiece({piece, best, distance, lengths}) {
  const [first, last] = piece
  const a = first.join(",")
  const b = last.join(",")
  let length = lengths.vertical

  if (first[0] === last[0]) {
    length = lengths.horizontal
  }

  for (const [from, to] of [[a, b], [b, a]]) {
    const candidate = distance.get(best) + length
    const isFrom = from === best
    const isNew = !distance.has(to)
    const isShorter = isNew || distance.get(to) > candidate
    const isRelaxed = isFrom && isShorter

    if (isRelaxed) {
      distance.set(to, candidate)
    }
  }
}

function dijkstra({pieces, lengths, source, target}) {
  const distance = new Map([[source, 0]])
  const settled = new Set()

  for (;;) {
    const best = nearestUnsettled({distance, settled})

    if (best === null) {
      return Infinity
    }

    if (best === target) {
      return distance.get(best)
    }

    settled.add(best)

    for (const piece of pieces) {
      relaxPiece({piece, best, distance, lengths})
    }
  }
}

function nodeOf([row, column]) {
  return degrees(gridLatUnits(row), gridLonUnits(column))
}

function parseNode(text) {
  return Array.from(text.split(","), Number)
}

let foundCount = 0
let disconnectedCount = 0

for (let trial = 0; trial < RANDOM_TRIAL_COUNT; trial += 1) {
  const pieces = gridPieces()
  const table = tableOf(pieces)
  const nodes = []

  for (const [first, last] of pieces) {
    nodes.push(first.join(","), last.join(","))
  }

  if (nodes.length === 0) {
    continue
  }

  const source = nodes[Math.floor(random() * nodes.length)]
  const target = nodes[Math.floor(random() * nodes.length)]
  const from = nodeOf(parseNode(source))
  const to = nodeOf(parseNode(target))
  const middleLat = (from.lat + to.lat) / HALF
  const horizontal = metersOfUnits({lonUnits: GRID_COLUMN_STEP_UNITS, latDegrees: middleLat})
  const vertical = GRID_ROW_STEP_UNITS * (METERS_PER_DEGREE / UNITS_PER_DEGREE)
  const wanted = dijkstra({pieces, lengths: {horizontal, vertical}, source, target})
  const found = findWalkPath({from, to, shards: [table], limits: WALK_LIMITS})

  if (wanted === Infinity) {
    deepStrictEqual(found, {kind: WalkPathKind.noPath, reason: NoPathReason.disconnected}, "trial " + trial + " has no path")
    disconnectedCount += 1
  } else {
    strictEqual(found.kind, WalkPathKind.found, "trial " + trial)
    ok(Math.abs(found.meters - wanted) < METERS_TOLERANCE, "trial " + trial + ": " + found.meters + " against " + wanted)
    foundCount += 1
  }
}

ok(foundCount > TRIAL_KIND_COUNT_MIN, "the grid trials find paths: " + foundCount)
ok(disconnectedCount > TRIAL_KIND_COUNT_MIN, "the grid trials meet disconnected ends: " + disconnectedCount)

console.log("walk path check passed")
