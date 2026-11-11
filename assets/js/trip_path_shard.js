// The readers of the trip path files of one service date's routing snapshot,
// kinds 1 and 2 of the packed container, as Gobusgo.Routing.TripPathShard and
// Gobusgo.Routing.TripPathIndex write them: the index names, per route, the
// shard that holds the paths of the route's trips, and a shard holds each
// trip's path as a geometry, a pattern of stop distances along it, and the
// trip's own times. A reader decodes a whole file's structure when it opens
// the file, so a bad file is refused as a value there, and decodes a trip's
// points and stops only when a trip is asked for. Everything here is pure:
// the bytes are an expanded container, as `expandStream` of
// packed_container.js returns them.

import {assertCondition} from "./assert.js"
import {
  ColumnType,
  PackedKind,
  PackedOutcome,
  PackedRefusal,
  SectionCursor,
  decodeContainer,
  openColumn,
  unzigzag
} from "./packed_container.js"
import {tripPathOf} from "./trip_path.js"

/** The versions of each kind this reader reads. */
export const TRIP_PATH_SHARD_VERSIONS = Object.freeze([1])
export const TRIP_PATH_INDEX_VERSIONS = Object.freeze([1])

/** What a lookup returns for a trip or a route the file does not hold. */
export const TripPathLookup = Object.freeze({missing: "missing"})

/** Why a file is refused, beyond the container's reasons: a reference to a string, geometry, pattern, or time the file does not hold, or a stop before the stop before it. */
export const TripPathRefusal = Object.freeze({badIndex: "badIndex"})

const SHARD_SECTION_COUNT = 4
const INDEX_SECTION_COUNT = 2
const COLUMNS_PER_TRIP = 3
const COLUMNS_PER_ROUTE = 3
const SHARD_SECTION = Object.freeze({geometries: 0, patterns: 1, trips: 2, times: 3})
const INDEX_SECTION = Object.freeze({columns: 0, hashes: 1})
const SHA256_BYTES = 32
const MICRODEGREES_PER_DEGREE = 1_000_000
const LATITUDE_AT = 0
const LONGITUDE_AT = 1
const POINT_VALUES = 2
const TIME_VALUES_PER_STOP = 2
const HEX_RADIX = 16
const HEX_DIGITS_PER_BYTE = 2

function refused(reason) {
  return {kind: PackedOutcome.refused, reason}
}

function sectionRestFrom({section, offset}) {
  return {offset, byteLength: section.offset + section.byteLength - offset}
}

// The geometries of `section`: each one's start, every path checked. A
// geometry of no point is refused, since a path holds at least one.
function scanGeometries({view, section}) {
  const cursor = new SectionCursor({view, section})
  const count = cursor.readVarint()

  if (cursor.refusal !== null) {
    return refused(cursor.refusal)
  }

  // Each geometry takes at least one byte, so a larger count is cut short.
  if (count > cursor.remaining()) {
    return refused(PackedRefusal.truncated)
  }

  const offsets = new Uint32Array(count)

  for (let index = 0; index < count; index += 1) {
    offsets[index] = cursor.offset
    const path = cursor.readPath()

    if (cursor.refusal !== null) {
      return refused(cursor.refusal)
    }

    if (path.length === 0) {
      return refused(TripPathRefusal.badIndex)
    }
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badSectionSize)
  }

  return {kind: PackedOutcome.decoded, offsets}
}

// The patterns of `section`: each one's geometry, stop count, and the start
// of its distance steps. A pattern names a geometry the file holds, has a
// stop, and has no step back.
function scanPatterns({view, section, geometryCount}) {
  const cursor = new SectionCursor({view, section})
  const count = cursor.readVarint()

  if (cursor.refusal !== null) {
    return refused(cursor.refusal)
  }

  if (count > cursor.remaining()) {
    return refused(PackedRefusal.truncated)
  }

  const geometries = new Uint32Array(count)
  const stopCounts = new Uint32Array(count)
  const stepOffsets = new Uint32Array(count)

  for (let index = 0; index < count; index += 1) {
    const geometryIndex = cursor.readVarint()
    const stopCount = cursor.readVarint()

    if (cursor.refusal !== null) {
      return refused(cursor.refusal)
    }

    if (geometryIndex >= geometryCount || stopCount === 0) {
      return refused(TripPathRefusal.badIndex)
    }

    if (stopCount > cursor.remaining()) {
      return refused(PackedRefusal.truncated)
    }

    geometries[index] = geometryIndex
    stopCounts[index] = stopCount
    stepOffsets[index] = cursor.offset

    for (let stop = 0; stop < stopCount; stop += 1) {
      const step = unzigzag(cursor.readVarint())

      if (cursor.refusal !== null) {
        return refused(cursor.refusal)
      }

      if (step < 0) {
        return refused(TripPathRefusal.badIndex)
      }
    }
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badSectionSize)
  }

  return {kind: PackedOutcome.decoded, geometries, stopCounts, stepOffsets}
}

// The three columns of the trips section: each trip's string index, pattern
// index, and offset into the times, which must lie one after another with
// no gap, and each trip's identifier used once.
function scanTrips({view, container, patterns}) {
  const count = container.header.recordCount
  const column = openColumn({
    view,
    section: container.sections[SHARD_SECTION.trips],
    type: ColumnType.u32,
    count: count * COLUMNS_PER_TRIP
  })

  if (column.kind === PackedOutcome.refused) {
    return column
  }

  const timesSection = container.sections[SHARD_SECTION.times]
  const cursor = new SectionCursor({view, section: timesSection})
  const stringIndexes = new Uint32Array(count)
  const patternIndexes = new Uint32Array(count)
  const timeOffsets = new Uint32Array(count)
  const isUsed = new Uint8Array(container.strings.count)

  for (let index = 0; index < count; index += 1) {
    const stringIndex = column.at(index)
    const patternIndex = column.at(count + index)
    const timeOffset = column.at(count * 2 + index)
    const isStringInRange = stringIndex < container.strings.count
    const isPatternInRange = patternIndex < patterns.geometries.length

    if (!isStringInRange || !isPatternInRange) {
      return refused(TripPathRefusal.badIndex)
    }

    const isStringUsed = isUsed[stringIndex] === 1
    const isOffsetOffTheRun = timeOffset !== cursor.offset - timesSection.offset

    if (isStringUsed || isOffsetOffTheRun) {
      return refused(TripPathRefusal.badIndex)
    }

    isUsed[stringIndex] = 1
    stringIndexes[index] = stringIndex
    patternIndexes[index] = patternIndex
    timeOffsets[index] = timeOffset

    const valueCount = patterns.stopCounts[patternIndex] * TIME_VALUES_PER_STOP

    if (valueCount > cursor.remaining()) {
      return refused(PackedRefusal.truncated)
    }

    for (let value = 0; value < valueCount; value += 1) {
      cursor.readVarint()

      if (cursor.refusal !== null) {
        return refused(cursor.refusal)
      }
    }
  }

  if (cursor.remaining() !== 0) {
    return refused(PackedRefusal.badSectionSize)
  }

  return {kind: PackedOutcome.decoded, stringIndexes, patternIndexes, timeOffsets}
}

/**
 * The shard `bytes` holds, an expanded container of kind 1: `{kind:
 * "decoded", shard}`, or `{kind: "refused", reason}` with a reason of the
 * container's or `badIndex`. The whole file is checked here, so reading a
 * trip from the shard cannot fail. `shard.tripCount` is the trips it holds,
 * and `tripPathFromShard` reads one.
 */
export function decodeTripPathShard(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.tripPathShard,
    versions: TRIP_PATH_SHARD_VERSIONS,
    sectionCount: SHARD_SECTION_COUNT
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const {view} = container
  const geometries = scanGeometries({view, section: container.sections[SHARD_SECTION.geometries]})

  if (geometries.kind === PackedOutcome.refused) {
    return geometries
  }

  const patterns = scanPatterns({
    view,
    section: container.sections[SHARD_SECTION.patterns],
    geometryCount: geometries.offsets.length
  })

  if (patterns.kind === PackedOutcome.refused) {
    return patterns
  }

  const trips = scanTrips({view, container, patterns})

  if (trips.kind === PackedOutcome.refused) {
    return trips
  }

  const tripCount = container.header.recordCount
  let indexByTripId = null

  // One Map per shard, built when the first trip is asked for and bounded
  // by the trips the shard holds.
  function indexOfTrip(tripId) {
    if (indexByTripId === null) {
      indexByTripId = new Map()

      for (let index = 0; index < tripCount; index += 1) {
        indexByTripId.set(container.strings.at(trips.stringIndexes[index]), index)
      }
    }

    const index = indexByTripId.get(tripId)

    if (index === undefined) {
      return -1
    }

    return index
  }

  const shard = Object.freeze({
    tripCount,
    view,
    geometrySection: container.sections[SHARD_SECTION.geometries],
    patternSection: container.sections[SHARD_SECTION.patterns],
    timesSection: container.sections[SHARD_SECTION.times],
    geometryOffsets: geometries.offsets,
    patternGeometries: patterns.geometries,
    patternStopCounts: patterns.stopCounts,
    patternStepOffsets: patterns.stepOffsets,
    tripPatternIndexes: trips.patternIndexes,
    tripTimeOffsets: trips.timeOffsets,
    indexOfTrip
  })

  return {kind: PackedOutcome.decoded, shard}
}

function pointsOf({shard, geometryIndex}) {
  const offset = shard.geometryOffsets[geometryIndex]
  const section = sectionRestFrom({section: shard.geometrySection, offset})
  const cursor = new SectionCursor({view: shard.view, section})
  const path = cursor.readPath()
  assertCondition(cursor.refusal === null, "the shard's geometries were checked when it was decoded")
  const points = []

  // Microdegrees over a million is the same quotient as the encoded format's
  // five-place integers over a hundred thousand, so a point is the number
  // `decodeTripPath` finds, bit for bit.
  for (let index = 0; index < path.length; index += POINT_VALUES) {
    const latitude = path[index + LATITUDE_AT] / MICRODEGREES_PER_DEGREE
    const longitude = path[index + LONGITUDE_AT] / MICRODEGREES_PER_DEGREE
    points.push(Object.freeze([longitude, latitude]))
  }

  return points
}

function stopsOf({shard, patternIndex, tripIndex}) {
  const stopCount = shard.patternStopCounts[patternIndex]
  const stepSection = sectionRestFrom({
    section: shard.patternSection,
    offset: shard.patternStepOffsets[patternIndex]
  })
  const distanceCursor = new SectionCursor({view: shard.view, section: stepSection})
  const timesOffset = shard.timesSection.offset + shard.tripTimeOffsets[tripIndex]
  const timesCursor = new SectionCursor({
    view: shard.view,
    section: sectionRestFrom({section: shard.timesSection, offset: timesOffset})
  })
  const stops = []
  let distanceMeters = 0
  let arrivalSeconds = 0

  for (let index = 0; index < stopCount; index += 1) {
    distanceMeters += unzigzag(distanceCursor.readVarint())
    arrivalSeconds += unzigzag(timesCursor.readVarint())
    const departureSeconds = arrivalSeconds + unzigzag(timesCursor.readVarint())
    stops.push(Object.freeze({distanceMeters, arrivalSeconds, departureSeconds}))
  }

  assertCondition(distanceCursor.refusal === null, "the shard's patterns were checked when it was decoded")
  assertCondition(timesCursor.refusal === null, "the shard's times were checked when it was decoded")
  return stops
}

/**
 * The path of trip `tripId` of `route` on the service day that starts at
 * `serviceDateMs`, from `shard`, a decoded shard: the frozen object
 * `decodeTripPath` returns for the same trip, or `{kind: "missing"}` for a
 * trip the shard does not hold. Only this trip's points and stops are
 * decoded.
 */
export function tripPathFromShard(shard, {tripId, routeId, serviceDateMs}) {
  assertCondition(typeof tripId === "string", "a trip identifier must be text")
  const tripIndex = shard.indexOfTrip(tripId)

  if (tripIndex < 0) {
    return {kind: TripPathLookup.missing}
  }

  const patternIndex = shard.tripPatternIndexes[tripIndex]
  const geometryIndex = shard.patternGeometries[patternIndex]
  const points = pointsOf({shard, geometryIndex})
  const stops = stopsOf({shard, patternIndex, tripIndex})
  return tripPathOf({tripId, routeId, serviceDateMs, points, stops})
}

function hexOf(bytes) {
  let hex = ""

  for (const byte of bytes) {
    hex += byte.toString(HEX_RADIX).padStart(HEX_DIGITS_PER_BYTE, "0")
  }

  return hex
}

/**
 * The index `bytes` holds, an expanded container of kind 2: `{kind:
 * "decoded", index}`, or `{kind: "refused", reason}`. `index.routeCount` is
 * the routes it holds, and `index.entryOf(routeId)` is the route's `{path,
 * byteSize, sha256}`, the manifest entry of its shard, or `{kind:
 * "missing"}`.
 */
export function decodeTripPathIndex(bytes) {
  const container = decodeContainer(bytes, {
    kind: PackedKind.tripPathIndex,
    versions: TRIP_PATH_INDEX_VERSIONS,
    sectionCount: INDEX_SECTION_COUNT
  })

  if (container.kind === PackedOutcome.refused) {
    return container
  }

  const {view} = container
  const routeCount = container.header.recordCount
  const column = openColumn({
    view,
    section: container.sections[INDEX_SECTION.columns],
    type: ColumnType.u32,
    count: routeCount * COLUMNS_PER_ROUTE
  })

  if (column.kind === PackedOutcome.refused) {
    return column
  }

  const hashes = container.sections[INDEX_SECTION.hashes]

  if (hashes.byteLength !== routeCount * SHA256_BYTES) {
    return refused(PackedRefusal.badSectionSize)
  }

  const entries = new Map()

  for (let index = 0; index < routeCount; index += 1) {
    const routeIndex = column.at(index)
    const pathIndex = column.at(routeCount + index)
    const byteSize = column.at(routeCount * 2 + index)
    const isRouteInRange = routeIndex < container.strings.count
    const isPathInRange = pathIndex < container.strings.count

    if (!isRouteInRange || !isPathInRange) {
      return refused(TripPathRefusal.badIndex)
    }

    const routeId = container.strings.at(routeIndex)

    if (entries.has(routeId)) {
      return refused(TripPathRefusal.badIndex)
    }

    const hash = new Uint8Array(view.buffer, view.byteOffset + hashes.offset + index * SHA256_BYTES, SHA256_BYTES)
    entries.set(routeId, Object.freeze({path: container.strings.at(pathIndex), byteSize, sha256: hexOf(hash)}))
  }

  function entryOf(routeId) {
    const entry = entries.get(routeId)

    if (entry === undefined) {
      return {kind: TripPathLookup.missing}
    }

    return entry
  }

  return {kind: PackedOutcome.decoded, index: Object.freeze({routeCount, entryOf})}
}
