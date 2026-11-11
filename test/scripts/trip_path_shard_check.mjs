// Decodes the shared trip path fixtures of test/fixtures/routing/trip-paths-v1
// with the trip path readers, the loop route's shard, expanded and as a gzip
// stream, and the index, against the expected values beside them. It checks
// that the loop trip's path read from the shard is the frozen object
// `decodeTripPath` returns for the same trip's encoded event, which the Elixir
// tests pin to the server's builder; that a trip the shard lacks is a value;
// and that each rule a file can break is refused as a value. Run it with
// `node test/scripts/trip_path_shard_check.mjs`; it exits non-zero on the
// first result that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {
  CONTAINER_EXPANDED_BYTES_MAX,
  HEADER_BYTES,
  PackedOutcome,
  PackedRefusal,
  expandStream
} from "../../assets/js/packed_container.js"
import {decodeTripPath} from "../../assets/js/trip_path.js"
import {
  TripPathLookup,
  TripPathRefusal,
  decodeTripPathIndex,
  decodeTripPathShard,
  indexEntries,
  tripPathFromShard
} from "../../assets/js/trip_path_shard.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/routing/trip-paths-v1/", import.meta.url))
const loopDirectory = fileURLToPath(new URL("../fixtures/one_bus_away/trip_path/", import.meta.url))
const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const {event: loopEvent} = JSON.parse(readFileSync(loopDirectory + "encoded_loop.json", "utf-8"))
const E5_PER_DEGREE = 100_000
const ROUTE_ID = "1_7994"
const SERVICE_DATE_MS = 1_794_211_200_000
const VERSION_OFFSET = 4
const VERSION_UNKNOWN = 2
const U32_BYTES = 4
const SHA256_BYTES = 32
const GEOMETRY_SECTION = 1
const PATTERN_SECTION = 2
const TRIP_SECTION = 3
const TIMES_SECTION = 4
const INDEX_COLUMN_SECTION = 1
const INDEX_HASH_SECTION = 2
const FIRST_BLOCK = 0
const SECOND_BLOCK = 1
const THIRD_BLOCK = 2
const STRING_INDEX_UNHELD = 99
const PATTERN_INDEX_UNHELD = 7
const OFFSET_SKEW = 1
const LITTLE_ENDIAN = true
const GEOMETRY_NO_POINT = "0100"
const GEOMETRY_CLAIMS_MORE_POINTS = "010900"
const PATTERN_GEOMETRY_UNHELD = "01050100"
const PATTERN_NO_STOP = "010000"
const PATTERN_STEP_BACK = "0100020001"
const PATTERN_CLAIMS_MORE_STOPS = "01000500"
const EXTRA_BYTE = "00"

const shardBytes = fileBytes("shard.bin")
const indexBytes = fileBytes("index.bin")

function fileBytes(name) {
  return new Uint8Array(readFileSync(fixtureDirectory + name))
}

function hexBytes(hex) {
  return new Uint8Array(Buffer.from(hex, "hex"))
}

function decodedOf(result) {
  deepStrictEqual(result.kind, PackedOutcome.decoded, "the file is decoded, not " + JSON.stringify(result))
  return result
}

function refusal(reason) {
  return {kind: PackedOutcome.refused, reason}
}

// The sections of a container, the string table first, each a copy.
function splitSections(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const sections = []
  let offset = HEADER_BYTES

  while (offset < bytes.byteLength) {
    const length = view.getUint32(offset, LITTLE_ENDIAN)
    sections.push(bytes.slice(offset + U32_BYTES, offset + U32_BYTES + length))
    offset += U32_BYTES + length
  }

  return sections
}

function sectionBytes(section) {
  return U32_BYTES + section.length
}

function assemble({header, sections}) {
  const sizes = Array.from(sections, sectionBytes)
  const total = sizes.reduce(sumOf, header.length)
  const assembled = new Uint8Array(total)
  const view = new DataView(assembled.buffer)
  assembled.set(header, 0)
  let offset = header.length

  for (const section of sections) {
    view.setUint32(offset, section.length, LITTLE_ENDIAN)
    assembled.set(section, offset + U32_BYTES)
    offset += sectionBytes(section)
  }

  return assembled
}

function sumOf(left, right) {
  return left + right
}

// The container of `bytes` with the section at `index`, counting the string
// table as 0, replaced by `section`.
function withSection({bytes, index, section}) {
  const sections = splitSections(bytes)
  sections[index] = section
  const header = bytes.slice(0, HEADER_BYTES)
  return assemble({header, sections})
}

function u32s(values) {
  const bytes = new Uint8Array(values.length * U32_BYTES)
  const view = new DataView(bytes.buffer)

  for (const [index, value] of values.entries()) {
    view.setUint32(index * U32_BYTES, value, LITTLE_ENDIAN)
  }

  return bytes
}

function readU32s(section) {
  const view = new DataView(section.buffer, section.byteOffset, section.byteLength)
  const values = []

  for (let offset = 0; offset < section.length; offset += U32_BYTES) {
    values.push(view.getUint32(offset, LITTLE_ENDIAN))
  }

  return values
}

function withBytes({bytes, extra}) {
  const joined = new Uint8Array(bytes.length + extra.length)
  joined.set(bytes, 0)
  joined.set(extra, bytes.length)
  return joined
}

function withVersion({bytes, version}) {
  const copy = bytes.slice()
  new DataView(copy.buffer).setUint16(VERSION_OFFSET, version, LITTLE_ENDIAN)
  return copy
}

function dropLast({bytes, count}) {
  return bytes.slice(0, bytes.length - count)
}

function stopDistance(stop) {
  return stop.distanceMeters
}

function stopArrival(stop) {
  return stop.arrivalSeconds
}

function stopDeparture(stop) {
  return stop.departureSeconds
}

function degreesOf(e5) {
  return e5 / E5_PER_DEGREE
}

// The fixture's two stored forms hold one content each.
async function checkStoredStreams() {
  const options = {expandedByteSizeMax: CONTAINER_EXPANDED_BYTES_MAX}
  const shardExpanded = await expandStream(fileBytes("shard.bin.gz"), options)
  deepStrictEqual(shardExpanded.kind, PackedOutcome.expanded)
  deepStrictEqual(shardExpanded.bytes, shardBytes, "the gzip stream expands to the shard")

  const indexExpanded = await expandStream(fileBytes("index.bin.gz"), options)
  deepStrictEqual(indexExpanded.bytes, indexBytes, "the gzip stream expands to the index")
}

function checkExpectedTrip({shard, trip}) {
  const path = tripPathFromShard(shard, {tripId: trip.id, routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS})
  const [firstLatitude, firstLongitude] = trip.firstPointE5
  const [lastLatitude, lastLongitude] = trip.lastPointE5
  const lastPoint = path.points[path.points.length - 1]
  deepStrictEqual(path.points.length, trip.pointCount, trip.id + " point count")
  deepStrictEqual(path.points[0], [degreesOf(firstLongitude), degreesOf(firstLatitude)])
  deepStrictEqual(lastPoint, [degreesOf(lastLongitude), degreesOf(lastLatitude)])
  const distances = Array.from(path.stops, stopDistance)
  const arrivals = Array.from(path.stops, stopArrival)
  const departures = Array.from(path.stops, stopDeparture)
  deepStrictEqual(distances, trip.stopDistancesM, trip.id + " distances")
  deepStrictEqual(arrivals, trip.arrivalS, trip.id + " arrivals")
  deepStrictEqual(departures, trip.departureS, trip.id + " departures")
}

function checkShard() {
  const {shard} = decodedOf(decodeTripPathShard(shardBytes))
  deepStrictEqual(shard.tripCount, expected.shard.tripCount, "the trip count")

  for (const trip of expected.shard.trips) {
    checkExpectedTrip({shard, trip})
  }

  const loopTrip = {tripId: loopEvent.trip_id, routeId: loopEvent.route_id, serviceDateMs: loopEvent.service_date_ms}
  const fromShard = tripPathFromShard(shard, loopTrip)
  deepStrictEqual(fromShard, decodeTripPath(loopEvent), "the shard's path is the event's decoded path")
  ok(Object.isFrozen(fromShard), "the path is frozen")
  ok(Object.isFrozen(fromShard.points[0]), "a point is frozen")
  ok(Object.isFrozen(fromShard.stops[0]), "a stop is frozen")

  const absent = {tripId: "1_none", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}
  deepStrictEqual(tripPathFromShard(shard, absent), {kind: TripPathLookup.missing}, "a trip the shard lacks")
}

function checkIndex() {
  const {index} = decodedOf(decodeTripPathIndex(indexBytes))
  deepStrictEqual(index.routeCount, expected.index.records.length, "the route count")

  for (const record of expected.index.records) {
    const entry = {path: record.path, byteSize: record.byteSize, sha256: record.sha256}
    deepStrictEqual(index.entryOf(record.routeId), entry, "the entry of " + record.routeId)
  }

  deepStrictEqual(index.entryOf("1_none"), {kind: TripPathLookup.missing}, "a route the index lacks")

  const listed = indexEntries(index)
  deepStrictEqual(listed.length, index.routeCount, "every route's entry is listed")

  for (const [position, record] of expected.index.records.entries()) {
    const entry = {path: record.path, byteSize: record.byteSize, sha256: record.sha256}
    deepStrictEqual(listed[position], entry, "the listed entry " + position + " is the index's order")
  }
}

function shardWithSection({index, section}) {
  return decodeTripPathShard(withSection({bytes: shardBytes, index, section}))
}

function shardWithColumns(columns) {
  return shardWithSection({index: TRIP_SECTION, section: u32s(columns.flat())})
}

function shardContainerCases() {
  const geometries = splitSections(shardBytes)[GEOMETRY_SECTION]
  const times = splitSections(shardBytes)[TIMES_SECTION]
  const wrongVersion = withVersion({bytes: shardBytes, version: VERSION_UNKNOWN})
  const sectionsKept = splitSections(shardBytes).slice(0, PATTERN_SECTION)
  const fewerSections = assemble({header: shardBytes.slice(0, HEADER_BYTES), sections: sectionsKept})
  const extraByte = hexBytes(EXTRA_BYTE)

  return [
    {message: "an index as a shard", result: decodeTripPathShard(indexBytes), reason: PackedRefusal.kindMismatch},
    {message: "an unknown version", result: decodeTripPathShard(wrongVersion), reason: PackedRefusal.unsupportedVersion},
    {message: "a cut file", result: decodeTripPathShard(dropLast({bytes: shardBytes, count: 1})), reason: PackedRefusal.truncated},
    {
      message: "bytes after the last section",
      result: decodeTripPathShard(withBytes({bytes: shardBytes, extra: extraByte})),
      reason: PackedRefusal.trailingBytes
    },
    {message: "another section count", result: decodeTripPathShard(fewerSections), reason: PackedRefusal.sectionCount},
    {
      message: "bytes after the last geometry",
      result: shardWithSection({index: GEOMETRY_SECTION, section: withBytes({bytes: geometries, extra: extraByte})}),
      reason: PackedRefusal.badSectionSize
    },
    {
      message: "times past the last trip's",
      result: shardWithSection({index: TIMES_SECTION, section: withBytes({bytes: times, extra: extraByte})}),
      reason: PackedRefusal.badSectionSize
    },
    {
      message: "times that stop short",
      result: shardWithSection({index: TIMES_SECTION, section: dropLast({bytes: times, count: 1})}),
      reason: PackedRefusal.truncated
    }
  ]
}

function shardWithGeometry(hex) {
  return shardWithSection({index: GEOMETRY_SECTION, section: hexBytes(hex)})
}

function shardWithPattern(hex) {
  return shardWithSection({index: PATTERN_SECTION, section: hexBytes(hex)})
}

function shardContentCases() {
  const geometry = shardWithGeometry
  const pattern = shardWithPattern

  return [
    {message: "a geometry of no point", result: geometry(GEOMETRY_NO_POINT), reason: TripPathRefusal.badIndex},
    {message: "a geometry that claims more points than its bytes hold", result: geometry(GEOMETRY_CLAIMS_MORE_POINTS), reason: PackedRefusal.truncated},
    {message: "a pattern that names a geometry the shard lacks", result: pattern(PATTERN_GEOMETRY_UNHELD), reason: TripPathRefusal.badIndex},
    {message: "a pattern of no stop", result: pattern(PATTERN_NO_STOP), reason: TripPathRefusal.badIndex},
    {message: "a pattern with a stop before the stop before it", result: pattern(PATTERN_STEP_BACK), reason: TripPathRefusal.badIndex},
    {message: "a pattern that claims more stops than its bytes hold", result: pattern(PATTERN_CLAIMS_MORE_STOPS), reason: PackedRefusal.truncated}
  ]
}

function shardTripCases() {
  const tripSection = splitSections(shardBytes)[TRIP_SECTION]
  const values = readU32s(tripSection)
  const {tripCount} = expected.shard
  const blockOf = (block) => values.slice(block * tripCount, (block + 1) * tripCount)
  const strings = blockOf(FIRST_BLOCK)
  const patterns = blockOf(SECOND_BLOCK)
  const offsets = blockOf(THIRD_BLOCK)
  const [firstString, secondString] = strings
  const [firstPattern, secondPattern] = patterns
  const [firstOffset, secondOffset] = offsets
  const shortColumn = dropLast({bytes: tripSection, count: U32_BYTES})

  return [
    {
      message: "a trip that names a string the table lacks",
      result: shardWithColumns([[STRING_INDEX_UNHELD, secondString], patterns, offsets]),
      reason: TripPathRefusal.badIndex
    },
    {
      message: "a trip that names a pattern the shard lacks",
      result: shardWithColumns([strings, [PATTERN_INDEX_UNHELD, secondPattern], offsets]),
      reason: TripPathRefusal.badIndex
    },
    {
      message: "two trips of one identifier",
      result: shardWithColumns([[firstString, firstString], patterns, offsets]),
      reason: TripPathRefusal.badIndex
    },
    {
      message: "times that start off the run",
      result: shardWithColumns([strings, [firstPattern, secondPattern], [firstOffset + OFFSET_SKEW, secondOffset]]),
      reason: TripPathRefusal.badIndex
    },
    {
      message: "a trip column that is not three values a trip",
      result: shardWithSection({index: TRIP_SECTION, section: shortColumn}),
      reason: PackedRefusal.badSectionSize
    }
  ]
}

function indexWithSection({index, section}) {
  return decodeTripPathIndex(withSection({bytes: indexBytes, index, section}))
}

function indexCases() {
  const sections = splitSections(indexBytes)
  const columns = sections[INDEX_COLUMN_SECTION]
  const hashes = sections[INDEX_HASH_SECTION]
  const values = readU32s(columns)
  const [firstRoute, ...rest] = values
  const [, ...afterSecondRoute] = rest
  const wrongVersion = withVersion({bytes: indexBytes, version: VERSION_UNKNOWN})
  const unheldRoute = u32s([STRING_INDEX_UNHELD, ...rest])
  const twiceRoute = u32s([firstRoute, firstRoute, ...afterSecondRoute])

  return [
    {message: "a shard as an index", result: decodeTripPathIndex(shardBytes), reason: PackedRefusal.kindMismatch},
    {message: "an unknown version", result: decodeTripPathIndex(wrongVersion), reason: PackedRefusal.unsupportedVersion},
    {
      message: "a hash section of another length than 32 bytes a route",
      result: indexWithSection({index: INDEX_HASH_SECTION, section: dropLast({bytes: hashes, count: 1})}),
      reason: PackedRefusal.badSectionSize
    },
    {
      message: "a column section of another length than three values a route",
      result: indexWithSection({index: INDEX_COLUMN_SECTION, section: dropLast({bytes: columns, count: U32_BYTES})}),
      reason: PackedRefusal.badSectionSize
    },
    {
      message: "a route that names a string the table lacks",
      result: indexWithSection({index: INDEX_COLUMN_SECTION, section: unheldRoute}),
      reason: TripPathRefusal.badIndex
    },
    {
      message: "two records of one route",
      result: indexWithSection({index: INDEX_COLUMN_SECTION, section: twiceRoute}),
      reason: TripPathRefusal.badIndex
    }
  ]
}

function checkRefusals(cases) {
  for (const {message, result, reason} of cases) {
    deepStrictEqual(result, refusal(reason), message)
  }
}

function checkHashWidth() {
  const hashes = splitSections(indexBytes)[INDEX_HASH_SECTION]
  deepStrictEqual(hashes.length, expected.index.records.length * SHA256_BYTES, "the fixture's hashes are 32 bytes a route")
}

await checkStoredStreams()
checkShard()
checkIndex()
checkRefusals(shardContainerCases())
checkRefusals(shardContentCases())
checkRefusals(shardTripCases())
checkRefusals(indexCases())
checkHashWidth()
console.log("trip path shard checks passed")
