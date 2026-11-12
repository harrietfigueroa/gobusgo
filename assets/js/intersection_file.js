// The intersection files as Gobusgo.Intersections.Format writes them: packed
// containers of kind 6, a shard of streets with the crossings of each, and
// kind 7, the index of the shards, both version 1. `decodeIntersectionShard`
// and `decodeIntersectionIndex` read the expanded bytes into typed columns and
// decoded strings, with no object per crossing; `loadIntersectionShard` and
// `loadIntersectionIndex` expand a fetched gzip stream under the kind's bound
// first. Each returns a result keyed by `kind`, the table or the reason the
// file was refused; a bad file is never a throw. Everything here is pure but
// the expansion.

import {assertCondition} from "./core/assert.js"
import {
  ColumnType,
  PackedKind,
  PackedOutcome,
  PackedRefusal,
  SectionCursor,
  VARINT_VALUE_MAX,
  decodeContainer,
  openColumn,
  packedFileName,
} from "./core/packed_container.js"
import {expandStream} from "./packed_stream.js"

const INTERSECTION_FILE_VERSION = 1
const SHARD_SECTION_COUNT = 4
const INDEX_SECTION_COUNT = 3
const DIGEST_BYTES = 32
const COORDINATE_COUNT = 2
const BYTES_PER_MEBIBYTE = 1024 * 1024
const HEX_RADIX = 16
const HEX_DIGITS_PER_BYTE = 2
const SHARD_EXPANDED_MEBIBYTES_MAX = 1
const INDEX_EXPANDED_MEBIBYTES_MAX = 1

/** The most bytes an intersection shard may expand to. */
export const INTERSECTION_SHARD_EXPANDED_BYTES_MAX = SHARD_EXPANDED_MEBIBYTES_MAX * BYTES_PER_MEBIBYTE

/** The most bytes an intersection index may expand to. */
export const INTERSECTION_INDEX_EXPANDED_BYTES_MAX = INDEX_EXPANDED_MEBIBYTES_MAX * BYTES_PER_MEBIBYTE

/** The sections of the shard kind after the string table, in order. */
export const IntersectionShardSection = Object.freeze({
  keys: 0,
  counts: 1,
  others: 2,
  positions: 3,
})

/** The sections of the index kind after the string table, in order. */
export const IntersectionIndexSection = Object.freeze({
  prefixes: 0,
  byteSizes: 1,
  digests: 2,
})

/** The reasons the kinds refuse a file for, beside the container's own. */
export const IntersectionFileRefusal = Object.freeze({
  badStringIndex: "badStringIndex",
  badCounts: "badCounts",
  countMismatch: "countMismatch",
})

function refused(reason) {
  return {kind: PackedOutcome.refused, reason}
}

function column({container, index, type, count}) {
  return openColumn({view: container.view, section: container.sections[index], type, count})
}

// The first of `results` that is a refusal, or a decoded result when none is.
function firstRefusal(results) {
  for (const result of results) {
    if (result.kind === PackedOutcome.refused) {
      return result
    }
  }

  return {kind: PackedOutcome.decoded}
}

// A copy of an opened column as a typed array, or a refusal for an index that
// is not in the string table.
function stringIndexes({container, index, count}) {
  const opened = column({container, index, type: ColumnType.u32, count})

  if (opened.kind === PackedOutcome.refused) {
    return opened
  }

  const indexes = new Uint32Array(count)

  for (let position = 0; position < count; position += 1) {
    const value = opened.at(position)

    if (value >= container.strings.count) {
      return refused(IntersectionFileRefusal.badStringIndex)
    }

    indexes[position] = value
  }

  return {kind: PackedOutcome.decoded, indexes}
}

// Every entry of the string table, decoded once.
function allStrings(strings) {
  const texts = new Array(strings.count)

  for (let index = 0; index < strings.count; index += 1) {
    texts[index] = strings.at(index)
  }

  return texts
}

// The start of each street's crossings: street `s` holds crossings
// `crossingStarts[s]` up to `crossingStarts[s + 1]`. Every street holds one.
function readCrossingStarts({container, streetCount}) {
  const opened = column({container, index: IntersectionShardSection.counts, type: ColumnType.u32, count: streetCount})

  if (opened.kind === PackedOutcome.refused) {
    return opened
  }

  const crossingStarts = new Uint32Array(streetCount + 1)
  let running = 0

  for (let street = 0; street < streetCount; street += 1) {
    const count = opened.at(street)
    running += count

    const isCounted = count >= 1 && running <= VARINT_VALUE_MAX

    if (!isCounted) {
      return refused(IntersectionFileRefusal.badCounts)
    }

    crossingStarts[street + 1] = running
  }

  return {kind: PackedOutcome.decoded, crossingStarts}
}

// The positions of every crossing, latitude and longitude in turn, one path a
// street of as many points as the street has crossings.
function readPositions({container, crossingStarts}) {
  const streetCount = crossingStarts.length - 1
  const total = crossingStarts[streetCount]
  const cursor = new SectionCursor({view: container.view, section: container.sections[IntersectionShardSection.positions]})
  const positions = new Int32Array(total * COORDINATE_COUNT)

  for (let street = 0; street < streetCount; street += 1) {
    const path = cursor.readPath()

    if (cursor.refusal !== null) {
      return refused(cursor.refusal)
    }

    const start = crossingStarts[street]
    const count = crossingStarts[street + 1] - start

    if (path.length !== count * COORDINATE_COUNT) {
      return refused(IntersectionFileRefusal.countMismatch)
    }

    positions.set(path, start * COORDINATE_COUNT)
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badSectionSize)
  }

  return {kind: PackedOutcome.decoded, positions}
}

/**
 * The streets of `bytes`, the expanded container of a shard:
 * `{kind: "decoded", table}`, where `table` is `{streetCount, strings, keys,
 * crossingStarts, others, positions}`, or `{kind: "refused", reason}` with a
 * reason of the container or of `IntersectionFileRefusal`. `strings` is every
 * string of the file; `keys` is a `Uint32Array` of each street's key as an
 * index into it. Street `s` holds the crossings `crossingStarts[s]` up to
 * `crossingStarts[s + 1]`, a `Uint32Array` of `streetCount + 1` starts into
 * `others`, a `Uint32Array` of the other street of each crossing as an index
 * into `strings`, and `positions`, an `Int32Array` of latitude and longitude
 * in microdegrees, two a crossing.
 */
export function decodeIntersectionShard(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.intersectionShard,
    versions: [INTERSECTION_FILE_VERSION],
    sectionCount: SHARD_SECTION_COUNT,
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const streetCount = container.header.recordCount
  const keys = stringIndexes({container, index: IntersectionShardSection.keys, count: streetCount})
  const starts = readCrossingStarts({container, streetCount})
  const earlier = firstRefusal([keys, starts])

  if (earlier.kind === PackedOutcome.refused) {
    return earlier
  }

  const {crossingStarts} = starts
  const total = crossingStarts[streetCount]
  const others = stringIndexes({container, index: IntersectionShardSection.others, count: total})

  if (others.kind === PackedOutcome.refused) {
    return others
  }

  const positions = readPositions({container, crossingStarts})

  if (positions.kind === PackedOutcome.refused) {
    return positions
  }

  const table = {
    streetCount,
    strings: allStrings(container.strings),
    keys: keys.indexes,
    crossingStarts,
    others: others.indexes,
    positions: positions.positions,
  }

  return {kind: PackedOutcome.decoded, table}
}

function hexOf({view, offset}) {
  let text = ""

  for (let index = 0; index < DIGEST_BYTES; index += 1) {
    const byte = view.getUint8(offset + index)
    text += byte.toString(HEX_RADIX).padStart(HEX_DIGITS_PER_BYTE, "0")
  }

  return text
}

function shardFileName(sha256) {
  return packedFileName({kind: PackedKind.intersectionShard, sha256})
}

/**
 * The shards of `bytes`, the expanded container of an index:
 * `{kind: "decoded", table}`, where `table` is `{shardCount, prefixes,
 * paths, byteSizes, sha256s}`, one entry per shard in the order of their
 * prefixes: `prefixes` is an array of strings, a prefix ending in `$` for the
 * shard of the streets named by the prefix alone; `byteSizes` is a
 * `Uint32Array` of the sizes of the shards' gzip streams; `sha256s` is an
 * array of the streams' SHA-256 as lower case hexadecimal; and `paths` is the
 * file name of each shard, which the index does not hold: `packedFileName`
 * names it from the digest, in the index's directory. A refusal has the
 * reasons of `decodeIntersectionShard`.
 */
export function decodeIntersectionIndex(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.intersectionIndex,
    versions: [INTERSECTION_FILE_VERSION],
    sectionCount: INDEX_SECTION_COUNT,
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const shardCount = container.header.recordCount

  const prefixes = stringIndexes({container, index: IntersectionIndexSection.prefixes, count: shardCount})
  const sizes = column({container, index: IntersectionIndexSection.byteSizes, type: ColumnType.u32, count: shardCount})
  const digests = container.sections[IntersectionIndexSection.digests]
  const refusal = firstRefusal([prefixes, sizes])

  if (refusal.kind === PackedOutcome.refused) {
    return refusal
  }

  if (digests.byteLength !== shardCount * DIGEST_BYTES) {
    return refused(PackedRefusal.badSectionSize)
  }

  const byteSizes = new Uint32Array(shardCount)
  const sha256s = new Array(shardCount)
  const strings = allStrings(container.strings)

  for (let shard = 0; shard < shardCount; shard += 1) {
    byteSizes[shard] = sizes.at(shard)
    sha256s[shard] = hexOf({view: container.view, offset: digests.offset + shard * DIGEST_BYTES})
  }

  const table = {
    shardCount,
    prefixes: Array.from(prefixes.indexes, (index) => strings[index]),
    paths: Array.from(sha256s, shardFileName),
    byteSizes,
    sha256s,
  }

  return {kind: PackedOutcome.decoded, table}
}

async function loadExpanded({source, expandedByteSizeMax}) {
  assertCondition(source !== undefined, "the source must be given")
  assertCondition(source !== null, "the source must not be null")
  return expandStream(source, {expandedByteSizeMax})
}

/**
 * The streets of `source`, a fetched shard, its gzip stream as bytes or a
 * ReadableStream: the result of `decodeIntersectionShard` after expanding it
 * to at most `INTERSECTION_SHARD_EXPANDED_BYTES_MAX` bytes, or a refusal of
 * the expansion.
 */
export async function loadIntersectionShard(source) {
  const expanded = await loadExpanded({source, expandedByteSizeMax: INTERSECTION_SHARD_EXPANDED_BYTES_MAX})

  if (expanded.kind === PackedOutcome.refused) {
    return expanded
  }

  return decodeIntersectionShard(expanded.bytes)
}

/**
 * The shards of `source`, a fetched index: the result of
 * `decodeIntersectionIndex` after expanding it to at most
 * `INTERSECTION_INDEX_EXPANDED_BYTES_MAX` bytes, or a refusal of the
 * expansion.
 */
export async function loadIntersectionIndex(source) {
  const expanded = await loadExpanded({source, expandedByteSizeMax: INTERSECTION_INDEX_EXPANDED_BYTES_MAX})

  if (expanded.kind === PackedOutcome.refused) {
    return expanded
  }

  return decodeIntersectionIndex(expanded.bytes)
}
