// Decodes the shared address fixtures, a shard and an index, expanded and as
// gzip streams, and compares each table with the expected one the fixtures
// hold beside them, then checks the refusals as values: another version,
// the other kind, another section count, an index past the string table, a
// column of another length, numbers cut short or followed by bytes, a suffix
// that is not a letter, a path of another length, a position past the globe,
// a digest section of another length, and an expansion past each kind's
// bound. Run it with `node test/scripts/address_file_check.mjs`; it exits
// non-zero on the first result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual} from "node:assert/strict"
import {
  ADDRESS_INDEX_EXPANDED_BYTES_MAX,
  ADDRESS_SHARD_EXPANDED_BYTES_MAX,
  AddressFileRefusal,
  AddressIndexSection,
  AddressShardSection,
  decodeAddressIndex,
  decodeAddressShard,
  loadAddressIndex,
  loadAddressShard,
} from "../../assets/js/address_file.js"
import {PackedOutcome, PackedRefusal} from "../../assets/js/core/packed_container.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/addresses/v1/", import.meta.url))
const HEADER_BYTES = 16
const VERSION_OFFSET = 4
const VERSION_SECOND = 2
const U32_BYTES = 4
const VARINT_BASE = 128
const STRING_TABLE_SECTIONS = 1
const NAME_PAST_TABLE = 999
const COUNT_PAST_SECTION = 328
const PATH_COUNT_PAST_SECTION = 4
const ZIGZAG_FACTOR = 2
const FIXTURE_STREET_COUNT = 5
const FIXTURE_SHARD_COUNT = 4
const DIGEST_BYTES = 32
const NOT_A_LETTER = 49
const ZIGZAG_MAX_MAGNITUDE = 2_147_483_647
const PATH_PADDING_BYTES = 8
const BOUND_PAD_BYTES = 16
const LITTLE_ENDIAN = true
const SUFFIX_NONE = 0

const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const shardBytes = new Uint8Array(readFileSync(fixtureDirectory + "shard.bin"))
const shardStream = new Uint8Array(readFileSync(fixtureDirectory + "shard.bin.gz"))
const indexBytes = new Uint8Array(readFileSync(fixtureDirectory + "index.bin"))
const indexStream = new Uint8Array(readFileSync(fixtureDirectory + "index.bin.gz"))

function suffixText(code) {
  if (code === SUFFIX_NONE) {
    return ""
  }

  return String.fromCharCode(code)
}

function plainShard(table) {
  const text = (indexes) => Array.from(indexes, (index) => table.strings[index])

  return {
    streetCount: table.streetCount,
    names: text(table.names),
    preDirections: text(table.preDirections),
    types: text(table.types),
    sufDirections: text(table.sufDirections),
    cities: text(table.cities),
    addressStarts: Array.from(table.addressStarts),
    numbers: Array.from(table.numbers),
    suffixes: Array.from(table.suffixes, suffixText),
    positions: Array.from(table.positions),
  }
}

function plainIndex(table) {
  return {
    shardCount: table.shardCount,
    prefixes: table.prefixes,
    paths: table.paths,
    byteSizes: Array.from(table.byteSizes),
    sha256s: table.sha256s,
  }
}

function varint(value) {
  const bytes = []
  let rest = value

  while (rest >= VARINT_BASE) {
    bytes.push((rest % VARINT_BASE) + VARINT_BASE)
    rest = Math.floor(rest / VARINT_BASE)
  }

  bytes.push(rest)
  return bytes
}

function zigzag(value) {
  if (value >= 0) {
    return ZIGZAG_FACTOR * value
  }

  return -ZIGZAG_FACTOR * value - 1
}

// The indexes 0 up to `count`, one after another.
function indexRun(count) {
  const indexes = []

  for (let index = 0; index < count; index += 1) {
    indexes.push(index)
  }

  return indexes
}

function u32Column(values) {
  const bytes = new Uint8Array(values.length * U32_BYTES)
  const view = new DataView(bytes.buffer)
  for (const [index, value] of values.entries()) {
    view.setUint32(index * U32_BYTES, value, LITTLE_ENDIAN)
  }
  return bytes
}

// The bytes of `source` with section `index`, counted from the string table
// at 0, replaced by `replacement`.
function withSection({source, index, replacement}) {
  const view = new DataView(source.buffer, source.byteOffset, source.byteLength)
  const parts = [source.slice(0, HEADER_BYTES)]
  let offset = HEADER_BYTES
  let position = 0

  while (offset < source.byteLength) {
    const length = view.getUint32(offset, LITTLE_ENDIAN)
    let section = source.slice(offset + U32_BYTES, offset + U32_BYTES + length)

    if (position === index) {
      section = Uint8Array.from(replacement)
    }

    const prefix = new Uint8Array(U32_BYTES)
    new DataView(prefix.buffer).setUint32(0, section.byteLength, LITTLE_ENDIAN)
    parts.push(prefix, section)
    offset += U32_BYTES + length
    position += 1
  }

  const joined = []

  for (const part of parts) {
    for (const byte of part) {
      joined.push(byte)
    }
  }

  return Uint8Array.from(joined)
}

function sectionOf({source, index}) {
  const view = new DataView(source.buffer, source.byteOffset, source.byteLength)
  let offset = HEADER_BYTES

  for (let position = 0; position < index; position += 1) {
    offset += U32_BYTES + view.getUint32(offset, LITTLE_ENDIAN)
  }

  const length = view.getUint32(offset, LITTLE_ENDIAN)
  return source.slice(offset + U32_BYTES, offset + U32_BYTES + length)
}

function expectRefusal({label, result, reason}) {
  deepStrictEqual(result, {kind: PackedOutcome.refused, reason}, label)
}

function shardWith({section, replacement}) {
  return withSection({source: shardBytes, index: section + STRING_TABLE_SECTIONS, replacement})
}

function indexWith({section, replacement}) {
  return withSection({source: indexBytes, index: section + STRING_TABLE_SECTIONS, replacement})
}

function checkDecodes() {
  const shard = decodeAddressShard(shardBytes)
  deepStrictEqual(shard.kind, PackedOutcome.decoded)
  deepStrictEqual(plainShard(shard.table), expected.shard, "the expanded shard")

  const index = decodeAddressIndex(indexBytes)
  deepStrictEqual(index.kind, PackedOutcome.decoded)
  deepStrictEqual(plainIndex(index.table), expected.index, "the expanded index")
}

async function checkLoads() {
  const shard = await loadAddressShard(shardStream)
  deepStrictEqual(shard.kind, PackedOutcome.decoded)
  deepStrictEqual(plainShard(shard.table), expected.shard, "the gzip shard")

  const index = await loadAddressIndex(indexStream)
  deepStrictEqual(index.kind, PackedOutcome.decoded)
  deepStrictEqual(plainIndex(index.table), expected.index, "the gzip index")
}

function checkHeaderRefusals() {
  const otherVersion = new Uint8Array(shardBytes)
  new DataView(otherVersion.buffer).setUint16(VERSION_OFFSET, VERSION_SECOND, LITTLE_ENDIAN)
  expectRefusal({label: "another version", result: decodeAddressShard(otherVersion), reason: PackedRefusal.unsupportedVersion})

  expectRefusal({label: "an index read as a shard", result: decodeAddressShard(indexBytes), reason: PackedRefusal.kindMismatch})
  expectRefusal({label: "a shard read as an index", result: decodeAddressIndex(shardBytes), reason: PackedRefusal.kindMismatch})

  const extraSection = new Uint8Array(shardBytes.byteLength + U32_BYTES)
  extraSection.set(shardBytes)
  expectRefusal({label: "another section count", result: decodeAddressShard(extraSection), reason: PackedRefusal.sectionCount})
}

function checkShardRefusals() {
  const namePast = shardWith({section: AddressShardSection.names, replacement: u32Column([...indexRun(FIXTURE_STREET_COUNT - 1), NAME_PAST_TABLE])})
  expectRefusal({label: "a name past the string table", result: decodeAddressShard(namePast), reason: AddressFileRefusal.badStringIndex})

  const shortColumn = shardWith({section: AddressShardSection.preDirections, replacement: u32Column([0])})
  expectRefusal({label: "a column of another length", result: decodeAddressShard(shortColumn), reason: PackedRefusal.badSectionSize})

  const countPastSection = shardWith({section: AddressShardSection.numbers, replacement: varint(COUNT_PAST_SECTION)})
  expectRefusal({label: "numbers cut short", result: decodeAddressShard(countPastSection), reason: AddressFileRefusal.badNumbers})

  const numbers = sectionOf({source: shardBytes, index: AddressShardSection.numbers + STRING_TABLE_SECTIONS})
  const leftover = shardWith({section: AddressShardSection.numbers, replacement: [...numbers, 0]})
  expectRefusal({label: "bytes after the numbers", result: decodeAddressShard(leftover), reason: AddressFileRefusal.badNumbers})

  const suffixes = sectionOf({source: shardBytes, index: AddressShardSection.suffixes + STRING_TABLE_SECTIONS})
  const notLetter = shardWith({section: AddressShardSection.suffixes, replacement: [NOT_A_LETTER, ...suffixes.slice(1)]})
  expectRefusal({label: "a suffix that is not a letter", result: decodeAddressShard(notLetter), reason: AddressFileRefusal.badSuffix})

  const shortSuffixes = shardWith({section: AddressShardSection.suffixes, replacement: [0]})
  expectRefusal({label: "a suffix column of another length", result: decodeAddressShard(shortSuffixes), reason: PackedRefusal.badSectionSize})

  const positions = sectionOf({source: shardBytes, index: AddressShardSection.positions + STRING_TABLE_SECTIONS})
  const onePoint = [...varint(1), ...varint(zigzag(1)), ...varint(zigzag(1))]
  const mismatched = shardWith({section: AddressShardSection.positions, replacement: [...onePoint, ...positions]})
  expectRefusal({label: "a path of another length", result: decodeAddressShard(mismatched), reason: AddressFileRefusal.countMismatch})

  const pastGlobe = [...varint(PATH_COUNT_PAST_SECTION), ...varint(zigzag(ZIGZAG_MAX_MAGNITUDE)), 0, ...new Array(PATH_PADDING_BYTES).fill(0)]
  const badPosition = shardWith({section: AddressShardSection.positions, replacement: pastGlobe})
  expectRefusal({label: "a position past the globe", result: decodeAddressShard(badPosition), reason: PackedRefusal.badPosition})
}

function checkIndexRefusals() {
  const prefixPast = indexWith({section: AddressIndexSection.prefixes, replacement: u32Column([...indexRun(FIXTURE_SHARD_COUNT - 1), NAME_PAST_TABLE])})
  expectRefusal({label: "a prefix past the string table", result: decodeAddressIndex(prefixPast), reason: AddressFileRefusal.badStringIndex})

  const shortDigests = indexWith({section: AddressIndexSection.digests, replacement: new Array(DIGEST_BYTES).fill(0)})
  expectRefusal({label: "digests of another length", result: decodeAddressIndex(shortDigests), reason: PackedRefusal.badSectionSize})
}

async function checkBounds() {
  for (const {load, bound, label} of [
    {load: loadAddressShard, bound: ADDRESS_SHARD_EXPANDED_BYTES_MAX, label: "a shard"},
    {load: loadAddressIndex, bound: ADDRESS_INDEX_EXPANDED_BYTES_MAX, label: "an index"},
  ]) {
    const tooLarge = new Uint8Array(bound + BOUND_PAD_BYTES)
    const compressedStream = new Blob([tooLarge]).stream().pipeThrough(new CompressionStream("gzip"))
    const compressed = await new Response(compressedStream).arrayBuffer()
    const result = await load(new Uint8Array(compressed))
    expectRefusal({label: `${label} expanding past its bound`, result, reason: PackedRefusal.tooLarge})
  }
}

checkDecodes()
await checkLoads()
checkHeaderRefusals()
checkShardRefusals()
checkIndexRefusals()
await checkBounds()
console.log("address_file_check: ok")
