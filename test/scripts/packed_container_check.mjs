// Decodes the shared packed container fixture with the JavaScript core,
// expanded and as a gzip stream, and compares the values with the expected
// values the fixture holds beside it, then checks that each rule a
// container can break is refused as a value: another kind, an unknown kind
// version, a bad magic, a reserved field that is not zero, a cut file, bytes
// after the last section, another section count, an over-long varint,
// invalid UTF-8, and an expanded size past the bound. It also checks the
// kind table against the table file beside the fixture. Run it with
// `node test/scripts/packed_container_check.mjs`; it exits non-zero on the
// first result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual} from "node:assert/strict"
import {
  ColumnType,
  HEADER_BYTES,
  KINDS,
  PackedKind,
  PackedOutcome,
  PackedRefusal,
  packedFileName,
  SectionCursor,
  UNKNOWN_MICRODEGREES,
  decodeContainer,
  openColumn,
  openPositions,
} from "../../assets/js/core/packed_container.js"
import {expandStream} from "../../assets/js/packed_stream.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/packed/core-v1/", import.meta.url))
const kindsPath = fileURLToPath(new URL("../fixtures/packed/kinds.json", import.meta.url))
const FIXTURE_VERSION = 1
const SECTION_COUNT = 6
const SECTION_COUNT_BELOW = 5
const SECTION_COUNT_ABOVE = 7
const VERSION_SECOND = 2
const VERSION_THIRD = 3
const UNKNOWN_VERSIONS = Object.freeze([VERSION_SECOND, VERSION_THIRD])
const COORDINATE_COUNT = 2
const BOUND_BYTES = 16
const TRUNCATED_STREAM_BYTES = 8
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const RESERVED_OFFSET = 12
const MAGIC_LAST_OFFSET = 3
const SHORT_FILE_BYTES = 10
const U32_BYTES = 4
const TEXT_ENCODER = new TextEncoder()
const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const options = {kind: PackedKind.fixture, versions: [FIXTURE_VERSION], sectionCount: SECTION_COUNT}
const tableOptions = {...options, sectionCount: 0}

// Table bytes as hexadecimal text, each a table section of the fixture kind
// that breaks one rule of the string table.
const OVERLONG_VARINT_TABLE = "01000000" + "808080808001"
const INVALID_UTF8_TABLE = "01000000" + "02c328"
const TRAILING_TABLE = "01000000" + "016100"
const SHORT_COUNT_TABLE = "03000000" + "0161"
const VARINT_PAST_32_BITS = "ffffffff1f00"
const UNKNOWN_ON_ONE_AXIS = "00000080" + "00000000"
const UNKNOWN_KIND_HEX = "6300"
const NON_ZERO_RESERVED_HEX = "01"
const BAD_MAGIC_HEX = "58"
const TRAILING_BYTE_HEX = "00"

function fileBytes(name) {
  return new Uint8Array(readFileSync(fixtureDirectory + name))
}

function hexBytes(hex) {
  return new Uint8Array(Buffer.from(hex, "hex"))
}

function refusal(reason) {
  return {kind: PackedOutcome.refused, reason}
}

function decodedOf(result) {
  deepStrictEqual(result.kind, PackedOutcome.decoded)
  return result
}

function columnValues({container, sectionIndex, type}) {
  const section = container.sections[sectionIndex]
  const column = decodedOf(openColumn({view: container.view, section, type, count: container.header.recordCount}))
  return Array.from({length: column.count}, (_, index) => column.at(index))
}

function positionValues({container, sectionIndex}) {
  const section = container.sections[sectionIndex]
  const positions = decodedOf(openPositions({view: container.view, section, count: container.header.recordCount}))
  const values = []

  for (let index = 0; index < positions.count; index += 1) {
    const latitude = positions.latitudeAt(index)
    const longitude = positions.longitudeAt(index)

    if (positions.isKnownAt(index)) {
      values.push([latitude, longitude])
    } else {
      deepStrictEqual([latitude, longitude], [UNKNOWN_MICRODEGREES, UNKNOWN_MICRODEGREES])
      values.push(null)
    }
  }

  return values
}

function pathValues({container, sectionIndex}) {
  const section = container.sections[sectionIndex]
  const cursor = new SectionCursor({view: container.view, section})
  const paths = []

  while (cursor.remaining() > 0) {
    const points = cursor.readPath()
    deepStrictEqual(cursor.refusal, null)
    const path = []

    for (let index = 0; index < points.length; index += COORDINATE_COUNT) {
      path.push([points[index], points[index + 1]])
    }

    paths.push(path)
  }

  return paths
}

function varintValues({container, sectionIndex}) {
  const section = container.sections[sectionIndex]
  const cursor = new SectionCursor({view: container.view, section})
  const values = []

  while (cursor.remaining() > 0) {
    values.push(cursor.readVarint())
    deepStrictEqual(cursor.refusal, null)
  }

  return values
}

function valuesOf(container) {
  const strings = Array.from({length: container.strings.count}, (_, index) => container.strings.at(index))
  return {
    kind: container.header.kind,
    version: container.header.version,
    recordCount: container.header.recordCount,
    strings,
    u32: columnValues({container, sectionIndex: 0, type: ColumnType.u32}),
    i32: columnValues({container, sectionIndex: 1, type: ColumnType.i32}),
    u16Strings: columnValues({container, sectionIndex: 2, type: ColumnType.u16}),
    positions: positionValues({container, sectionIndex: 3}),
    paths: pathValues({container, sectionIndex: 4}),
    varints: varintValues({container, sectionIndex: 5}),
  }
}

// The fixture's bytes with the bytes of `hex` written at `offset`.
function patched({offset, hex}) {
  const copy = fileBytes("fixture.bin")
  copy.set(hexBytes(hex), offset)
  return copy
}

// A container of the fixture kind whose string table section is `hex`.
function withTable(hex) {
  const table = hexBytes(hex)
  const out = new Uint8Array(HEADER_BYTES + U32_BYTES + table.length)
  out.set(fileBytes("fixture.bin").slice(0, HEADER_BYTES), 0)
  new DataView(out.buffer).setUint32(HEADER_BYTES, table.length, true)
  out.set(table, HEADER_BYTES + U32_BYTES)
  return out
}

function withTrailingByte(bytes) {
  const out = new Uint8Array(bytes.length + 1)
  out.set(bytes, 0)
  out.set(hexBytes(TRAILING_BYTE_HEX), bytes.length)
  return out
}

const expanded = fileBytes("fixture.bin")
const direct = decodedOf(decodeContainer(expanded, options))
deepStrictEqual(valuesOf(direct), expected)

const stream = fileBytes("fixture.bin.gz")
const expandedStream = await expandStream(stream, {expandedByteSizeMax: expanded.byteLength})
deepStrictEqual(expandedStream.kind, PackedOutcome.expanded)
const fromStream = decodedOf(decodeContainer(expandedStream.bytes, options))
deepStrictEqual(valuesOf(fromStream), expected)

const blob = new Blob([stream])
const bareStream = await expandStream(blob.stream(), {expandedByteSizeMax: expanded.byteLength})
deepStrictEqual(bareStream.bytes, expanded)

const tooLarge = await expandStream(stream, {expandedByteSizeMax: BOUND_BYTES})
deepStrictEqual(tooLarge, refusal(PackedRefusal.tooLarge))

const cutStream = stream.slice(0, stream.byteLength - TRUNCATED_STREAM_BYTES)
const cut = await expandStream(cutStream, {expandedByteSizeMax: expanded.byteLength})
deepStrictEqual(cut, refusal(PackedRefusal.corrupt))

const notGzip = TEXT_ENCODER.encode("not gzip")
const corrupt = await expandStream(notGzip, {expandedByteSizeMax: expanded.byteLength})
deepStrictEqual(corrupt, refusal(PackedRefusal.corrupt))

const kinds = JSON.parse(readFileSync(kindsPath, "utf-8"))
const frozenKinds = JSON.stringify(KINDS)
deepStrictEqual(JSON.parse(frozenKinds), kinds)

const refusals = [
  {name: "another kind", bytes: expanded, options: {...options, kind: PackedKind.tripPathShard}, reason: PackedRefusal.kindMismatch},
  {name: "an unknown kind version", bytes: expanded, options: {...options, versions: UNKNOWN_VERSIONS}, reason: PackedRefusal.unsupportedVersion},
  {name: "a bad magic", bytes: patched({offset: MAGIC_LAST_OFFSET, hex: BAD_MAGIC_HEX}), options, reason: PackedRefusal.badMagic},
  {name: "a kind not in the table", bytes: patched({offset: KIND_OFFSET, hex: UNKNOWN_KIND_HEX}), options, reason: PackedRefusal.unknownKind},
  {name: "a reserved field that is not zero", bytes: patched({offset: RESERVED_OFFSET, hex: NON_ZERO_RESERVED_HEX}), options, reason: PackedRefusal.reservedNotZero},
  {name: "a file shorter than its header", bytes: expanded.slice(0, SHORT_FILE_BYTES), options, reason: PackedRefusal.truncated},
  {name: "a file cut in a section", bytes: expanded.slice(0, expanded.byteLength - 1), options, reason: PackedRefusal.truncated},
  {name: "bytes after the last section", bytes: withTrailingByte(expanded), options, reason: PackedRefusal.trailingBytes},
  {name: "fewer sections than the kind", bytes: expanded, options: {...options, sectionCount: SECTION_COUNT_ABOVE}, reason: PackedRefusal.sectionCount},
  {name: "more sections than the kind", bytes: expanded, options: {...options, sectionCount: SECTION_COUNT_BELOW}, reason: PackedRefusal.sectionCount},
  {name: "an over-long varint in the string table", bytes: withTable(OVERLONG_VARINT_TABLE), options: tableOptions, reason: PackedRefusal.badVarint},
  {name: "invalid UTF-8 in the string table", bytes: withTable(INVALID_UTF8_TABLE), options: tableOptions, reason: PackedRefusal.badUtf8},
  {name: "bytes after the last string table entry", bytes: withTable(TRAILING_TABLE), options: tableOptions, reason: PackedRefusal.badStringTable},
  {name: "more string table entries than bytes", bytes: withTable(SHORT_COUNT_TABLE), options: tableOptions, reason: PackedRefusal.truncated},
]

for (const {name, bytes, options: refusedOptions, reason} of refusals) {
  const result = decodeContainer(bytes, refusedOptions)
  deepStrictEqual(result, refusal(reason), name)
}

// A reader that knows several versions accepts a file of any of them.
const version = decodeContainer(patched({offset: VERSION_OFFSET, hex: "02"}), {...options, versions: UNKNOWN_VERSIONS})
deepStrictEqual(decodedOf(version).header.version, UNKNOWN_VERSIONS[0])

const varintBytes = hexBytes(VARINT_PAST_32_BITS)
const varintView = new DataView(varintBytes.buffer)
const varintCursor = new SectionCursor({view: varintView, section: {offset: 0, byteLength: varintBytes.length}})
varintCursor.readVarint()
deepStrictEqual(varintCursor.refusal, PackedRefusal.badVarint, "a varint past 32 bits")

const oneAxisBytes = hexBytes(UNKNOWN_ON_ONE_AXIS)
const oneAxisView = new DataView(oneAxisBytes.buffer)
const oneAxisSection = {offset: 0, byteLength: oneAxisBytes.length}
const oneAxis = openPositions({view: oneAxisView, section: oneAxisSection, count: 1})
deepStrictEqual(oneAxis, refusal(PackedRefusal.badPosition))

const SHA256_BYTES = 32
const FILE_NAME_SHA256 = "ab".repeat(SHA256_BYTES)
deepStrictEqual(
  packedFileName({kind: PackedKind.addressShard, sha256: FILE_NAME_SHA256}),
  `addresses-${FILE_NAME_SHA256}.bin.gz`,
)
deepStrictEqual(
  packedFileName({kind: PackedKind.addressIndex, sha256: FILE_NAME_SHA256}),
  `addresses-index-${FILE_NAME_SHA256}.bin.gz`,
)

console.log("packed container: the fixture decodes to expected.json")
