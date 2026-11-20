// Decodes the shared packed container fixture, expanded and as a gzip
// stream, and compares the values with the expected values the fixture
// holds beside it, then checks that each rule a container, a section cursor,
// a column, or a positions section can break is refused as a value, from the
// shared refusal table beside the fixture, and that an expanded size past the
// bound is refused. It also checks the kind table against the table file
// beside the fixture. The gzip expansion is the web shell's, so its cases run
// once; the decoding runs once per implementation.

import {beforeAll, describe, expect, test} from "vitest"
import {expandStream} from "../../../assets/js/packed_stream.js"
import {editedBytes, hexBytes} from "../bytes.mjs"
import {fixtureBytes, fixtureJson} from "../fixtures.mjs"
import {IMPLEMENTATIONS, implementationsWith} from "../implementations.mjs"

const DIRECTORY = "packed/core-v1/"
const FIXTURE_VERSION = 1
const SECTION_COUNT = 6
const VERSION_SECOND = 2
const VERSION_THIRD = 3
const UNKNOWN_VERSIONS = Object.freeze([VERSION_SECOND, VERSION_THIRD])
const COORDINATE_COUNT = 2
const BOUND_BYTES = 16
const TRUNCATED_STREAM_BYTES = 8
const VERSION_OFFSET = 4
const U32_BYTES = 4
const SHA256_BYTES = 32
const TEXT_ENCODER = new TextEncoder()


// The cases name the tests, so they are read before the tests are collected.
const refusals = await fixtureJson(DIRECTORY + "refusals.json")

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

// The fixture's bytes with the bytes of `hex` written at `offset`.
function patched({offset, hex}) {
  return editedBytes(fileBytes(), [{write: {offset, hex}}])
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

describe.each(implementationsWith("packedContainer"))("packed container ($name)", ({packedContainer}) => {
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

  // The bytes a container case of the shared table decodes.
  function containerBytes(bytes) {
    if ("table" in bytes) {
      return withTable(bytes.table)
    }

    return editedBytes(fileBytes(), bytes.fixture)
  }

  test.each(refusals.containers)("refused: $name", ({bytes, options: overrides, reason}) => {
    const result = packedContainer.decodeContainer(containerBytes(bytes), {...options, ...overrides})
    expect(result).toStrictEqual(refusal(PackedRefusal[reason]))
  })

  // A section of its own bytes, over a view of them alone.
  function sectionOf(hex) {
    const bytes = hexBytes(hex)
    return {view: new DataView(bytes.buffer), section: {offset: 0, byteLength: bytes.length}}
  }

  test.each(refusals.cursors)("refused by a cursor: $name", ({hex, read, reason}) => {
    const cursor = new SectionCursor(sectionOf(hex))

    if (read === "path") {
      expect(cursor.readPath()).toStrictEqual(new Int32Array(0))
    } else {
      expect(cursor.readVarint()).toBe(0)
    }

    expect(cursor.refusal).toBe(PackedRefusal[reason])
  })

  // The section of a section case, opened as its table names.
  function opened({hex, open, columnType, count}) {
    const {view, section} = sectionOf(hex)

    if (open === "positions") {
      return packedContainer.openPositions({view, section, count})
    }

    return packedContainer.openColumn({view, section, type: ColumnType[columnType], count})
  }

  test.each(refusals.sections)("refused when opened: $name", (section) => {
    expect(opened(section)).toStrictEqual(refusal(PackedRefusal[section.reason]))
  })

  // A reader that knows several versions accepts a file of any of them.
  test("a reader of several versions accepts any of them", () => {
    const secondVersion = patched({offset: VERSION_OFFSET, hex: "02"})
    const version = packedContainer.decodeContainer(secondVersion, {...options, versions: UNKNOWN_VERSIONS})
    expect(decodedOf(version).header.version).toBe(UNKNOWN_VERSIONS[0])
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
