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
const LOWER_BOUND_PIECE_POINTS = 1
const LARGER_PIECE_POINTS = 3
const TRIAL_KIND_COUNT_MIN = 10
const UPPER_G = 0x47
const METERS_TOLERANCE = 0.6
const SEATTLE_MIDDLE_LAT_UNITS = 4_761_375
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

function withByte({bytes, offset, value}) {
  const copy = new Uint8Array(bytes)
  copy[offset] = value
  return copy
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
  const expanded = await expandStream(stream, {expandedByteSizeMax: 1024 * 1024})
  strictEqual(expanded.kind, PackedOutcome.expanded)
  deepStrictEqual(decodeWalkGraphShard(expanded.bytes), {kind: PackedOutcome.decoded, table}, name + " gzip")
}

const indexDecoded = decodeWalkGraphIndex(read("index.bin"))
strictEqual(indexDecoded.kind, PackedOutcome.decoded)
strictEqual(indexDecoded.table.buildId, expected.index.buildId)
deepStrictEqual(Array.from(indexDecoded.table.tileKeys).sort(), [...expected.index.tileKeys].sort(), "index tiles")
const index = indexDecoded.table.tileKeys

strictEqual(
  walkGraphShardName({buildId: BUILD_ID, tile: {row: 4761, column: -8156}}),
  "walk-graph-0123456789abcdef-4761_-8156.bin.gz",
  "shard file name"
)

deepStrictEqual(
  KINDS.filter((kind) => kind.number === PackedKind.walkGraphShard || kind.number === PackedKind.walkGraphIndex).map((kind) => kind.prefix),
  ["walk-graph", "walk-graph-index"],
  "kind prefixes"
)

// ---- Refusals are values.

const westBytes = read("shard-west.bin")
const indexBytes = read("index.bin")

strictEqual(refusalOf(decodeWalkGraphShard(indexBytes)), PackedRefusal.kindMismatch, "the index read as a shard")
strictEqual(refusalOf(decodeWalkGraphIndex(westBytes)), PackedRefusal.kindMismatch, "the shard read as an index")
strictEqual(refusalOf(decodeWalkGraphShard(withByte({bytes: westBytes, offset: VERSION_OFFSET, value: SECOND_VERSION}))), PackedRefusal.unsupportedVersion)
strictEqual(refusalOf(decodeWalkGraphShard(westBytes.slice(0, westBytes.length - 1))), PackedRefusal.truncated)
strictEqual(refusalOf(decodeWalkGraphShard(withByte({bytes: westBytes, offset: SHARD_CLASS_OFFSET, value: BAD_CLASS}))), WalkGraphRefusal.badClass)
strictEqual(refusalOf(decodeWalkGraphShard(withByte({bytes: westBytes, offset: SHARD_COUNT_OFFSET, value: LOWER_BOUND_PIECE_POINTS}))), WalkGraphRefusal.badCounts)
strictEqual(refusalOf(decodeWalkGraphShard(withByte({bytes: westBytes, offset: SHARD_COUNT_OFFSET, value: LARGER_PIECE_POINTS}))), WalkGraphRefusal.countMismatch)
strictEqual(refusalOf(decodeWalkGraphShard(new Uint8Array([...westBytes, 0]))), PackedRefusal.trailingBytes)
strictEqual(refusalOf(decodeWalkGraphIndex(withByte({bytes: indexBytes, offset: INDEX_BUILD_ID_OFFSET, value: UPPER_G}))), WalkGraphRefusal.badBuildId)
strictEqual(refusalOf(decodeWalkGraphIndex(withByte({bytes: indexBytes, offset: INDEX_FIRST_LENGTH_OFFSET, value: 0}))), WalkGraphRefusal.badRuns)
strictEqual(refusalOf(decodeWalkGraphIndex(withByte({bytes: indexBytes, offset: KIND_OFFSET, value: PackedKind.walkGraphShard}))), PackedRefusal.kindMismatch)

const tooLarge = await expandStream(read("shard-west.bin.gz"), {expandedByteSizeMax: 1})
deepStrictEqual(tooLarge, {kind: PackedOutcome.refused, reason: PackedRefusal.tooLarge}, "an expansion past its bound")

// ---- The walk path over the fixture's shards.

const west = decodedShard("shard-west.bin")
const east = decodedShard("shard-east.bin")
const loadedBoth = new Map([[tileKey({row: 4761, column: -8156}), west], [tileKey({row: 4761, column: -8155}), east]])
const loadedWest = new Map([[tileKey({row: 4761, column: -8156}), west]])
const NORTH = 4_761_450
const SOUTH = 4_761_300

function walk({from, to, loaded}) {
  return planWalk({from, to, index, loaded, limits: WALK_LIMITS})
}

// A walk around the missing link: the middle column joins no rows, so the
// path from the north street to the south one goes by the west sidewalk.
{
  const from = degrees(NORTH, -12_233_500)
  const to = degrees(SOUTH, -12_233_500)
  const found = walk({from, to, loaded: loadedBoth})
  strictEqual(found.kind, WalkPathKind.found)
  const metersPerLon = metersPerDegreeLongitude((from.lat + to.lat) / 2)
  const expectedMeters = 2 * 100 * (metersPerLon / UNITS_PER_DEGREE) + 150 * (METERS_PER_DEGREE / UNITS_PER_DEGREE)
  ok(Math.abs(found.meters - expectedMeters) < METERS_TOLERANCE, "the detour is " + expectedMeters + " m, not " + found.meters)
  deepStrictEqual(found.coordinates[0], [from.lon, from.lat], "the line starts at the first end")
  deepStrictEqual(found.coordinates[found.coordinates.length - 1], [to.lon, to.lat], "the line ends at the second end")
  const sidewalkMiddle = found.coordinates.some(([lon, lat]) => Math.abs(lon - -122.336) < 1e-7 && Math.abs(lat - 47.6138) < 1e-7)
  ok(sidewalkMiddle, "the path passes the sidewalk's middle vertex")
}

// A path across the boundary of two shards joins at the position they share.
{
  const from = degrees(SOUTH, -12_233_300)
  const to = degrees(SOUTH, -12_232_000)
  const found = walk({from, to, loaded: loadedBoth})
  strictEqual(found.kind, WalkPathKind.found)
  const shared = found.coordinates.some(([lon, lat]) => Math.abs(lon - -122.324) < 1e-7 && Math.abs(lat - 47.613) < 1e-7)
  ok(shared, "the path passes the position the shards share")
  const straight = 1300 * (metersPerDegreeLongitude(from.lat) / UNITS_PER_DEGREE)
  ok(Math.abs(found.meters - straight) < METERS_TOLERANCE, "a straight street is as long as the straight line")

  const needsEast = walk({from, to, loaded: loadedWest})
  deepStrictEqual(needsEast, {kind: WalkPathKind.notLoaded, tiles: [{row: 4761, column: -8155}]}, "the east shard is still to load")
}

// Both ends on one piece.
{
  const from = degrees(NORTH, -12_233_550)
  const to = degrees(NORTH, -12_233_450)
  const found = walk({from, to, loaded: loadedBoth})
  strictEqual(found.kind, WalkPathKind.found)
  const expectedMeters = 100 * (metersPerDegreeLongitude(from.lat) / UNITS_PER_DEGREE)
  ok(Math.abs(found.meters - expectedMeters) < METERS_TOLERANCE, "one piece: " + found.meters)
}

// The first end snaps to a piece that no other joins.
{
  const island = walk({from: degrees(4_761_800, -12_233_500), to: degrees(NORTH, -12_233_500), loaded: loadedBoth})
  deepStrictEqual(island, {kind: WalkPathKind.noPath, reason: NoPathReason.disconnected})
}

// An end farther than the snap bound from every piece.
{
  const off = walk({from: degrees(NORTH, -12_233_400), to: degrees(4_761_600, -12_233_400), loaded: loadedBoth})
  deepStrictEqual(off, {kind: WalkPathKind.noPath, reason: NoPathReason.offGraph})
}

// A search past its cap stops.
{
  const capped = planWalk({
    from: degrees(NORTH, -12_233_500),
    to: degrees(SOUTH, -12_233_500),
    index,
    loaded: loadedBoth,
    limits: {...WALK_LIMITS, visitedNodeCountMax: 1}
  })
  deepStrictEqual(capped, {kind: WalkPathKind.noPath, reason: NoPathReason.capReached})
}

// A graph past its piece bound stops before it is built.
{
  const bounded = planWalk({
    from: degrees(NORTH, -12_233_500),
    to: degrees(SOUTH, -12_233_500),
    index,
    loaded: loadedBoth,
    limits: {...WALK_LIMITS, edgeCountMax: 1}
  })
  deepStrictEqual(bounded, {kind: WalkPathKind.noPath, reason: NoPathReason.capReached})
}

// Ends farther apart than the walk limit read no tile.
{
  const far = walk({from: degrees(NORTH, -12_233_500), to: degrees(NORTH + 2_000, -12_233_500), loaded: loadedBoth})
  deepStrictEqual(far, {kind: WalkPathKind.noPath, reason: NoPathReason.tooFar})
}

// A box of more tiles than the bound is too far, whatever the distance.
{
  const wide = planWalk({
    from: degrees(NORTH, -12_233_500),
    to: degrees(NORTH, -12_231_000),
    index,
    loaded: loadedBoth,
    limits: {...WALK_LIMITS, tileCountMax: 1}
  })
  deepStrictEqual(wide, {kind: WalkPathKind.noPath, reason: NoPathReason.tooFar})
}

// A walk where the index holds no tile has no shard.
{
  const none = planWalk({from: degrees(NORTH, -12_233_500), to: degrees(SOUTH, -12_233_500), index: new Set(), loaded: new Map(), limits: WALK_LIMITS})
  deepStrictEqual(none, {kind: WalkPathKind.noPath, reason: NoPathReason.noShards})
  deepStrictEqual(findWalkPath({from: degrees(NORTH, -12_233_500), to: degrees(SOUTH, -12_233_500), shards: [], limits: WALK_LIMITS}), none)
}

// The tiles a walk reads: those its box touches, and only the indexed ones.
{
  const needed = walkTilesNeeded({from: degrees(NORTH, -12_233_300), to: degrees(SOUTH, -12_232_000), index, limits: WALK_LIMITS})
  deepStrictEqual(needed, {kind: "tiles", tiles: [{row: 4761, column: -8156}, {row: 4761, column: -8155}]})
  deepStrictEqual(tileOf({lat: SEATTLE_MIDDLE_LAT_UNITS, lon: -12_233_500}), {row: 4761, column: -8156})
  strictEqual(TILE_LAT_UNITS, 1_000)
  strictEqual(TILE_LON_UNITS, 1_500)
}

// A negative end is refused as a programmer error, never a value.
{
  let message = ""

  try {
    walk({from: {lat: Number.NaN, lon: 0}, to: degrees(SOUTH, -12_233_500), loaded: loadedBoth})
  } catch (error) {
    message = error.message
  }

  ok(message.includes("latitude"), "a NaN latitude asserts: " + message)
}

// ---- A random grid against Dijkstra.

let seed = 7

function random() {
  seed = (seed * LINEAR_CONGRUENTIAL_MULTIPLIER + LINEAR_CONGRUENTIAL_INCREMENT) % LINEAR_CONGRUENTIAL_MODULUS
  return seed / LINEAR_CONGRUENTIAL_MODULUS
}

function gridTable() {
  const pieces = []
  const omitted = new Set()

  for (let row = 0; row < GRID_SIZE; row += 1) {
    for (let column = 0; column < GRID_SIZE; column += 1) {
      for (const [dRow, dColumn] of [[0, 1], [1, 0]]) {
        const nextRow = row + dRow
        const nextColumn = column + dColumn
        const isInside = nextRow < GRID_SIZE && nextColumn < GRID_SIZE
        const isKept = random() * PERCENT >= OMIT_PERCENT

        if (isInside && isKept) {
          pieces.push([[row, column], [nextRow, nextColumn]])
        } else if (isInside) {
          omitted.add(`${row},${column},${nextRow},${nextColumn}`)
        }
      }
    }
  }

  const points = []
  const pieceStarts = [0]

  for (const [first, last] of pieces) {
    for (const [row, column] of [first, last]) {
      points.push(GRID_ORIGIN_LAT_UNITS + row * GRID_ROW_STEP_UNITS, GRID_ORIGIN_LON_UNITS + column * GRID_COLUMN_STEP_UNITS)
    }

    pieceStarts.push(pieceStarts[pieceStarts.length - 1] + 2)
  }

  return {pieces, table: {pieceCount: pieces.length, classes: new Uint8Array(pieces.length), pieceStarts: Uint32Array.from(pieceStarts), points: Int32Array.from(points)}}
}

function dijkstra({pieces, lengths, source, target}) {
  const distance = new Map([[source, 0]])
  const settled = new Set()

  for (;;) {
    let best = null

    for (const [node, meters] of distance) {
      if (!settled.has(node) && (best === null || meters < distance.get(best))) {
        best = node
      }
    }

    if (best === null) {
      return Infinity
    }

    if (best === target) {
      return distance.get(best)
    }

    settled.add(best)

    for (const [first, last] of pieces) {
      const a = first.join(",")
      const b = last.join(",")
      const length = first[0] === last[0] ? lengths.horizontal : lengths.vertical

      for (const [from, to] of [[a, b], [b, a]]) {
        const isNearer = from === best && (!distance.has(to) || distance.get(to) > distance.get(best) + length)

        if (isNearer) {
          distance.set(to, distance.get(best) + length)
        }
      }
    }
  }
}

let foundCount = 0
let disconnectedCount = 0

for (let trial = 0; trial < RANDOM_TRIAL_COUNT; trial += 1) {
  const {pieces, table} = gridTable()
  const nodes = []

  for (const [first, last] of pieces) {
    nodes.push(first.join(","), last.join(","))
  }

  if (nodes.length === 0) {
    continue
  }

  const source = nodes[Math.floor(random() * nodes.length)]
  const target = nodes[Math.floor(random() * nodes.length)]
  const [sourceRow, sourceColumn] = source.split(",").map(Number)
  const [targetRow, targetColumn] = target.split(",").map(Number)
  const from = degrees(GRID_ORIGIN_LAT_UNITS + sourceRow * GRID_ROW_STEP_UNITS, GRID_ORIGIN_LON_UNITS + sourceColumn * GRID_COLUMN_STEP_UNITS)
  const to = degrees(GRID_ORIGIN_LAT_UNITS + targetRow * GRID_ROW_STEP_UNITS, GRID_ORIGIN_LON_UNITS + targetColumn * GRID_COLUMN_STEP_UNITS)
  const metersPerLon = metersPerDegreeLongitude((from.lat + to.lat) / 2)
  const lengths = {horizontal: GRID_COLUMN_STEP_UNITS * metersPerLon / UNITS_PER_DEGREE, vertical: GRID_ROW_STEP_UNITS * METERS_PER_DEGREE / UNITS_PER_DEGREE}
  const wanted = dijkstra({pieces, lengths, source, target})
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

// ---- The manifest a reader accepts.

const MANIFEST = {
  buildId: BUILD_ID,
  index: {path: "/intersections/walk-graph-index-aa.bin.gz", byteSize: 3318, sha256: "aa"},
  tile: {latUnits: TILE_LAT_UNITS, lonUnits: TILE_LON_UNITS},
  unitsPerDegree: UNITS_PER_DEGREE
}

deepStrictEqual(
  acceptWalkManifest(MANIFEST),
  {kind: ManifestKind.accepted, buildId: BUILD_ID, indexPath: "/intersections/walk-graph-index-aa.bin.gz", indexByteSize: 3318}
)

for (const [name, manifest, reason] of [
  ["null", null, ManifestRefusal.notAnObject],
  ["an array", [], ManifestRefusal.notAnObject],
  ["other tiles", {...MANIFEST, tile: {latUnits: 500, lonUnits: TILE_LON_UNITS}}, ManifestRefusal.otherTiles],
  ["no tiles", {...MANIFEST, tile: undefined}, ManifestRefusal.otherTiles],
  ["other units", {...MANIFEST, unitsPerDegree: 1_000_000}, ManifestRefusal.otherUnits],
  ["a build identifier in upper case", {...MANIFEST, buildId: BUILD_ID.toUpperCase()}, ManifestRefusal.badBuildId],
  ["an index path with no slash", {...MANIFEST, index: {...MANIFEST.index, path: "walk-graph-index.bin.gz"}}, ManifestRefusal.badIndex],
  ["an index of no size", {...MANIFEST, index: {...MANIFEST.index, byteSize: 0}}, ManifestRefusal.badIndex]
]) {
  deepStrictEqual(acceptWalkManifest(manifest), {kind: ManifestKind.refused, reason}, name)
}

console.log("walk path check passed")
