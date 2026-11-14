// The walk graph files as Gobusgo.WalkGraph.Format writes them: packed
// containers of kind 8, a shard of the pieces of way of one tile, and kind 9,
// the index of the tiles that have a shard, both version 1. A position is a
// latitude or longitude in units of the 100,000th part of a degree. The
// decoders read expanded bytes into typed arrays, with no object per piece,
// and return a result keyed by `kind`, the table or the reason the file was
// refused; a bad file is never a throw. Everything here is pure.

import {assertCondition} from "./assert.js"
import {
  ColumnType,
  PackedKind,
  PackedOutcome,
  PackedRefusal,
  SectionCursor,
  decodeContainer,
  openColumn
} from "./packed_container.js"

const WALK_GRAPH_FILE_VERSION = 1
const SHARD_SECTION_COUNT = 3
const INDEX_SECTION_COUNT = 3
const COORDINATE_COUNT = 2
const INDEX_TILE_COUNT_MAX = 200_000
const PIECE_POINT_COUNT_MIN = 2
const BYTES_PER_MEBIBYTE = 1024 * 1024
const BUILD_ID_PATTERN = /^[0-9a-f]{16}$/
const TILE_KEY_SEPARATOR = "_"
const SHARD_FILE_PREFIX = "walk-graph"

/** The units of a degree of latitude or longitude a position is stored in. */
export const UNITS_PER_DEGREE = 100_000

/** The height and width of a tile, in units, as `Gobusgo.WalkGraph.Tiles.sizes/0` has them. */
export const TILE_LAT_UNITS = 1_000
export const TILE_LON_UNITS = 1_500

/** The most bytes a walk graph shard may expand to. */
export const WALK_GRAPH_SHARD_EXPANDED_BYTES_MAX = 1 * BYTES_PER_MEBIBYTE

/** The most bytes a walk graph index may expand to. */
export const WALK_GRAPH_INDEX_EXPANDED_BYTES_MAX = 1 * BYTES_PER_MEBIBYTE

/** The sections of the shard kind after the string table, in order. */
export const WalkGraphShardSection = Object.freeze({classes: 0, counts: 1, positions: 2})

/** The sections of the index kind after the string table, in order. */
export const WalkGraphIndexSection = Object.freeze({rows: 0, starts: 1, lengths: 2})

/** The classes of a piece of way, by the number the shard stores. */
export const WalkClass = Object.freeze({path: 0, sidewalk: 1, crossing: 2, steps: 3, street: 4})

const WALK_CLASS_MAX = WalkClass.street

/** The reasons the kinds refuse a file for, beside the container's own. */
export const WalkGraphRefusal = Object.freeze({
  badClass: "badClass",
  badCounts: "badCounts",
  countMismatch: "countMismatch",
  badBuildId: "badBuildId",
  badRuns: "badRuns"
})

function refused(reason) {
  return {kind: PackedOutcome.refused, reason}
}

/** The key of a tile in a set or a map: `<row>_<column>`. */
export function tileKey({row, column}) {
  assertCondition(Number.isSafeInteger(row), "walk graph: a tile row is an integer, not " + String(row))
  assertCondition(Number.isSafeInteger(column), "walk graph: a tile column is an integer, not " + String(column))
  return String(row) + TILE_KEY_SEPARATOR + String(column)
}

/** The tile that holds the position `{lat, lon}`, each in units. */
export function tileOf({lat, lon}) {
  return {row: Math.floor(lat / TILE_LAT_UNITS), column: Math.floor(lon / TILE_LON_UNITS)}
}

/**
 * The name of the file of the shard of `tile` in the build `buildId`, as
 * `Gobusgo.WalkGraph.Format.shard_file_name/1` names it.
 */
export function walkGraphShardName({buildId, tile}) {
  assertCondition(BUILD_ID_PATTERN.test(buildId), "walk graph: a build identifier is 16 lower case hexadecimal digits, not " + String(buildId))
  return SHARD_FILE_PREFIX + "-" + buildId + "-" + tileKey(tile) + ".bin.gz"
}

function readPieceStarts({container, pieceCount}) {
  const classes = openColumn({view: container.view, section: container.sections[WalkGraphShardSection.classes], type: ColumnType.u8, count: pieceCount})
  const counts = openColumn({view: container.view, section: container.sections[WalkGraphShardSection.counts], type: ColumnType.u16, count: pieceCount})

  if (classes.kind === PackedOutcome.refused) {
    return classes
  }

  if (counts.kind === PackedOutcome.refused) {
    return counts
  }

  const classNumbers = new Uint8Array(pieceCount)
  const pieceStarts = new Uint32Array(pieceCount + 1)

  for (let piece = 0; piece < pieceCount; piece += 1) {
    const classNumber = classes.at(piece)
    const count = counts.at(piece)

    if (classNumber > WALK_CLASS_MAX) {
      return refused(WalkGraphRefusal.badClass)
    }

    if (count < PIECE_POINT_COUNT_MIN) {
      return refused(WalkGraphRefusal.badCounts)
    }

    classNumbers[piece] = classNumber
    pieceStarts[piece + 1] = pieceStarts[piece] + count
  }

  return {kind: PackedOutcome.decoded, classNumbers, pieceStarts}
}

/**
 * The pieces of `bytes`, the expanded container of a shard:
 * `{kind: "decoded", table}`, where `table` is `{pieceCount, classes,
 * pieceStarts, points}`, or `{kind: "refused", reason}` with a reason of the
 * container or of `WalkGraphRefusal`. Piece `p` is of class `classes[p]`, a
 * `WalkClass` number, and holds the positions `pieceStarts[p]` up to
 * `pieceStarts[p + 1]` of `points`, an `Int32Array` of latitude and
 * longitude in units, two a position.
 */
export function decodeWalkGraphShard(bytes) {
  const container = decodeContainer(bytes, {kind: PackedKind.walkGraphShard, versions: [WALK_GRAPH_FILE_VERSION], sectionCount: SHARD_SECTION_COUNT})

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const pieceCount = container.header.recordCount
  const starts = readPieceStarts({container, pieceCount})

  if (starts.kind === PackedOutcome.refused) {
    return starts
  }

  const cursor = new SectionCursor({view: container.view, section: container.sections[WalkGraphShardSection.positions]})
  const points = cursor.readPath()

  if (cursor.refusal !== null) {
    return refused(cursor.refusal)
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badSectionSize)
  }

  const pointCount = starts.pieceStarts[pieceCount]

  if (points.length !== pointCount * COORDINATE_COUNT) {
    return refused(WalkGraphRefusal.countMismatch)
  }

  const table = {pieceCount, classes: starts.classNumbers, pieceStarts: starts.pieceStarts, points}
  return {kind: PackedOutcome.decoded, table}
}

function readRuns({container, runCount}) {
  const rows = openColumn({view: container.view, section: container.sections[WalkGraphIndexSection.rows], type: ColumnType.i32, count: runCount})
  const starts = openColumn({view: container.view, section: container.sections[WalkGraphIndexSection.starts], type: ColumnType.i32, count: runCount})
  const lengths = openColumn({view: container.view, section: container.sections[WalkGraphIndexSection.lengths], type: ColumnType.u16, count: runCount})

  for (const opened of [rows, starts, lengths]) {
    if (opened.kind === PackedOutcome.refused) {
      return opened
    }
  }

  const tileKeys = new Set()

  for (let run = 0; run < runCount; run += 1) {
    const length = lengths.at(run)

    if (length < 1) {
      return refused(WalkGraphRefusal.badRuns)
    }

    for (let offset = 0; offset < length; offset += 1) {
      tileKeys.add(tileKey({row: rows.at(run), column: starts.at(run) + offset}))
    }

    if (tileKeys.size > INDEX_TILE_COUNT_MAX) {
      return refused(WalkGraphRefusal.badRuns)
    }
  }

  return {kind: PackedOutcome.decoded, tileKeys}
}

/**
 * The tiles of `bytes`, the expanded container of an index:
 * `{kind: "decoded", table}`, where `table` is `{buildId, tileKeys}`, the
 * build identifier and a Set of the `tileKey` of every tile that has a
 * shard. A refusal has the reasons of `decodeWalkGraphShard`.
 */
export function decodeWalkGraphIndex(bytes) {
  const container = decodeContainer(bytes, {kind: PackedKind.walkGraphIndex, versions: [WALK_GRAPH_FILE_VERSION], sectionCount: INDEX_SECTION_COUNT})

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const runCount = container.header.recordCount
  const isBuildIdHeld = container.strings.count === 1

  if (!isBuildIdHeld) {
    return refused(WalkGraphRefusal.badBuildId)
  }

  const buildId = container.strings.at(0)

  if (!BUILD_ID_PATTERN.test(buildId)) {
    return refused(WalkGraphRefusal.badBuildId)
  }

  if (runCount < 1) {
    return refused(WalkGraphRefusal.badRuns)
  }

  const runs = readRuns({container, runCount})

  if (runs.kind === PackedOutcome.refused) {
    return runs
  }

  return {kind: PackedOutcome.decoded, table: {buildId, tileKeys: runs.tileKeys}}
}

/** The kinds of the answer to a manifest. */
export const ManifestKind = Object.freeze({accepted: "accepted", refused: "refused"})

/** Why a manifest is refused. */
export const ManifestRefusal = Object.freeze({
  notAnObject: "notAnObject",
  otherTiles: "otherTiles",
  otherUnits: "otherUnits",
  badBuildId: "badBuildId",
  badIndex: "badIndex"
})

function refusedManifest(reason) {
  return {kind: ManifestKind.refused, reason}
}

/**
 * Whether the reader can use the walk graph `manifest` names, as parsed from
 * its JSON: `{kind: "accepted", buildId, indexPath, indexByteSize}`, or
 * `{kind: "refused", reason}` for a manifest that is not an object, whose
 * tiles or units are not the ones this reader cuts by, or whose build
 * identifier or index entry is malformed.
 */
export function acceptWalkManifest(manifest) {
  const isObject = typeof manifest === "object" && manifest !== null && !Array.isArray(manifest)

  if (!isObject) {
    return refusedManifest(ManifestRefusal.notAnObject)
  }

  const tile = manifest.tile
  const isTileHeld = typeof tile === "object" && tile !== null
  const isTileSame = isTileHeld && tile.latUnits === TILE_LAT_UNITS && tile.lonUnits === TILE_LON_UNITS

  if (!isTileSame) {
    return refusedManifest(ManifestRefusal.otherTiles)
  }

  if (manifest.unitsPerDegree !== UNITS_PER_DEGREE) {
    return refusedManifest(ManifestRefusal.otherUnits)
  }

  const isBuildIdHeld = typeof manifest.buildId === "string" && BUILD_ID_PATTERN.test(manifest.buildId)

  if (!isBuildIdHeld) {
    return refusedManifest(ManifestRefusal.badBuildId)
  }

  const index = manifest.index
  const isIndexHeld = typeof index === "object" && index !== null
  const isPathHeld = isIndexHeld && typeof index.path === "string" && index.path.startsWith("/")
  const isSizeHeld = isIndexHeld && Number.isSafeInteger(index.byteSize) && index.byteSize > 0

  if (!isPathHeld || !isSizeHeld) {
    return refusedManifest(ManifestRefusal.badIndex)
  }

  return {kind: ManifestKind.accepted, buildId: manifest.buildId, indexPath: index.path, indexByteSize: index.byteSize}
}
