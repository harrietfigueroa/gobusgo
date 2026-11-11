// Decodes the shared trip path fixtures of test/fixtures/routing/trip-paths-v1
// with the JavaScript readers of assets/js/trip_path_shard.js: the loop
// route's shard, expanded and as a gzip stream, and the index, against the
// expected values beside them; checks that the loop trip's path read from
// the shard is the frozen object `decodeTripPath` returns for the same trip's
// encoded event, which the Elixir tests pin to the server's builder; that a
// trip the shard lacks is a value; and that each rule a file can break is
// refused as a value. Run it with
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
  tripPathFromShard
} from "../../assets/js/trip_path_shard.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/routing/trip-paths-v1/", import.meta.url))
const loopDirectory = fileURLToPath(new URL("../fixtures/one_bus_away/trip_path/", import.meta.url))
const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const {event: loopEvent} = JSON.parse(readFileSync(loopDirectory + "encoded_loop.json", "utf-8"))
const MICRODEGREES_PER_DEGREE = 1_000_000
const ROUTE_ID = "1_7994"
const SERVICE_DATE_MS = 1_794_211_200_000
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const VERSION_UNKNOWN = 2
const U32_BYTES = 4
const SHA256_BYTES = 32
const GEOMETRY_SECTION = 1
const PATTERN_SECTION = 2
const TRIP_SECTION = 3
const TIMES_SECTION = 4
const INDEX_COLUMN_SECTION = 1
const INDEX_HASH_SECTION = 2
const TRIP_COLUMN_BLOCKS = 3
const STRING_INDEX_UNHELD = 99
const PATTERN_INDEX_UNHELD = 7

const shardBytes = fileBytes("shard.bin")
const indexBytes = fileBytes("index.bin")

function fileBytes(name) {
  return new Uint8Array(readFileSync(fixtureDirectory + name))
}

function decodedOf(result) {
  deepStrictEqual(result.kind, PackedOutcome.decoded, "the file is decoded, not " + JSON.stringify(result))
  return result
}

function refusedWith(result, reason, message) {
  deepStrictEqual(result, {kind: PackedOutcome.refused, reason}, message)
}

// The sections of a container, the string table first, each a copy.
function splitSections(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const sections = []
  let offset = HEADER_BYTES

  while (offset < bytes.byteLength) {
    const length = view.getUint32(offset, true)
    sections.push(bytes.slice(offset + U32_BYTES, offset + U32_BYTES + length))
    offset += U32_BYTES + length
  }

  return sections
}

// The container of `bytes` with the section at `index`, counting the string
// table as 0, replaced by `section`.
function withSection(bytes, index, section) {
  const sections = splitSections(bytes)
  sections[index] = section
  return assemble(bytes.slice(0, HEADER_BYTES), sections)
}

function assemble(header, sections) {
  const total = sections.reduce((sum, section) => sum + U32_BYTES + section.length, header.length)
  const assembled = new Uint8Array(total)
  const view = new DataView(assembled.buffer)
  assembled.set(header, 0)
  let offset = header.length

  for (const section of sections) {
    view.setUint32(offset, section.length, true)
    assembled.set(section, offset + U32_BYTES)
    offset += U32_BYTES + section.length
  }

  return assembled
}

function u32s(values) {
  const bytes = new Uint8Array(values.length * U32_BYTES)
  const view = new DataView(bytes.buffer)
  values.forEach((value, index) => view.setUint32(index * U32_BYTES, value, true))
  return bytes
}

function readU32s(section) {
  const view = new DataView(section.buffer, section.byteOffset, section.byteLength)
  return Array.from({length: section.length / U32_BYTES}, (_unused, index) => view.getUint32(index * U32_BYTES, true))
}

function withBytes(bytes, extra) {
  const joined = new Uint8Array(bytes.length + extra.length)
  joined.set(bytes, 0)
  joined.set(extra, bytes.length)
  return joined
}

function withHeaderField(bytes, offset, value) {
  const copy = bytes.slice()
  new DataView(copy.buffer).setUint16(offset, value, true)
  return copy
}

// The fixture's two stored forms hold one content.
async function checkStoredStream() {
  const stream = fileBytes("shard.bin.gz")
  const expanded = await expandStream(stream, {expandedByteSizeMax: CONTAINER_EXPANDED_BYTES_MAX})
  deepStrictEqual(expanded.kind, PackedOutcome.expanded)
  deepStrictEqual(expanded.bytes, shardBytes, "the gzip stream expands to the shard")

  const indexStream = fileBytes("index.bin.gz")
  const expandedIndex = await expandStream(indexStream, {expandedByteSizeMax: CONTAINER_EXPANDED_BYTES_MAX})
  deepStrictEqual(expandedIndex.bytes, indexBytes, "the gzip stream expands to the index")
}

function checkShard() {
  const {shard} = decodedOf(decodeTripPathShard(shardBytes))
  deepStrictEqual(shard.tripCount, expected.shard.tripCount, "the trip count")

  for (const trip of expected.shard.trips) {
    const path = tripPathFromShard(shard, {tripId: trip.id, routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS})
    const [firstLatitude, firstLongitude] = trip.firstPointMicrodegrees
    const [lastLatitude, lastLongitude] = trip.lastPointMicrodegrees
    deepStrictEqual(path.points.length, trip.pointCount, trip.id + " point count")
    deepStrictEqual(path.points[0], [firstLongitude / MICRODEGREES_PER_DEGREE, firstLatitude / MICRODEGREES_PER_DEGREE])
    deepStrictEqual(
      path.points[path.points.length - 1],
      [lastLongitude / MICRODEGREES_PER_DEGREE, lastLatitude / MICRODEGREES_PER_DEGREE]
    )
    deepStrictEqual(path.stops.map((stop) => stop.distanceMeters), trip.stopDistancesM, trip.id + " distances")
    deepStrictEqual(path.stops.map((stop) => stop.arrivalSeconds), trip.arrivalS, trip.id + " arrivals")
    deepStrictEqual(path.stops.map((stop) => stop.departureSeconds), trip.departureS, trip.id + " departures")
  }

  const fromShard = tripPathFromShard(shard, {
    tripId: loopEvent.trip_id,
    routeId: loopEvent.route_id,
    serviceDateMs: loopEvent.service_date_ms
  })
  deepStrictEqual(fromShard, decodeTripPath(loopEvent), "the shard's path is the event's decoded path")
  ok(Object.isFrozen(fromShard), "the path is frozen")
  ok(Object.isFrozen(fromShard.points[0]), "a point is frozen")
  ok(Object.isFrozen(fromShard.stops[0]), "a stop is frozen")

  deepStrictEqual(
    tripPathFromShard(shard, {tripId: "1_none", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}),
    {kind: TripPathLookup.missing},
    "a trip the shard lacks"
  )
}

function checkIndex() {
  const {index} = decodedOf(decodeTripPathIndex(indexBytes))
  deepStrictEqual(index.routeCount, expected.index.records.length, "the route count")

  for (const record of expected.index.records) {
    deepStrictEqual(
      index.entryOf(record.routeId),
      {path: record.path, byteSize: record.byteSize, sha256: record.sha256},
      "the entry of " + record.routeId
    )
  }

  deepStrictEqual(index.entryOf("1_none"), {kind: TripPathLookup.missing}, "a route the index lacks")
}

function checkShardRefusals() {
  refusedWith(decodeTripPathShard(indexBytes), PackedRefusal.kindMismatch, "an index as a shard")
  refusedWith(
    decodeTripPathShard(withHeaderField(shardBytes, VERSION_OFFSET, VERSION_UNKNOWN)),
    PackedRefusal.unsupportedVersion,
    "a version it does not know"
  )
  refusedWith(
    decodeTripPathShard(shardBytes.slice(0, shardBytes.length - 1)),
    PackedRefusal.truncated,
    "a cut file"
  )
  refusedWith(
    decodeTripPathShard(withBytes(shardBytes, new Uint8Array([0]))),
    PackedRefusal.trailingBytes,
    "bytes after the last section"
  )
  refusedWith(
    decodeTripPathShard(assemble(shardBytes.slice(0, HEADER_BYTES), splitSections(shardBytes).slice(0, 4))),
    PackedRefusal.sectionCount,
    "another section count"
  )

  const geometries = splitSections(shardBytes)[GEOMETRY_SECTION]
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, GEOMETRY_SECTION, withBytes(geometries, new Uint8Array([0])))),
    PackedRefusal.badSectionSize,
    "bytes after the last geometry"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, GEOMETRY_SECTION, new Uint8Array([1, 0]))),
    TripPathRefusal.badIndex,
    "a geometry of no point"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, GEOMETRY_SECTION, new Uint8Array([1, 9, 0]))),
    PackedRefusal.truncated,
    "a geometry that claims more points than its bytes hold"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, PATTERN_SECTION, new Uint8Array([1, 5, 1, 0]))),
    TripPathRefusal.badIndex,
    "a pattern that names a geometry the shard lacks"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, PATTERN_SECTION, new Uint8Array([1, 0, 0]))),
    TripPathRefusal.badIndex,
    "a pattern of no stop"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, PATTERN_SECTION, new Uint8Array([1, 0, 2, 0, 1]))),
    TripPathRefusal.badIndex,
    "a pattern with a stop before the stop before it"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, PATTERN_SECTION, new Uint8Array([1, 0, 5, 0]))),
    PackedRefusal.truncated,
    "a pattern that claims more stops than its bytes hold"
  )
}

function checkShardTripRefusals() {
  const tripSection = splitSections(shardBytes)[TRIP_SECTION]
  const values = readU32s(tripSection)
  const {tripCount} = expected.shard
  const [strings, patterns, offsets] = [0, 1, 2].map((block) => values.slice(block * tripCount, (block + 1) * tripCount))

  const replaced = (columns) => decodeTripPathShard(withSection(shardBytes, TRIP_SECTION, u32s(columns.flat())))

  refusedWith(
    replaced([[STRING_INDEX_UNHELD, strings[1]], patterns, offsets]),
    TripPathRefusal.badIndex,
    "a trip that names a string the table lacks"
  )
  refusedWith(
    replaced([strings, [PATTERN_INDEX_UNHELD, patterns[1]], offsets]),
    TripPathRefusal.badIndex,
    "a trip that names a pattern the shard lacks"
  )
  refusedWith(
    replaced([[strings[0], strings[0]], patterns, offsets]),
    TripPathRefusal.badIndex,
    "two trips of one identifier"
  )
  refusedWith(
    replaced([strings, patterns, [offsets[0] + 1, offsets[1]]]),
    TripPathRefusal.badIndex,
    "times that start off the run"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, TRIP_SECTION, tripSection.slice(0, tripSection.length - U32_BYTES))),
    PackedRefusal.badSectionSize,
    "a trip column that is not three values a trip"
  )

  const times = splitSections(shardBytes)[TIMES_SECTION]
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, TIMES_SECTION, withBytes(times, new Uint8Array([0])))),
    PackedRefusal.badSectionSize,
    "times past the last trip's"
  )
  refusedWith(
    decodeTripPathShard(withSection(shardBytes, TIMES_SECTION, times.slice(0, times.length - 1))),
    PackedRefusal.truncated,
    "times that stop short"
  )
}

function checkIndexRefusals() {
  refusedWith(decodeTripPathIndex(shardBytes), PackedRefusal.kindMismatch, "a shard as an index")
  refusedWith(
    decodeTripPathIndex(withHeaderField(indexBytes, VERSION_OFFSET, VERSION_UNKNOWN)),
    PackedRefusal.unsupportedVersion,
    "a version it does not know"
  )
  const sections = splitSections(indexBytes)
  const columns = sections[INDEX_COLUMN_SECTION]
  const hashes = sections[INDEX_HASH_SECTION]
  refusedWith(
    decodeTripPathIndex(withSection(indexBytes, INDEX_HASH_SECTION, hashes.slice(0, hashes.length - 1))),
    PackedRefusal.badSectionSize,
    "a hash section of another length than 32 bytes a route"
  )
  refusedWith(
    decodeTripPathIndex(withSection(indexBytes, INDEX_COLUMN_SECTION, columns.slice(0, columns.length - U32_BYTES))),
    PackedRefusal.badSectionSize,
    "a column section of another length than three values a route"
  )

  const values = readU32s(columns)
  const count = values.length / TRIP_COLUMN_BLOCKS
  refusedWith(
    decodeTripPathIndex(withSection(indexBytes, INDEX_COLUMN_SECTION, u32s([STRING_INDEX_UNHELD, ...values.slice(1)]))),
    TripPathRefusal.badIndex,
    "a route that names a string the table lacks"
  )
  refusedWith(
    decodeTripPathIndex(withSection(indexBytes, INDEX_COLUMN_SECTION, u32s([values[0], values[0], ...values.slice(2)]))),
    TripPathRefusal.badIndex,
    "two records of one route"
  )
  ok(hashes.length === count * SHA256_BYTES, "the fixture's hashes are 32 bytes a route")
}

await checkStoredStream()
checkShard()
checkIndex()
checkShardRefusals()
checkShardTripRefusals()
checkIndexRefusals()
console.log("trip path shard checks passed")
