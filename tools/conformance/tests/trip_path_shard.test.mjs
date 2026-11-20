// Decodes the shared trip path fixtures of test/fixtures/routing/trip-paths-v1
// with the trip path readers, the loop route's shard, expanded and as a gzip
// stream, and the index, against the expected values beside them. It checks
// that the loop trip's path read from the shard is the frozen object
// `decodeTripPath` returns for the same trip's encoded event, which the Elixir
// tests pin to the server's builder; that a trip the shard lacks is a value;
// and that each rule a file can break is refused as a value. The gzip
// expansion is the web shell's, so its cases run once.

import {beforeAll, describe, expect, test} from "vitest"
import {expandStream} from "../../../assets/js/packed_stream.js"
import {hexBytes} from "../bytes.mjs"
import {fixtureBytes, fixtureJson} from "../fixtures.mjs"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const FIXTURE_DIRECTORY = "routing/trip-paths-v1/"
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

let expected = null
let loopEvent = null
let shardBytes = null
let indexBytes = null
let shardStream = null
let indexStream = null

async function fileBytes(name) {
  const buffer = await fixtureBytes(FIXTURE_DIRECTORY + name)
  return new Uint8Array(buffer)
}

beforeAll(async () => {
  expected = await fixtureJson(FIXTURE_DIRECTORY + "expected.json")
  const loop = await fixtureJson("one_bus_away/trip_path/encoded_loop.json")
  loopEvent = loop.event
  shardBytes = await fileBytes("shard.bin")
  indexBytes = await fileBytes("index.bin")
  shardStream = await fileBytes("shard.bin.gz")
  indexStream = await fileBytes("index.bin.gz")
})

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

function sectionBytes(section) {
  return U32_BYTES + section.length
}

function sumOf(left, right) {
  return left + right
}

// The fixture's two stored forms hold one content each.
describe("trip path streams", () => {
  // The bound is the core's, so the JavaScript core names it here.
  const {CONTAINER_EXPANDED_BYTES_MAX, PackedOutcome} = IMPLEMENTATIONS[0].packedContainer
  const options = {expandedByteSizeMax: CONTAINER_EXPANDED_BYTES_MAX}

  test("the gzip stream expands to the shard", async () => {
    const shardExpanded = await expandStream(shardStream, options)
    expect(shardExpanded.kind).toBe(PackedOutcome.expanded)
    expect(shardExpanded.bytes).toStrictEqual(shardBytes)
  })

  test("the gzip stream expands to the index", async () => {
    const indexExpanded = await expandStream(indexStream, options)
    expect(indexExpanded.bytes).toStrictEqual(indexBytes)
  })
})

describe.each(IMPLEMENTATIONS)("trip path shard ($name)", ({packedContainer, tripPath, tripPathShard}) => {
  const {HEADER_BYTES, PackedOutcome, PackedRefusal} = packedContainer
  const {TripPathLookup, TripPathRefusal, decodeTripPathIndex, decodeTripPathShard, indexEntries, tripPathFromShard} = tripPathShard

  function decodedOf(result) {
    expect(result.kind).toBe(PackedOutcome.decoded)
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

  // The container of `bytes` with the section at `index`, counting the string
  // table as 0, replaced by `section`.
  function withSection({bytes, index, section}) {
    const sections = splitSections(bytes)
    sections[index] = section
    const header = bytes.slice(0, HEADER_BYTES)
    return assemble({header, sections})
  }

  function decodedShard() {
    const {shard} = decodedOf(decodeTripPathShard(shardBytes))
    return shard
  }

  function decodedIndex() {
    const {index} = decodedOf(decodeTripPathIndex(indexBytes))
    return index
  }

  test("the trip count", () => {
    expect(decodedShard().tripCount).toBe(expected.shard.tripCount)
  })

  test("each expected trip's points, distances, and times", () => {
    const shard = decodedShard()

    for (const trip of expected.shard.trips) {
      const path = tripPathFromShard(shard, {tripId: trip.id, routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS})
      const [firstLatitude, firstLongitude] = trip.firstPointE5
      const [lastLatitude, lastLongitude] = trip.lastPointE5
      const lastPoint = path.points[path.points.length - 1]
      expect(path.points.length).toBe(trip.pointCount)
      expect(path.points[0]).toStrictEqual([degreesOf(firstLongitude), degreesOf(firstLatitude)])
      expect(lastPoint).toStrictEqual([degreesOf(lastLongitude), degreesOf(lastLatitude)])
      const distances = Array.from(path.stops, stopDistance)
      const arrivals = Array.from(path.stops, stopArrival)
      const departures = Array.from(path.stops, stopDeparture)
      expect(distances).toStrictEqual(trip.stopDistancesM)
      expect(arrivals).toStrictEqual(trip.arrivalS)
      expect(departures).toStrictEqual(trip.departureS)
    }
  })

  function loopFromShard() {
    const loopTrip = {tripId: loopEvent.trip_id, routeId: loopEvent.route_id, serviceDateMs: loopEvent.service_date_ms}
    return tripPathFromShard(decodedShard(), loopTrip)
  }

  test("the shard's path is the event's decoded path", () => {
    const fromEvent = tripPath.decodeTripPath(loopEvent)
    expect(loopFromShard()).toStrictEqual(fromEvent)
  })

  test("the path is frozen", () => {
    const fromShard = loopFromShard()
    expect(Object.isFrozen(fromShard)).toBe(true)
  })

  test("a point is frozen", () => {
    const fromShard = loopFromShard()
    expect(Object.isFrozen(fromShard.points[0])).toBe(true)
  })

  test("a stop is frozen", () => {
    const fromShard = loopFromShard()
    expect(Object.isFrozen(fromShard.stops[0])).toBe(true)
  })

  test("a trip the shard lacks", () => {
    const absent = {tripId: "1_none", routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}
    const shard = decodedShard()
    expect(tripPathFromShard(shard, absent)).toStrictEqual({kind: TripPathLookup.missing})
  })

  test("the route count", () => {
    expect(decodedIndex().routeCount).toBe(expected.index.records.length)
  })

  test("the entry of each route", () => {
    const index = decodedIndex()

    for (const record of expected.index.records) {
      const entry = {path: record.path, byteSize: record.byteSize, sha256: record.sha256}
      expect(index.entryOf(record.routeId)).toStrictEqual(entry)
    }
  })

  test("a route the index lacks", () => {
    expect(decodedIndex().entryOf("1_none")).toStrictEqual({kind: TripPathLookup.missing})
  })

  test("every route's entry is listed", () => {
    const index = decodedIndex()
    expect(indexEntries(index).length).toBe(index.routeCount)
  })

  test("the listed entries are in the index's order", () => {
    const listed = indexEntries(decodedIndex())

    for (const [position, record] of expected.index.records.entries()) {
      const entry = {path: record.path, byteSize: record.byteSize, sha256: record.sha256}
      expect(listed[position]).toStrictEqual(entry)
    }
  })

  function shardWithSection({index, section}) {
    const bytes = withSection({bytes: shardBytes, index, section})
    return decodeTripPathShard(bytes)
  }

  function shardWithColumns(columns) {
    const section = u32s(columns.flat())
    return shardWithSection({index: TRIP_SECTION, section})
  }

  function indexWithSection({index, section}) {
    const bytes = withSection({bytes: indexBytes, index, section})
    return decodeTripPathIndex(bytes)
  }

  function geometryWith(hex) {
    const section = hexBytes(hex)
    return shardWithSection({index: GEOMETRY_SECTION, section})
  }

  function patternWith(hex) {
    const section = hexBytes(hex)
    return shardWithSection({index: PATTERN_SECTION, section})
  }

  function tripColumns() {
    const tripSection = splitSections(shardBytes)[TRIP_SECTION]
    const values = readU32s(tripSection)
    const {tripCount} = expected.shard
    const strings = values.slice(FIRST_BLOCK * tripCount, SECOND_BLOCK * tripCount)
    const patterns = values.slice(SECOND_BLOCK * tripCount, THIRD_BLOCK * tripCount)
    const offsets = values.slice(THIRD_BLOCK * tripCount, (THIRD_BLOCK + 1) * tripCount)
    return {tripSection, strings, patterns, offsets}
  }

  const refusalCases = [
    {name: "an index as a shard", result: () => decodeTripPathShard(indexBytes), reason: () => PackedRefusal.kindMismatch},
    {
      name: "a shard of an unknown version",
      result: () => decodeTripPathShard(withVersion({bytes: shardBytes, version: VERSION_UNKNOWN})),
      reason: () => PackedRefusal.unsupportedVersion
    },
    {name: "a cut shard", result: () => decodeTripPathShard(dropLast({bytes: shardBytes, count: 1})), reason: () => PackedRefusal.truncated},
    {
      name: "bytes after the shard's last section",
      result: () => decodeTripPathShard(withBytes({bytes: shardBytes, extra: hexBytes(EXTRA_BYTE)})),
      reason: () => PackedRefusal.trailingBytes
    },
    {
      name: "another section count",
      result: () => {
        const sectionsKept = splitSections(shardBytes).slice(0, PATTERN_SECTION)
        const header = shardBytes.slice(0, HEADER_BYTES)
        return decodeTripPathShard(assemble({header, sections: sectionsKept}))
      },
      reason: () => PackedRefusal.sectionCount
    },
    {
      name: "bytes after the last geometry",
      result: () => {
        const geometries = splitSections(shardBytes)[GEOMETRY_SECTION]
        const extra = hexBytes(EXTRA_BYTE)
        return shardWithSection({index: GEOMETRY_SECTION, section: withBytes({bytes: geometries, extra})})
      },
      reason: () => PackedRefusal.badSectionSize
    },
    {
      name: "times past the last trip's",
      result: () => {
        const times = splitSections(shardBytes)[TIMES_SECTION]
        const extra = hexBytes(EXTRA_BYTE)
        return shardWithSection({index: TIMES_SECTION, section: withBytes({bytes: times, extra})})
      },
      reason: () => PackedRefusal.badSectionSize
    },
    {
      name: "times that stop short",
      result: () => {
        const times = splitSections(shardBytes)[TIMES_SECTION]
        return shardWithSection({index: TIMES_SECTION, section: dropLast({bytes: times, count: 1})})
      },
      reason: () => PackedRefusal.truncated
    },
    {name: "a geometry of no point", result: () => geometryWith(GEOMETRY_NO_POINT), reason: () => TripPathRefusal.badIndex},
    {
      name: "a geometry that claims more points than its bytes hold",
      result: () => geometryWith(GEOMETRY_CLAIMS_MORE_POINTS),
      reason: () => PackedRefusal.truncated
    },
    {name: "a pattern that names a geometry the shard lacks", result: () => patternWith(PATTERN_GEOMETRY_UNHELD), reason: () => TripPathRefusal.badIndex},
    {name: "a pattern of no stop", result: () => patternWith(PATTERN_NO_STOP), reason: () => TripPathRefusal.badIndex},
    {name: "a pattern with a stop before the stop before it", result: () => patternWith(PATTERN_STEP_BACK), reason: () => TripPathRefusal.badIndex},
    {
      name: "a pattern that claims more stops than its bytes hold",
      result: () => patternWith(PATTERN_CLAIMS_MORE_STOPS),
      reason: () => PackedRefusal.truncated
    },
    {
      name: "a trip that names a string the table lacks",
      result: () => {
        const {strings, patterns, offsets} = tripColumns()
        return shardWithColumns([[STRING_INDEX_UNHELD, strings[1]], patterns, offsets])
      },
      reason: () => TripPathRefusal.badIndex
    },
    {
      name: "a trip that names a pattern the shard lacks",
      result: () => {
        const {strings, patterns, offsets} = tripColumns()
        return shardWithColumns([strings, [PATTERN_INDEX_UNHELD, patterns[1]], offsets])
      },
      reason: () => TripPathRefusal.badIndex
    },
    {
      name: "two trips of one identifier",
      result: () => {
        const {strings, patterns, offsets} = tripColumns()
        return shardWithColumns([[strings[0], strings[0]], patterns, offsets])
      },
      reason: () => TripPathRefusal.badIndex
    },
    {
      name: "times that start off the run",
      result: () => {
        const {strings, patterns, offsets} = tripColumns()
        return shardWithColumns([strings, patterns, [offsets[0] + OFFSET_SKEW, offsets[1]]])
      },
      reason: () => TripPathRefusal.badIndex
    },
    {
      name: "a trip column that is not three values a trip",
      result: () => {
        const {tripSection} = tripColumns()
        return shardWithSection({index: TRIP_SECTION, section: dropLast({bytes: tripSection, count: U32_BYTES})})
      },
      reason: () => PackedRefusal.badSectionSize
    },
    {name: "a shard as an index", result: () => decodeTripPathIndex(shardBytes), reason: () => PackedRefusal.kindMismatch},
    {
      name: "an index of an unknown version",
      result: () => decodeTripPathIndex(withVersion({bytes: indexBytes, version: VERSION_UNKNOWN})),
      reason: () => PackedRefusal.unsupportedVersion
    },
    {
      name: "a hash section of another length than 32 bytes a route",
      result: () => {
        const hashes = splitSections(indexBytes)[INDEX_HASH_SECTION]
        return indexWithSection({index: INDEX_HASH_SECTION, section: dropLast({bytes: hashes, count: 1})})
      },
      reason: () => PackedRefusal.badSectionSize
    },
    {
      name: "a column section of another length than three values a route",
      result: () => {
        const columns = splitSections(indexBytes)[INDEX_COLUMN_SECTION]
        return indexWithSection({index: INDEX_COLUMN_SECTION, section: dropLast({bytes: columns, count: U32_BYTES})})
      },
      reason: () => PackedRefusal.badSectionSize
    },
    {
      name: "a route that names a string the table lacks",
      result: () => {
        const columns = splitSections(indexBytes)[INDEX_COLUMN_SECTION]
        const [, ...rest] = readU32s(columns)
        return indexWithSection({index: INDEX_COLUMN_SECTION, section: u32s([STRING_INDEX_UNHELD, ...rest])})
      },
      reason: () => TripPathRefusal.badIndex
    },
    {
      name: "two records of one route",
      result: () => {
        const columns = splitSections(indexBytes)[INDEX_COLUMN_SECTION]
        const [firstRoute, , ...afterSecondRoute] = readU32s(columns)
        return indexWithSection({index: INDEX_COLUMN_SECTION, section: u32s([firstRoute, firstRoute, ...afterSecondRoute])})
      },
      reason: () => TripPathRefusal.badIndex
    }
  ]

  test.each(refusalCases)("refused: $name", ({result, reason}) => {
    const expectedRefusal = refusal(reason())
    expect(result()).toStrictEqual(expectedRefusal)
  })

  test("the fixture's hashes are 32 bytes a route", () => {
    const hashes = splitSections(indexBytes)[INDEX_HASH_SECTION]
    expect(hashes.length).toBe(expected.index.records.length * SHA256_BYTES)
  })
})
