// The packed container every published data file of a kind added after the
// routing snapshot uses, as Gobusgo.Packed writes it: a 16-byte header,
// little-endian, of the magic "GBPK", a u16 kind version, a u16 kind, a u32
// record count, and a u32 reserved, zero, then sections, each a u32 byte
// length and that many bytes. Section 0 is the string table. A file is
// stored as one gzip stream; `expandStream` expands it under a bound, and
// `decodeContainer` reads the header and sections in place over one
// DataView. Each returns a result keyed by `kind`, the value or the reason
// the file was refused, and a bad file is never a throw. Everything here is
// pure but the expansion, which uses DecompressionStream.

import {assertCondition, unreachable} from "./assert.js"

const COMPRESSION_FORMAT = "gzip"
const TEXT_ENCODING = "utf-8"
const MAGIC_TEXT = "GBPK"
const LITTLE_ENDIAN = true
const STRING_TABLE_SECTION_INDEX = 0
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const RECORD_COUNT_OFFSET = 8
const RESERVED_OFFSET = 12
const U32_BYTES = 4
const I32_BYTES = 4
const COORDINATE_COUNT = 2
const POSITION_BYTES = COORDINATE_COUNT * I32_BYTES
const LATITUDE_MICRODEGREES_MAX = 90_000_000
const LONGITUDE_MICRODEGREES_MAX = 180_000_000
const VARINT_BASE = 128
const ZIGZAG_DIVISOR = 2
const FILE_SUFFIX = ".bin.gz"

/** The bytes of a header. */
export const HEADER_BYTES = 16

/** The largest value a varint holds. */
export const VARINT_VALUE_MAX = 4_294_967_295

/** The most bytes a varint takes. */
export const VARINT_BYTES_MAX = 5

/** The value of both axes of an unknown position. */
export const UNKNOWN_MICRODEGREES = -2_147_483_648

/** The most bytes a stored container expands to, the bound the server stores compressed content under. */
export const CONTAINER_EXPANDED_BYTES_MAX = 16 * 1024 * 1024

/** The numbers of the kinds, as the header holds them. */
export const PackedKind = Object.freeze({
  fixture: 0,
  tripPathShard: 1,
  tripPathIndex: 2,
  addressShard: 3,
  addressIndex: 4,
  places: 5,
})

/** The kind table: each kind's number, name, and the file prefix of its stored files. */
export const KINDS = Object.freeze([
  Object.freeze({number: PackedKind.fixture, name: "fixture", prefix: "fixture"}),
  Object.freeze({number: PackedKind.tripPathShard, name: "trip path shard", prefix: "trip-paths"}),
  Object.freeze({number: PackedKind.tripPathIndex, name: "trip path index", prefix: "trip-paths-index"}),
  Object.freeze({number: PackedKind.addressShard, name: "address shard", prefix: "addresses"}),
  Object.freeze({number: PackedKind.addressIndex, name: "address index", prefix: "addresses-index"}),
  Object.freeze({number: PackedKind.places, name: "places", prefix: "places"}),
])

/** The `kind` of every result. */
export const PackedOutcome = Object.freeze({
  expanded: "expanded",
  decoded: "decoded",
  refused: "refused",
})

/** Why a stream or a container was refused. */
export const PackedRefusal = Object.freeze({
  tooLarge: "tooLarge",
  corrupt: "corrupt",
  badMagic: "badMagic",
  unknownKind: "unknownKind",
  kindMismatch: "kindMismatch",
  unsupportedVersion: "unsupportedVersion",
  reservedNotZero: "reservedNotZero",
  truncated: "truncated",
  trailingBytes: "trailingBytes",
  sectionCount: "sectionCount",
  badVarint: "badVarint",
  badUtf8: "badUtf8",
  badStringTable: "badStringTable",
  badSectionSize: "badSectionSize",
  badPosition: "badPosition",
})

/** The types of a fixed-width column. */
export const ColumnType = Object.freeze({u8: "u8", u16: "u16", u32: "u32", i32: "i32"})

const COLUMN_BYTES = Object.freeze({u8: 1, u16: 2, u32: 4, i32: 4})

const magicBytes = new TextEncoder().encode(MAGIC_TEXT)
const textDecoder = new TextDecoder(TEXT_ENCODING, {fatal: true, ignoreBOM: true})

function refused(reason) {
  return {kind: PackedOutcome.refused, reason}
}

function isByteSource(source) {
  const isArray = source instanceof Uint8Array
  const isBuffer = source instanceof ArrayBuffer
  return isArray || isBuffer
}

function assertIndex({index, count, name}) {
  assertCondition(Number.isInteger(index), "the index into " + name + " must be an integer")
  assertCondition(index >= 0, "the index into " + name + " must not be negative")
  assertCondition(index < count, "the index into " + name + " must be under its count")
}

function assertCount(count) {
  assertCondition(Number.isSafeInteger(count), "the count must be an integer")
  assertCondition(count >= 0, "the count must not be negative")
}

// The chunks of `reader` joined into one array, read until the stream ends
// or passes `expandedByteSizeMax`.
async function readBounded({reader, expandedByteSizeMax}) {
  const chunks = []
  let byteCount = 0

  for (;;) {
    const read = await reader.read()

    if (read.done) {
      break
    }

    byteCount += read.value.byteLength

    if (byteCount > expandedByteSizeMax) {
      await reader.cancel()
      return refused(PackedRefusal.tooLarge)
    }

    chunks.push(read.value)
  }

  const bytes = new Uint8Array(byteCount)
  let offset = 0

  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }

  return {kind: PackedOutcome.expanded, bytes}
}

/**
 * The content of the gzip stream `source`, the bytes of a stored container
 * as fetched or a ReadableStream of them, expanded to at most
 * `expandedByteSizeMax` bytes: `{kind: "expanded", bytes}`, or
 * `{kind: "refused", reason}` with `tooLarge`, once the bound is passed and
 * reading stops, or `corrupt` for a stream that is not gzip or ends early.
 */
export async function expandStream(source, {expandedByteSizeMax}) {
  assertCondition(Number.isSafeInteger(expandedByteSizeMax), "the bound must be an integer")
  assertCondition(expandedByteSizeMax >= 1, "the bound must be at least 1 byte")
  const isStream = source instanceof ReadableStream
  const isSupported = isStream || isByteSource(source)
  assertCondition(isSupported, "the source must be bytes or a ReadableStream")

  let compressed = source

  if (!isStream) {
    compressed = new Blob([source]).stream()
  }

  const decompression = new DecompressionStream(COMPRESSION_FORMAT)
  const expanded = compressed.pipeThrough(decompression)
  const reader = expanded.getReader()

  try {
    return await readBounded({reader, expandedByteSizeMax})
  } catch {
    // A stream that is not gzip, or ends early, rejects the read; no other
    // failure comes from reading it.
    return refused(PackedRefusal.corrupt)
  }
}

function isLatitude(microdegrees) {
  return Math.abs(microdegrees) <= LATITUDE_MICRODEGREES_MAX
}

function isLongitude(microdegrees) {
  return Math.abs(microdegrees) <= LONGITUDE_MICRODEGREES_MAX
}

function isPointInRange({latitude, longitude}) {
  const isLatitudeInRange = isLatitude(latitude)
  const isLongitudeInRange = isLongitude(longitude)
  return isLatitudeInRange && isLongitudeInRange
}

/**
 * The name of the file of kind `kind` whose gzip stream has the lower case
 * hexadecimal SHA-256 `sha256`, as `Gobusgo.Packed.file_name/1` names it.
 */
export function packedFileName({kind, sha256}) {
  const entry = KINDS.find((candidate) => candidate.number === kind)
  assertCondition(entry !== undefined, "the kind must be in the table")
  assertCondition(typeof sha256 === "string", "the hash must be a string")
  return `${entry.prefix}-${sha256}${FILE_SUFFIX}`
}

/** The signed integer whose zigzag is `value`, an unsigned 32-bit integer. */
export function unzigzag(value) {
  assertCondition(Number.isSafeInteger(value), "a zigzag value must be an integer")
  assertCondition(value >= 0, "a zigzag value must be unsigned")

  const isEven = value % ZIGZAG_DIVISOR === 0

  if (isEven) {
    return value / ZIGZAG_DIVISOR
  }

  return -(value + 1) / ZIGZAG_DIVISOR
}

/**
 * A reader of varints and paths over `section` of `view`. A read that finds
 * a varint over-long, past 32 bits, or cut by the section's end sets
 * `refusal` to the reason and yields nothing; a caller checks `refusal`
 * after a run of reads, which stop making progress once it is set.
 */
export class SectionCursor {
  constructor({view, section}) {
    this.view = view
    this.offset = section.offset
    this.end = section.offset + section.byteLength
    this.refusal = null
  }

  /** The bytes left in the section. */
  remaining() {
    return this.end - this.offset
  }

  /**
   * The unsigned varint at the cursor, which then moves past it, or 0 with
   * `refusal` set. Arithmetic, not bitwise operators, keeps a value past
   * 2^31 exact.
   */
  readVarint() {
    let value = 0
    let scale = 1

    for (let index = 0; index < VARINT_BYTES_MAX; index += 1) {
      if (this.offset >= this.end) {
        this.refusal = PackedRefusal.truncated
        return 0
      }

      const byte = this.view.getUint8(this.offset)
      this.offset += 1
      value += (byte % VARINT_BASE) * scale
      scale *= VARINT_BASE

      if (value > VARINT_VALUE_MAX) {
        this.refusal = PackedRefusal.badVarint
        return 0
      }

      const isLast = byte < VARINT_BASE

      if (isLast) {
        return value
      }
    }

    this.refusal = PackedRefusal.badVarint
    return 0
  }

  /**
   * The path at the cursor: a varint count of points, then per point the
   * zigzag varint deltas of latitude and longitude from the point before,
   * the first from (0, 0). Returns an Int32Array of latitude and longitude
   * microdegrees in turn, two per point, with the cursor past the path. A
   * count the section cannot hold, at two bytes a point, is refused before
   * anything is allocated; a refused path sets `refusal` and returns an
   * empty array.
   */
  readPath() {
    const empty = new Int32Array(0)
    const count = this.readVarint()

    if (this.refusal !== null) {
      return empty
    }

    const bytesNeeded = count * COORDINATE_COUNT

    if (bytesNeeded > this.remaining()) {
      this.refusal = PackedRefusal.truncated
      return empty
    }

    const points = new Int32Array(bytesNeeded)
    let latitude = 0
    let longitude = 0

    for (let index = 0; index < count; index += 1) {
      latitude += unzigzag(this.readVarint())
      longitude += unzigzag(this.readVarint())

      if (this.refusal !== null) {
        return empty
      }

      if (!isPointInRange({latitude, longitude})) {
        this.refusal = PackedRefusal.badPosition
        return empty
      }

      points[index * COORDINATE_COUNT] = latitude
      points[index * COORDINATE_COUNT + 1] = longitude
    }

    return points
  }
}

function columnGetter({view, type}) {
  switch (type) {
    case ColumnType.u8:
      return (offset) => view.getUint8(offset)
    case ColumnType.u16:
      return (offset) => view.getUint16(offset, LITTLE_ENDIAN)
    case ColumnType.u32:
      return (offset) => view.getUint32(offset, LITTLE_ENDIAN)
    case ColumnType.i32:
      return (offset) => view.getInt32(offset, LITTLE_ENDIAN)
    default:
      return unreachable(type, "unknown column type")
  }
}

/**
 * The fixed-width column of `count` values of `type` that `section` of
 * `view` holds: `{kind: "decoded", count, at(index)}`, or a refusal
 * `badSectionSize` when the section is not `count` values long.
 */
export function openColumn({view, section, type, count}) {
  const byteSize = COLUMN_BYTES[type]
  assertCondition(byteSize !== undefined, "unknown column type: " + String(type))
  assertCount(count)

  if (section.byteLength !== count * byteSize) {
    return refused(PackedRefusal.badSectionSize)
  }

  const getValue = columnGetter({view, type})

  function at(index) {
    assertIndex({index, count, name: "the column"})
    return getValue(section.offset + index * byteSize)
  }

  return {kind: PackedOutcome.decoded, count, at}
}

function isPositionRefused({latitude, longitude}) {
  const isUnknownLatitude = latitude === UNKNOWN_MICRODEGREES
  const isUnknownLongitude = longitude === UNKNOWN_MICRODEGREES

  if (isUnknownLatitude !== isUnknownLongitude) {
    return true
  }

  const isUnknown = isUnknownLatitude && isUnknownLongitude
  const isInRange = isPointInRange({latitude, longitude})
  const isRefused = !isUnknown && !isInRange
  return isRefused
}

/**
 * The `count` positions that `section` of `view` holds, each two i32 of
 * microdegrees, latitude then longitude: `{kind: "decoded", count,
 * isKnownAt, latitudeAt, longitudeAt}`, or a refusal, `badSectionSize` for
 * a section not `count` positions long and `badPosition` for a position out
 * of range or unknown on one axis alone. An unknown position holds
 * UNKNOWN_MICRODEGREES on both axes.
 */
export function openPositions({view, section, count}) {
  assertCount(count)

  if (section.byteLength !== count * POSITION_BYTES) {
    return refused(PackedRefusal.badSectionSize)
  }

  function latitudeAt(index) {
    assertIndex({index, count, name: "the positions"})
    return view.getInt32(section.offset + index * POSITION_BYTES, LITTLE_ENDIAN)
  }

  function longitudeAt(index) {
    assertIndex({index, count, name: "the positions"})
    return view.getInt32(section.offset + index * POSITION_BYTES + I32_BYTES, LITTLE_ENDIAN)
  }

  function isKnownAt(index) {
    return latitudeAt(index) !== UNKNOWN_MICRODEGREES
  }

  for (let index = 0; index < count; index += 1) {
    const latitude = latitudeAt(index)
    const longitude = longitudeAt(index)

    if (isPositionRefused({latitude, longitude})) {
      return refused(PackedRefusal.badPosition)
    }
  }

  return {kind: PackedOutcome.decoded, count, isKnownAt, latitudeAt, longitudeAt}
}

function isValidUtf8(bytes) {
  try {
    textDecoder.decode(bytes)
    return true
  } catch (error) {
    if (error instanceof TypeError) {
      return false
    }

    throw error
  }
}

// The string table of `section`: entry offsets and lengths, each entry
// checked as UTF-8 once, and `at(index)`, which decodes an entry when it is
// first asked for.
function readStringTable({view, section}) {
  if (section.byteLength < U32_BYTES) {
    return refused(PackedRefusal.truncated)
  }

  const count = view.getUint32(section.offset, LITTLE_ENDIAN)
  const entries = {offset: section.offset + U32_BYTES, byteLength: section.byteLength - U32_BYTES}
  const cursor = new SectionCursor({view, section: entries})

  // Each entry takes at least one byte, so a larger count is cut short.
  if (count > cursor.remaining()) {
    return refused(PackedRefusal.truncated)
  }

  const starts = new Uint32Array(count)
  const lengths = new Uint32Array(count)

  for (let index = 0; index < count; index += 1) {
    const length = cursor.readVarint()

    if (cursor.refusal !== null) {
      return refused(cursor.refusal)
    }

    if (length > cursor.remaining()) {
      return refused(PackedRefusal.truncated)
    }

    const entry = new Uint8Array(view.buffer, view.byteOffset + cursor.offset, length)

    if (!isValidUtf8(entry)) {
      return refused(PackedRefusal.badUtf8)
    }

    starts[index] = cursor.offset
    lengths[index] = length
    cursor.offset += length
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badStringTable)
  }

  const decodedEntries = new Array(count)

  function at(index) {
    assertIndex({index, count, name: "the string table"})

    if (decodedEntries[index] === undefined) {
      const entry = new Uint8Array(view.buffer, view.byteOffset + starts[index], lengths[index])
      decodedEntries[index] = textDecoder.decode(entry)
    }

    return decodedEntries[index]
  }

  return {kind: PackedOutcome.decoded, count, at}
}

function isKnownKind(number) {
  for (const entry of KINDS) {
    if (entry.number === number) {
      return true
    }
  }

  return false
}

function hasMagic(bytes) {
  for (let index = 0; index < magicBytes.length; index += 1) {
    if (bytes[index] !== magicBytes[index]) {
      return false
    }
  }

  return true
}

// The header of `bytes`, or the reason it is refused.
function readHeader({bytes, view}) {
  const hasMagicBytes = bytes.byteLength >= magicBytes.length

  if (hasMagicBytes) {
    const isMagic = hasMagic(bytes)

    if (!isMagic) {
      return refused(PackedRefusal.badMagic)
    }
  }

  if (bytes.byteLength < HEADER_BYTES) {
    return refused(PackedRefusal.truncated)
  }

  const kind = view.getUint16(KIND_OFFSET, LITTLE_ENDIAN)

  if (!isKnownKind(kind)) {
    return refused(PackedRefusal.unknownKind)
  }

  if (view.getUint32(RESERVED_OFFSET, LITTLE_ENDIAN) !== 0) {
    return refused(PackedRefusal.reservedNotZero)
  }

  const version = view.getUint16(VERSION_OFFSET, LITTLE_ENDIAN)
  const recordCount = view.getUint32(RECORD_COUNT_OFFSET, LITTLE_ENDIAN)
  return {kind: PackedOutcome.decoded, header: {kind, version, recordCount}}
}

// The sections of `view` after the header, or the reason they are refused.
function readSections(view) {
  const sections = []
  let offset = HEADER_BYTES

  while (offset < view.byteLength) {
    if (view.byteLength - offset < U32_BYTES) {
      return refused(PackedRefusal.trailingBytes)
    }

    const byteLength = view.getUint32(offset, LITTLE_ENDIAN)
    offset += U32_BYTES

    if (byteLength > view.byteLength - offset) {
      return refused(PackedRefusal.truncated)
    }

    sections.push({offset, byteLength})
    offset += byteLength
  }

  return {kind: PackedOutcome.decoded, sections}
}

/**
 * The container `bytes` holds, whose header names kind `kind`, one of
 * `versions`, and `sectionCount` sections after the string table:
 * `{kind: "decoded", header: {kind, version, recordCount}, strings: {count,
 * at(index)}, sections, view}`, where `sections` are `{offset, byteLength}`
 * over `view`, one DataView of the bytes, or `{kind: "refused", reason}`
 * with `badMagic`, `unknownKind`, `kindMismatch`, `unsupportedVersion`,
 * `reservedNotZero`, `truncated`, `trailingBytes`, `sectionCount`,
 * `badVarint`, `badUtf8`, or `badStringTable`. Every string table entry is
 * checked as UTF-8 here, so `strings.at` cannot fail.
 */
export function decodeContainer(bytes, {kind, versions, sectionCount}) {
  assertCondition(bytes instanceof Uint8Array, "the bytes must be a Uint8Array")
  assertCondition(Number.isInteger(kind), "the kind must be an integer")
  assertCondition(Array.isArray(versions), "the versions must be an array")
  assertCondition(Number.isInteger(sectionCount), "the section count must be an integer")
  assertCondition(sectionCount >= 0, "the section count must not be negative")

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const read = readHeader({bytes, view})

  if (read.kind === PackedOutcome.refused) {
    return read
  }

  const {header} = read

  if (header.kind !== kind) {
    return refused(PackedRefusal.kindMismatch)
  }

  if (!versions.includes(header.version)) {
    return refused(PackedRefusal.unsupportedVersion)
  }

  const split = readSections(view)

  if (split.kind === PackedOutcome.refused) {
    return split
  }

  if (split.sections.length !== sectionCount + 1) {
    return refused(PackedRefusal.sectionCount)
  }

  const strings = readStringTable({view, section: split.sections[STRING_TABLE_SECTION_INDEX]})

  if (strings.kind === PackedOutcome.refused) {
    return strings
  }

  const sections = split.sections.slice(STRING_TABLE_SECTION_INDEX + 1)
  return {kind: PackedOutcome.decoded, header, strings, sections, view}
}
