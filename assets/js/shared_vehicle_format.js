// The reader of the shared vehicle files a fetch is published as: the
// index, and the binary block a tile and the whole-city file both hold,
// format version 1 of `Gobusgo.Gbfs.VehicleTileFormat`. Everything here is
// pure: it decodes bytes and text it is given and fetches nothing, so the
// map layer and the trip planner read the files alike.
//
// A block is little-endian: a header of 28 bytes, the magic "GBSV", the
// version as a u16, a u16 of zero, the vehicle count as a u32, and the
// bounds as four i32 in millionths of a degree, south, west, north, east;
// then the columns, one entry per vehicle: the latitude and the longitude as
// u16 fractions of the bounds, the range as a u16 count of decameters or
// 0xFFFF for none, and the form factor as a u8.

const MAGIC = "GBSV"
const FORMAT_VERSION = 1
const INDEX_FORMAT_VERSION = 1
const HEADER_BYTES = 28
const VEHICLE_BYTES = 7
const COLUMN_ENTRY_BYTES = 2
const COUNT_OFFSET = 8
const SOUTH_OFFSET = 12
const WEST_OFFSET = 16
const NORTH_OFFSET = 20
const EAST_OFFSET = 24
const VERSION_OFFSET = 4
const FRACTION_MAX = 0xFFFF
const RANGE_UNKNOWN = 0xFFFF
const METERS_PER_DECAMETER = 10
const MICRODEGREES_PER_DEGREE = 1_000_000
const LAT_MICRODEGREES_MAX = 90_000_000
const LON_MICRODEGREES_MAX = 180_000_000
const IS_LITTLE_ENDIAN = true
const TILE_ENTRY_LENGTH = 4

/** The form factors, at the index of their code. */
export const FORM_FACTORS = Object.freeze(["other", "standing_scooter", "seated_scooter", "e_bike", "bike"])

/** The kinds of the outcome of decoding a block or reading an index. */
export const DecodeKind = Object.freeze({decoded: "decoded", refused: "refused"})

function refused(reason) {
  return {kind: DecodeKind.refused, reason}
}

function isAxisInside({low, high, max}) {
  const isLowInside = Math.abs(low) <= max
  const isHighInside = Math.abs(high) <= max
  const isInside = isLowInside && isHighInside
  return isInside && low <= high
}

// The degrees at `fraction` of the way from `low` to `high`, in
// microdegrees.
function degreesAt({fraction, low, high}) {
  return (low + fraction * (high - low) / FRACTION_MAX) / MICRODEGREES_PER_DEGREE
}

/**
 * The bounds and the vehicles of the block `bytes`, a Uint8Array, as
 * `DecodeKind.decoded`, or `DecodeKind.refused` with the first rule the
 * block breaks: "magic", "version", "length", "bounds", or "formFactor".
 */
export function decodeBlock(bytes) {
  if (bytes.byteLength < MAGIC.length) {
    return refused("magic")
  }

  const magicBytes = bytes.subarray(0, MAGIC.length)
  const magic = new TextDecoder().decode(magicBytes)

  if (magic !== MAGIC) {
    return refused("magic")
  }

  if (bytes.byteLength < HEADER_BYTES) {
    return refused("length")
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

  if (view.getUint16(VERSION_OFFSET, IS_LITTLE_ENDIAN) !== FORMAT_VERSION) {
    return refused("version")
  }

  const count = view.getUint32(COUNT_OFFSET, IS_LITTLE_ENDIAN)

  if (bytes.byteLength !== HEADER_BYTES + count * VEHICLE_BYTES) {
    return refused("length")
  }

  const bounds = {
    south: view.getInt32(SOUTH_OFFSET, IS_LITTLE_ENDIAN),
    west: view.getInt32(WEST_OFFSET, IS_LITTLE_ENDIAN),
    north: view.getInt32(NORTH_OFFSET, IS_LITTLE_ENDIAN),
    east: view.getInt32(EAST_OFFSET, IS_LITTLE_ENDIAN)
  }

  const isLatInside = isAxisInside({low: bounds.south, high: bounds.north, max: LAT_MICRODEGREES_MAX})
  const isLonInside = isAxisInside({low: bounds.west, high: bounds.east, max: LON_MICRODEGREES_MAX})
  const areBoundsInside = isLatInside && isLonInside

  if (!areBoundsInside) {
    return refused("bounds")
  }

  return decodeColumns({bytes, view, count, bounds})
}

// The vehicles of the columns of a block whose header holds.
function decodeColumns({bytes, view, count, bounds}) {
  const columnBytes = count * COLUMN_ENTRY_BYTES
  const latOffset = HEADER_BYTES
  const lonOffset = latOffset + columnBytes
  const rangeOffset = lonOffset + columnBytes
  const formOffset = rangeOffset + columnBytes
  const vehicles = []

  for (let index = 0; index < count; index += 1) {
    const entryOffset = index * COLUMN_ENTRY_BYTES
    const latFraction = view.getUint16(latOffset + entryOffset, IS_LITTLE_ENDIAN)
    const lonFraction = view.getUint16(lonOffset + entryOffset, IS_LITTLE_ENDIAN)
    const rangeDecameters = view.getUint16(rangeOffset + entryOffset, IS_LITTLE_ENDIAN)
    const formCode = bytes[formOffset + index]

    if (formCode >= FORM_FACTORS.length) {
      return refused("formFactor")
    }

    let rangeMeters = null

    if (rangeDecameters !== RANGE_UNKNOWN) {
      rangeMeters = rangeDecameters * METERS_PER_DECAMETER
    }

    vehicles.push({
      lat: degreesAt({fraction: latFraction, low: bounds.south, high: bounds.north}),
      lon: degreesAt({fraction: lonFraction, low: bounds.west, high: bounds.east}),
      rangeMeters,
      formFactor: FORM_FACTORS[formCode]
    })
  }

  return {kind: DecodeKind.decoded, block: {bounds, vehicles}}
}

// Whether `entry` is an index's `[x, y, count, hash]`.
function isTileEntry(entry) {
  const isList = Array.isArray(entry) && entry.length === TILE_ENTRY_LENGTH

  if (!isList) {
    return false
  }

  const [x, y, count, hash] = entry
  const isPlaced = Number.isSafeInteger(x) && Number.isSafeInteger(y)
  const isCounted = Number.isSafeInteger(count) && typeof hash === "string"
  return isPlaced && isCounted
}

/**
 * The index `value`, the parsed JSON of an index file, as
 * `DecodeKind.decoded` with its fetch time in milliseconds, its whole-city
 * file, its tile zoom, and its tiles by "x/y" key, or `DecodeKind.refused`
 * for a value of another shape.
 */
export function readIndex(value) {
  const isObject = typeof value === "object" && value !== null

  if (!isObject) {
    return refused("shape")
  }

  if (value.formatVersion !== INDEX_FORMAT_VERSION) {
    return refused("version")
  }

  const fetchedAtMs = Date.parse(value.fetchedAt)
  const hasTiles = Array.isArray(value.tiles) && value.tiles.every(isTileEntry)
  const hasZoom = Number.isSafeInteger(value.tileZoom)
  const hasCity = typeof value.city === "string"
  const hasFiles = hasTiles && hasZoom
  const isComplete = hasFiles && hasCity

  if (Number.isNaN(fetchedAtMs)) {
    return refused("shape")
  }

  if (!isComplete) {
    return refused("shape")
  }

  const tiles = new Map()

  for (const [x, y, count, hash] of value.tiles) {
    tiles.set(tileKey({x, y}), {x, y, count, name: `tile-${value.tileZoom}-${x}-${y}-${hash}.bin.gz`})
  }

  return {
    kind: DecodeKind.decoded,
    index: {fetchedAtMs, systemId: value.systemId, tileZoom: value.tileZoom, cityName: value.city, tiles}
  }
}

/** The key of the tile at `x`, `y` in an index's tiles. */
export function tileKey({x, y}) {
  return `${x}/${y}`
}

/** The address of the file `name` beside the index at `indexUrl`. */
export function fileUrl({indexUrl, name}) {
  const directory = indexUrl.slice(0, indexUrl.lastIndexOf("/") + 1)
  return directory + name
}
