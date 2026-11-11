// The address files as Gobusgo.Addresses.Format writes them: packed
// containers of kind 3, a shard of streets, and kind 4, the index of the
// shards, both version 1. `decodeAddressShard` and `decodeAddressIndex` read
// the expanded bytes into typed columns and decoded strings, with no object
// per address; `loadAddressShard` and `loadAddressIndex` expand a fetched
// gzip stream under the kind's bound first. Each returns a result keyed by
// `kind`, the table or the reason the file was refused; a bad file is never
// a throw. Everything here is pure but the expansion.

import {assertCondition} from "./assert.js"
import {
  ColumnType,
  PackedKind,
  PackedOutcome,
  PackedRefusal,
  SectionCursor,
  VARINT_VALUE_MAX,
  decodeContainer,
  expandStream,
  openColumn,
  packedFileName,
} from "./packed_container.js"

const ADDRESS_FILE_VERSION = 1
const SHARD_SECTION_COUNT = 8
const INDEX_SECTION_COUNT = 3
const DIGEST_BYTES = 32
const COORDINATE_COUNT = 2
const SUFFIX_NONE = 0
const SUFFIX_LETTER_FIRST = 65
const SUFFIX_LETTER_LAST = 90
const BYTES_PER_MEBIBYTE = 1024 * 1024
const HEX_RADIX = 16
const HEX_DIGITS_PER_BYTE = 2
const SHARD_EXPANDED_MEBIBYTES_MAX = 1
const INDEX_EXPANDED_MEBIBYTES_MAX = 1

/** The most bytes an address shard may expand to. */
export const ADDRESS_SHARD_EXPANDED_BYTES_MAX = SHARD_EXPANDED_MEBIBYTES_MAX * BYTES_PER_MEBIBYTE

/** The most bytes an address index may expand to. */
export const ADDRESS_INDEX_EXPANDED_BYTES_MAX = INDEX_EXPANDED_MEBIBYTES_MAX * BYTES_PER_MEBIBYTE

/** The sections of the shard kind after the string table, in order. */
export const AddressShardSection = Object.freeze({
  names: 0,
  preDirections: 1,
  types: 2,
  sufDirections: 3,
  cities: 4,
  numbers: 5,
  suffixes: 6,
  positions: 7,
})

/** The sections of the index kind after the string table, in order. */
export const AddressIndexSection = Object.freeze({
  prefixes: 0,
  byteSizes: 1,
  digests: 2,
})

/** The reasons the kinds refuse a file for, beside the container's own. */
export const AddressFileRefusal = Object.freeze({
  badStringIndex: "badStringIndex",
  badNumbers: "badNumbers",
  badSuffix: "badSuffix",
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
      return refused(AddressFileRefusal.badStringIndex)
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

// The numbers of every street, rebuilt from their differences, and the
// starts of each street's addresses: street `s` holds addresses
// `addressStarts[s]` up to `addressStarts[s + 1]`. `total` is the count of
// addresses the suffix column holds.
function readNumbers({container, streetCount, total}) {
  const cursor = new SectionCursor({view: container.view, section: container.sections[AddressShardSection.numbers]})
  const numbers = new Uint32Array(total)
  const addressStarts = new Uint32Array(streetCount + 1)
  let filled = 0

  for (let street = 0; street < streetCount; street += 1) {
    const count = cursor.readVarint()
    const isRead = cursor.refusal === null
    const isCountFitting = count >= 1 && count <= cursor.remaining()
    const isCounted = isRead && isCountFitting

    if (!isCounted) {
      return refused(AddressFileRefusal.badNumbers)
    }

    if (filled + count > total) {
      return refused(PackedRefusal.badSectionSize)
    }

    let number = 0

    for (let index = 0; index < count; index += 1) {
      number += cursor.readVarint()

      const isNumberRefused = cursor.refusal !== null || number > VARINT_VALUE_MAX

      if (isNumberRefused) {
        return refused(AddressFileRefusal.badNumbers)
      }

      numbers[filled + index] = number
    }

    filled += count
    addressStarts[street + 1] = filled
  }

  if (cursor.remaining() !== 0) {
    return refused(AddressFileRefusal.badNumbers)
  }

  if (filled !== total) {
    return refused(PackedRefusal.badSectionSize)
  }

  return {kind: PackedOutcome.decoded, numbers, addressStarts}
}

function readSuffixes({container, total}) {
  const opened = column({container, index: AddressShardSection.suffixes, type: ColumnType.u8, count: total})

  if (opened.kind === PackedOutcome.refused) {
    return opened
  }

  const suffixes = new Uint8Array(total)

  for (let address = 0; address < total; address += 1) {
    const code = opened.at(address)
    const isNone = code === SUFFIX_NONE
    const isLetter = code >= SUFFIX_LETTER_FIRST && code <= SUFFIX_LETTER_LAST

    const isSuffix = isNone || isLetter

    if (!isSuffix) {
      return refused(AddressFileRefusal.badSuffix)
    }

    suffixes[address] = code
  }

  return {kind: PackedOutcome.decoded, suffixes}
}

// The positions of every address, latitude and longitude in turn, one path a
// street of as many points as the street has addresses.
function readPositions({container, addressStarts, total}) {
  const cursor = new SectionCursor({view: container.view, section: container.sections[AddressShardSection.positions]})
  const positions = new Int32Array(total * COORDINATE_COUNT)
  const streetCount = addressStarts.length - 1

  for (let street = 0; street < streetCount; street += 1) {
    const path = cursor.readPath()

    if (cursor.refusal !== null) {
      return refused(cursor.refusal)
    }

    const start = addressStarts[street]
    const count = addressStarts[street + 1] - start

    if (path.length !== count * COORDINATE_COUNT) {
      return refused(AddressFileRefusal.countMismatch)
    }

    positions.set(path, start * COORDINATE_COUNT)
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badSectionSize)
  }

  return {kind: PackedOutcome.decoded, positions}
}

// The five u32 columns of strings, or the first refusal.
function readStreetColumns({container, streetCount}) {
  const names = stringIndexes({container, index: AddressShardSection.names, count: streetCount})
  const pre = stringIndexes({container, index: AddressShardSection.preDirections, count: streetCount})
  const types = stringIndexes({container, index: AddressShardSection.types, count: streetCount})
  const suf = stringIndexes({container, index: AddressShardSection.sufDirections, count: streetCount})
  const cities = stringIndexes({container, index: AddressShardSection.cities, count: streetCount})
  const refusal = firstRefusal([names, pre, types, suf, cities])

  if (refusal.kind === PackedOutcome.refused) {
    return refusal
  }

  return {
    kind: PackedOutcome.decoded,
    names: names.indexes,
    preDirections: pre.indexes,
    types: types.indexes,
    sufDirections: suf.indexes,
    cities: cities.indexes,
  }
}

/**
 * The streets of `bytes`, the expanded container of a shard:
 * `{kind: "decoded", table}`, where `table` is `{streetCount, strings,
 * names, preDirections, types, sufDirections, cities, addressStarts,
 * numbers, suffixes, positions}`, or `{kind: "refused", reason}` with a
 * reason of the container or of `AddressFileRefusal`. `strings` is every
 * string of the file, and `names`, `preDirections`, `types`,
 * `sufDirections`, and `cities` are `Uint32Array`s of a street's indexes
 * into it. Street `s` holds the addresses `addressStarts[s]` up to
 * `addressStarts[s + 1]`, a `Uint32Array` of `streetCount + 1` starts into
 * `numbers`, a `Uint32Array` of house numbers that do not decrease within a
 * street, `suffixes`, a `Uint8Array` of 0 or the code of an upper case
 * letter, and `positions`, an `Int32Array` of latitude and longitude in
 * microdegrees, two a address.
 */
export function decodeAddressShard(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.addressShard,
    versions: [ADDRESS_FILE_VERSION],
    sectionCount: SHARD_SECTION_COUNT,
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const streetCount = container.header.recordCount
  const columns = readStreetColumns({container, streetCount})

  if (columns.kind === PackedOutcome.refused) {
    return columns
  }

  const total = container.sections[AddressShardSection.suffixes].byteLength
  const read = readNumbers({container, streetCount, total})

  if (read.kind === PackedOutcome.refused) {
    return read
  }

  const {numbers, addressStarts} = read
  const suffixes = readSuffixes({container, total})
  const positions = readPositions({container, addressStarts, total})
  const refusal = firstRefusal([suffixes, positions])

  if (refusal.kind === PackedOutcome.refused) {
    return refusal
  }

  const table = {
    streetCount,
    strings: allStrings(container.strings),
    names: columns.names,
    preDirections: columns.preDirections,
    types: columns.types,
    sufDirections: columns.sufDirections,
    cities: columns.cities,
    addressStarts,
    numbers,
    suffixes: suffixes.suffixes,
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

/**
 * The shards of `bytes`, the expanded container of an index:
 * `{kind: "decoded", table}`, where `table` is `{shardCount, prefixes,
 * paths, byteSizes, sha256s}`, one entry per shard in the order of their
 * prefixes: `prefixes` is an array of strings, a prefix ending in `$` for
 * the shard of the streets named by the prefix alone; `byteSizes` is a
 * `Uint32Array` of the sizes of the shards' gzip streams; `sha256s` is an
 * array of the streams' SHA-256 as lower case hexadecimal; and `paths` is
 * each shard's file name, relative to the index's directory, which the
 * index does not hold: `packedFileName` names it from the digest. A refusal
 * has the reasons of `decodeAddressShard`.
 */
export function decodeAddressIndex(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.addressIndex,
    versions: [ADDRESS_FILE_VERSION],
    sectionCount: INDEX_SECTION_COUNT,
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const shardCount = container.header.recordCount

  const prefixes = stringIndexes({container, index: AddressIndexSection.prefixes, count: shardCount})
  const sizes = column({container, index: AddressIndexSection.byteSizes, type: ColumnType.u32, count: shardCount})
  const digests = container.sections[AddressIndexSection.digests]
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

function shardFileName(sha256) {
  return packedFileName({kind: PackedKind.addressShard, sha256})
}

async function loadExpanded({source, expandedByteSizeMax}) {
  assertCondition(source !== undefined, "the source must be given")
  assertCondition(source !== null, "the source must not be null")
  return expandStream(source, {expandedByteSizeMax})
}

/**
 * The streets of `source`, a fetched shard, its gzip stream as bytes or a
 * ReadableStream: the result of `decodeAddressShard` after expanding it to
 * at most `ADDRESS_SHARD_EXPANDED_BYTES_MAX` bytes, or a refusal of the
 * expansion.
 */
export async function loadAddressShard(source) {
  const expanded = await loadExpanded({source, expandedByteSizeMax: ADDRESS_SHARD_EXPANDED_BYTES_MAX})

  if (expanded.kind === PackedOutcome.refused) {
    return expanded
  }

  return decodeAddressShard(expanded.bytes)
}

/**
 * The shards of `source`, a fetched index: the result of
 * `decodeAddressIndex` after expanding it to at most
 * `ADDRESS_INDEX_EXPANDED_BYTES_MAX` bytes, or a refusal of the expansion.
 */
export async function loadAddressIndex(source) {
  const expanded = await loadExpanded({source, expandedByteSizeMax: ADDRESS_INDEX_EXPANDED_BYTES_MAX})

  if (expanded.kind === PackedOutcome.refused) {
    return expanded
  }

  return decodeAddressIndex(expanded.bytes)
}
