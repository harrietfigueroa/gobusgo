// Decodes the shared packed container fixture, expanded and as a gzip
// stream, and compares the values with the expected values the fixture
// holds beside it, then checks that each rule a container can break is
// refused as a value: another kind, an unknown kind version, a bad magic, a
// reserved field that is not zero, a cut file, bytes after the last section,
// another section count, an over-long varint, invalid UTF-8, and an expanded
// size past the bound. It also checks the kind table against the table file
// beside the fixture. The gzip expansion is the web shell's, so its cases run
// once; the decoding runs once per implementation.

import {beforeAll, describe, expect, test} from "vitest"
import {expandStream} from "../../../assets/js/packed_stream.js"
import {fixtureBytes, fixtureJson} from "../fixtures.mjs"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const DIRECTORY = "packed/core-v1/"
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
const HEX_RADIX = 16
const HEX_DIGITS_PER_BYTE = 2
const SHA256_BYTES = 32
const TEXT_ENCODER = new TextEncoder()

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

let expected = null
let kinds = null
let expandedBuffer = null
let streamBuffer = null

beforeAll(async () => {
  expected = await fixtureJson(DIRECTORY + "expected.json")
  kinds = await fixtureJson("packed/kinds.json")
  expandedBuffer = await fixtureBytes(DIRECTORY + "fixture.bin")
  streamBuffer = await fixtureBytes(DIRECTORY + "fixture.bin.gz")
})

// A fresh copy each time, so a case that patches its bytes changes no other
// case's.
function fileBytes() {
  return new Uint8Array(expandedBuffer.slice(0))
}

function streamBytes() {
  return new Uint8Array(streamBuffer.slice(0))
}

function hexBytes(hex) {
  const byteCount = Math.trunc(hex.length / HEX_DIGITS_PER_BYTE)
  const bytes = new Uint8Array(byteCount)

  for (let index = 0; index < byteCount; index++) {
    const start = index * HEX_DIGITS_PER_BYTE
    bytes[index] = Number.parseInt(hex.slice(start, start + HEX_DIGITS_PER_BYTE), HEX_RADIX)
  }

  return bytes
}

// The fixture's bytes with the bytes of `hex` written at `offset`.
function patched({offset, hex}) {
  const copy = fileBytes()
  copy.set(hexBytes(hex), offset)
  return copy
}

function withTrailingByte(bytes) {
  const out = new Uint8Array(bytes.length + 1)
  out.set(bytes, 0)
  out.set(hexBytes(TRAILING_BYTE_HEX), bytes.length)
  return out
}

describe("packed stream", () => {
  // The shell's refusal values are the core's, so the JavaScript core names
  // them here.
  const {PackedOutcome, PackedRefusal} = IMPLEMENTATIONS[0].packedContainer

  function refusal(reason) {
    return {kind: PackedOutcome.refused, reason}
  }

  test("a gzip stream expands to the container's bytes", async () => {
    const expanded = fileBytes()
    const result = await expandStream(streamBytes(), {expandedByteSizeMax: expanded.byteLength})
    expect(result.kind).toBe(PackedOutcome.expanded)
    expect(result.bytes).toStrictEqual(expanded)
  })

  test("a bare ReadableStream expands to the container's bytes", async () => {
    const expanded = fileBytes()
    const blob = new Blob([streamBytes()])
    const bareStream = await expandStream(blob.stream(), {expandedByteSizeMax: expanded.byteLength})
    expect(bareStream.bytes).toStrictEqual(expanded)
  })

  test("an expanded size past the bound", async () => {
    const tooLarge = await expandStream(streamBytes(), {expandedByteSizeMax: BOUND_BYTES})
    expect(tooLarge).toStrictEqual(refusal(PackedRefusal.tooLarge))
  })

  test("a stream cut short", async () => {
    const stream = streamBytes()
    const cutStream = stream.slice(0, stream.byteLength - TRUNCATED_STREAM_BYTES)
    const cut = await expandStream(cutStream, {expandedByteSizeMax: expandedBuffer.byteLength})
    expect(cut).toStrictEqual(refusal(PackedRefusal.corrupt))
  })

  test("bytes that are no gzip", async () => {
    const notGzip = TEXT_ENCODER.encode("not gzip")
    const corrupt = await expandStream(notGzip, {expandedByteSizeMax: expandedBuffer.byteLength})
    expect(corrupt).toStrictEqual(refusal(PackedRefusal.corrupt))
  })
})

describe.each(IMPLEMENTATIONS)("packed container ($name)", ({packedContainer}) => {
  const {
    ColumnType,
    HEADER_BYTES,
    KINDS,
    PackedKind,
    PackedOutcome,
    PackedRefusal,
    SectionCursor,
    UNKNOWN_MICRODEGREES
  } = packedContainer
  const options = {kind: PackedKind.fixture, versions: [FIXTURE_VERSION], sectionCount: SECTION_COUNT}
  const tableOptions = {...options, sectionCount: 0}

  function refusal(reason) {
    return {kind: PackedOutcome.refused, reason}
  }

  function decodedOf(result) {
    expect(result.kind).toBe(PackedOutcome.decoded)
    return result
  }

  function columnValues({container, sectionIndex, type}) {
    const section = container.sections[sectionIndex]
    const column = decodedOf(packedContainer.openColumn({view: container.view, section, type, count: container.header.recordCount}))
    return Array.from({length: column.count}, (_, index) => column.at(index))
  }

  function positionValues({container, sectionIndex}) {
    const section = container.sections[sectionIndex]
    const positions = decodedOf(packedContainer.openPositions({view: container.view, section, count: container.header.recordCount}))
    const values = []

    for (let index = 0; index < positions.count; index += 1) {
      const latitude = positions.latitudeAt(index)
      const longitude = positions.longitudeAt(index)

      if (positions.isKnownAt(index)) {
        values.push([latitude, longitude])
      } else {
        expect([latitude, longitude]).toStrictEqual([UNKNOWN_MICRODEGREES, UNKNOWN_MICRODEGREES])
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
      expect(cursor.refusal).toBe(null)
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
      expect(cursor.refusal).toBe(null)
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
      varints: varintValues({container, sectionIndex: 5})
    }
  }

  // A container of the fixture kind whose string table section is `hex`.
  function withTable(hex) {
    const table = hexBytes(hex)
    const out = new Uint8Array(HEADER_BYTES + U32_BYTES + table.length)
    const header = fileBytes().slice(0, HEADER_BYTES)
    out.set(header, 0)
    new DataView(out.buffer).setUint32(HEADER_BYTES, table.length, true)
    out.set(table, HEADER_BYTES + U32_BYTES)
    return out
  }

  test("the expanded fixture decodes to the expected values", () => {
    const bytes = fileBytes()
    const direct = decodedOf(packedContainer.decodeContainer(bytes, options))
    expect(valuesOf(direct)).toStrictEqual(expected)
  })

  test("the fixture expanded from its gzip stream decodes to the expected values", async () => {
    const expandedStream = await expandStream(streamBytes(), {expandedByteSizeMax: expandedBuffer.byteLength})
    expect(expandedStream.kind).toBe(PackedOutcome.expanded)
    const fromStream = decodedOf(packedContainer.decodeContainer(expandedStream.bytes, options))
    expect(valuesOf(fromStream)).toStrictEqual(expected)
  })

  test("the kind table matches the table file", () => {
    const frozenKinds = JSON.stringify(KINDS)
    expect(JSON.parse(frozenKinds)).toStrictEqual(kinds)
  })

  const refusalCases = [
    {name: "another kind", bytes: () => fileBytes(), options: () => ({...options, kind: PackedKind.tripPathShard}), reason: PackedRefusal.kindMismatch},
    {name: "an unknown kind version", bytes: () => fileBytes(), options: () => ({...options, versions: UNKNOWN_VERSIONS}), reason: PackedRefusal.unsupportedVersion},
    {name: "a bad magic", bytes: () => patched({offset: MAGIC_LAST_OFFSET, hex: BAD_MAGIC_HEX}), options: () => options, reason: PackedRefusal.badMagic},
    {name: "a kind not in the table", bytes: () => patched({offset: KIND_OFFSET, hex: UNKNOWN_KIND_HEX}), options: () => options, reason: PackedRefusal.unknownKind},
    {name: "a reserved field that is not zero", bytes: () => patched({offset: RESERVED_OFFSET, hex: NON_ZERO_RESERVED_HEX}), options: () => options, reason: PackedRefusal.reservedNotZero},
    {name: "a file shorter than its header", bytes: () => fileBytes().slice(0, SHORT_FILE_BYTES), options: () => options, reason: PackedRefusal.truncated},
    {name: "a file cut in a section", bytes: () => fileBytes().slice(0, expandedBuffer.byteLength - 1), options: () => options, reason: PackedRefusal.truncated},
    {name: "bytes after the last section", bytes: () => withTrailingByte(fileBytes()), options: () => options, reason: PackedRefusal.trailingBytes},
    {name: "fewer sections than the kind", bytes: () => fileBytes(), options: () => ({...options, sectionCount: SECTION_COUNT_ABOVE}), reason: PackedRefusal.sectionCount},
    {name: "more sections than the kind", bytes: () => fileBytes(), options: () => ({...options, sectionCount: SECTION_COUNT_BELOW}), reason: PackedRefusal.sectionCount},
    {name: "an over-long varint in the string table", bytes: () => withTable(OVERLONG_VARINT_TABLE), options: () => tableOptions, reason: PackedRefusal.badVarint},
    {name: "invalid UTF-8 in the string table", bytes: () => withTable(INVALID_UTF8_TABLE), options: () => tableOptions, reason: PackedRefusal.badUtf8},
    {name: "bytes after the last string table entry", bytes: () => withTable(TRAILING_TABLE), options: () => tableOptions, reason: PackedRefusal.badStringTable},
    {name: "more string table entries than bytes", bytes: () => withTable(SHORT_COUNT_TABLE), options: () => tableOptions, reason: PackedRefusal.truncated}
  ]

  test.each(refusalCases)("refused: $name", ({bytes, options: refusedOptions, reason}) => {
    const result = packedContainer.decodeContainer(bytes(), refusedOptions())
    expect(result).toStrictEqual(refusal(reason))
  })

  // A reader that knows several versions accepts a file of any of them.
  test("a reader of several versions accepts any of them", () => {
    const secondVersion = patched({offset: VERSION_OFFSET, hex: "02"})
    const version = packedContainer.decodeContainer(secondVersion, {...options, versions: UNKNOWN_VERSIONS})
    expect(decodedOf(version).header.version).toBe(UNKNOWN_VERSIONS[0])
  })

  test("a varint past 32 bits", () => {
    const varintBytes = hexBytes(VARINT_PAST_32_BITS)
    const varintView = new DataView(varintBytes.buffer)
    const varintCursor = new SectionCursor({view: varintView, section: {offset: 0, byteLength: varintBytes.length}})
    varintCursor.readVarint()
    expect(varintCursor.refusal).toBe(PackedRefusal.badVarint)
  })

  test("a position unknown on one axis only", () => {
    const oneAxisBytes = hexBytes(UNKNOWN_ON_ONE_AXIS)
    const oneAxisView = new DataView(oneAxisBytes.buffer)
    const oneAxisSection = {offset: 0, byteLength: oneAxisBytes.length}
    const oneAxis = packedContainer.openPositions({view: oneAxisView, section: oneAxisSection, count: 1})
    expect(oneAxis).toStrictEqual(refusal(PackedRefusal.badPosition))
  })

  const fileNameSha256 = "ab".repeat(SHA256_BYTES)

  test("an address shard's file name", () => {
    const name = packedContainer.packedFileName({kind: PackedKind.addressShard, sha256: fileNameSha256})
    expect(name).toBe(`addresses-${fileNameSha256}.bin.gz`)
  })

  test("an address index's file name", () => {
    const name = packedContainer.packedFileName({kind: PackedKind.addressIndex, sha256: fileNameSha256})
    expect(name).toBe(`addresses-index-${fileNameSha256}.bin.gz`)
  })
})
