// Decodes the shared intersection fixtures, a shard and an index, expanded and
// as gzip streams, compares each table with the expected one the fixtures hold
// beside them, checks the refusals as values (another version, the other kind,
// another section count, an index past the string table, a crossing count of
// zero, a column of another length, a path of another length, a position past
// the globe, bytes after the positions, a digest section of another length,
// and an expansion past each kind's bound), and then checks the lookup: the
// text read as two streets, the shard the index names for the first street,
// and the crossing nearest a point in the fixture's shard. Run it with
// `node test/scripts/intersection_lookup_check.mjs`; it exits non-zero on the
// first result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual, strictEqual} from "node:assert/strict"
import {
  INTERSECTION_INDEX_EXPANDED_BYTES_MAX,
  INTERSECTION_SHARD_EXPANDED_BYTES_MAX,
  IntersectionFileRefusal,
  IntersectionIndexSection,
  IntersectionShardSection,
  decodeIntersectionIndex,
  decodeIntersectionShard,
  loadIntersectionIndex,
  loadIntersectionShard,
} from "../../assets/js/intersection_file.js"
import {
  IntersectionLookupKind,
  NotAnIntersectionReason,
  planIntersection,
  searchIntersection,
} from "../../assets/js/intersection_lookup.js"
import {PackedKind, PackedOutcome, PackedRefusal, packedFileName} from "../../assets/js/packed_container.js"

const fixtureDirectory = fileURLToPath(new URL("../fixtures/intersections/v1/", import.meta.url))
const HEADER_BYTES = 16
const VERSION_OFFSET = 4
const VERSION_SECOND = 2
const U32_BYTES = 4
const U32_MAX = 4_294_967_295
const VARINT_BASE = 128
const STRING_TABLE_SECTIONS = 1
const KEY_PAST_TABLE = 999
const ZIGZAG_FACTOR = 2
const FIXTURE_STREET_COUNT = 6
const FIXTURE_CROSSING_COUNT = 11
const FIXTURE_SHARD_COUNT = 4
const DIGEST_BYTES = 32
const ZIGZAG_MAX_MAGNITUDE = 2_147_483_647
const PATH_COUNT_PAST_GLOBE = 4
const PATH_PADDING_BYTES = 8
const BOUND_PAD_BYTES = 16
const LITTLE_ENDIAN = true
const MICRODEGREES_PER_DEGREE = 1_000_000
const METERS_PER_DEGREE = 111_195
const SEATTLE_CENTER = Object.freeze({lat: 47.6062, lon: -122.3321})
const PIKE_AT_FOURTH = Object.freeze({lat: 47.6112, lon: -122.3357})
const POLE_CORNER = Object.freeze({lat: 90, lon: 180})
const MAIN_LATITUDE_NEAREST = 47.6
const MAIN_LATITUDE_MIDDLE = 47.7
const MAIN_LATITUDE_FARTHEST = 47.5
const MAIN_AT_FIRST_LATITUDES = Object.freeze([MAIN_LATITUDE_MIDDLE, MAIN_LATITUDE_FARTHEST, MAIN_LATITUDE_NEAREST])
const MAIN_AT_FIRST_NEAREST_FIRST = Object.freeze([MAIN_LATITUDE_NEAREST, MAIN_LATITUDE_MIDDLE, MAIN_LATITUDE_FARTHEST])
const ZEROED_COUNT_SKIP = 2
const EMPTY_PREFIX_SHARD = 0
const OWN_NAME_SHARD = 1
const EXTENDED_PREFIX_SHARD = 2
const MANY_CROSSING_COUNT = 7
const LATITUDE_STEP = 0.01
const RESULT_COUNT_MAX = 5
const OMITTED_BOTH_TYPES = 2
const MAIN_KEYS = Object.freeze(["MAIN ST", "1ST AVE"])
const TYPED_PLANS = Object.freeze(["4th & Pike", "Pine and 3rd", "3rd Ave @ Pine St", "Fourth Avenue and Pike Street"])
const NOT_INTERSECTIONS = Object.freeze(["Pike Street", "400 Broad St", "& Pike", "Pike &", ""])
const MISSING_TEXTS = Object.freeze(["3rd St & Pike", "3rd & Zed", "3rd & Pine Ave", "Nowhere & Pike"])

const expected = JSON.parse(readFileSync(fixtureDirectory + "expected.json", "utf-8"))
const shardBytes = new Uint8Array(readFileSync(fixtureDirectory + "shard.bin"))
const shardStream = new Uint8Array(readFileSync(fixtureDirectory + "shard.bin.gz"))
const indexBytes = new Uint8Array(readFileSync(fixtureDirectory + "index.bin"))
const indexStream = new Uint8Array(readFileSync(fixtureDirectory + "index.bin.gz"))

function stringAt(table) {
  return (index) => table.strings[index]
}

function plainShard(table) {
  const text = stringAt(table)

  return {
    streetCount: table.streetCount,
    keys: Array.from(table.keys, text),
    crossingStarts: Array.from(table.crossingStarts),
    others: Array.from(table.others, text),
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
  const joined = Array.from(source.slice(0, HEADER_BYTES))
  let offset = HEADER_BYTES
  let position = 0

  while (offset < source.byteLength) {
    const length = view.getUint32(offset, LITTLE_ENDIAN)
    let section = source.slice(offset + U32_BYTES, offset + U32_BYTES + length)

    if (position === index) {
      section = Uint8Array.from(replacement)
    }

    for (const byte of u32Column([section.byteLength])) {
      joined.push(byte)
    }

    for (const byte of section) {
      joined.push(byte)
    }

    offset += U32_BYTES + length
    position += 1
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

function indexAt(_value, index) {
  return index
}

function indexRun(count) {
  return Array.from({length: count}, indexAt)
}

// The crossings of each street of the fixture, from the starts it expects.
function fixtureCounts() {
  const starts = expected.shard.crossingStarts
  const counts = []

  for (let street = 0; street < FIXTURE_STREET_COUNT; street += 1) {
    counts.push(starts[street + 1] - starts[street])
  }

  return counts
}

function checkDecodes() {
  const shard = decodeIntersectionShard(shardBytes)
  strictEqual(shard.kind, PackedOutcome.decoded)
  deepStrictEqual(plainShard(shard.table), expected.shard, "the expanded shard")

  const index = decodeIntersectionIndex(indexBytes)
  strictEqual(index.kind, PackedOutcome.decoded)
  deepStrictEqual(plainIndex(index.table), expected.index, "the expanded index")
}

async function checkLoads() {
  const shard = await loadIntersectionShard(shardStream)
  strictEqual(shard.kind, PackedOutcome.decoded)
  deepStrictEqual(plainShard(shard.table), expected.shard, "the gzip shard")

  const index = await loadIntersectionIndex(indexStream)
  strictEqual(index.kind, PackedOutcome.decoded)
  deepStrictEqual(plainIndex(index.table), expected.index, "the gzip index")
}

function checkHeaderRefusals() {
  const otherVersion = new Uint8Array(shardBytes)
  new DataView(otherVersion.buffer).setUint16(VERSION_OFFSET, VERSION_SECOND, LITTLE_ENDIAN)
  expectRefusal({label: "another version", result: decodeIntersectionShard(otherVersion), reason: PackedRefusal.unsupportedVersion})

  expectRefusal({label: "an index read as a shard", result: decodeIntersectionShard(indexBytes), reason: PackedRefusal.kindMismatch})
  expectRefusal({label: "a shard read as an index", result: decodeIntersectionIndex(shardBytes), reason: PackedRefusal.kindMismatch})

  const extraSection = new Uint8Array(shardBytes.byteLength + U32_BYTES)
  extraSection.set(shardBytes)
  expectRefusal({label: "another section count", result: decodeIntersectionShard(extraSection), reason: PackedRefusal.sectionCount})
}

function checkShardKeyAndCountRefusals() {
  const keyPast = shardWith({section: IntersectionShardSection.keys, replacement: u32Column([...indexRun(FIXTURE_STREET_COUNT - 1), KEY_PAST_TABLE])})
  expectRefusal({label: "a key past the string table", result: decodeIntersectionShard(keyPast), reason: IntersectionFileRefusal.badStringIndex})

  const counts = fixtureCounts()
  const zeroCount = shardWith({section: IntersectionShardSection.counts, replacement: u32Column([0, ...counts.slice(1)])})
  expectRefusal({label: "a crossing count of zero", result: decodeIntersectionShard(zeroCount), reason: IntersectionFileRefusal.badCounts})

  const shortCounts = shardWith({section: IntersectionShardSection.counts, replacement: u32Column([1])})
  expectRefusal({label: "a count column of another length", result: decodeIntersectionShard(shortCounts), reason: PackedRefusal.badSectionSize})

  const bigCount = shardWith({section: IntersectionShardSection.counts, replacement: u32Column([U32_MAX, U32_MAX, ...counts.slice(ZEROED_COUNT_SKIP)])})
  expectRefusal({label: "counts that pass 32 bits", result: decodeIntersectionShard(bigCount), reason: IntersectionFileRefusal.badCounts})

  const otherPast = shardWith({section: IntersectionShardSection.others, replacement: u32Column([KEY_PAST_TABLE, ...indexRun(FIXTURE_CROSSING_COUNT - 1)])})
  expectRefusal({label: "another street past the string table", result: decodeIntersectionShard(otherPast), reason: IntersectionFileRefusal.badStringIndex})

  const shortOthers = shardWith({section: IntersectionShardSection.others, replacement: u32Column([0])})
  expectRefusal({label: "an others column of another length", result: decodeIntersectionShard(shortOthers), reason: PackedRefusal.badSectionSize})
}

function checkShardPositionRefusals() {
  const positions = sectionOf({source: shardBytes, index: IntersectionShardSection.positions + STRING_TABLE_SECTIONS})
  const onePoint = [...varint(1), ...varint(zigzag(1)), ...varint(zigzag(1))]
  const mismatched = shardWith({section: IntersectionShardSection.positions, replacement: [...onePoint, ...positions]})
  expectRefusal({label: "a path of another length", result: decodeIntersectionShard(mismatched), reason: IntersectionFileRefusal.countMismatch})

  const leftover = shardWith({section: IntersectionShardSection.positions, replacement: [...positions, ...onePoint]})
  expectRefusal({label: "bytes after the positions", result: decodeIntersectionShard(leftover), reason: PackedRefusal.badSectionSize})

  const pastGlobe = [...varint(PATH_COUNT_PAST_GLOBE), ...varint(zigzag(ZIGZAG_MAX_MAGNITUDE)), 0, ...new Array(PATH_PADDING_BYTES).fill(0)]
  const badPosition = shardWith({section: IntersectionShardSection.positions, replacement: pastGlobe})
  expectRefusal({label: "a position past the globe", result: decodeIntersectionShard(badPosition), reason: PackedRefusal.badPosition})
}

function checkIndexRefusals() {
  const prefixPast = indexWith({section: IntersectionIndexSection.prefixes, replacement: u32Column([...indexRun(FIXTURE_SHARD_COUNT - 1), KEY_PAST_TABLE])})
  expectRefusal({label: "a prefix past the string table", result: decodeIntersectionIndex(prefixPast), reason: IntersectionFileRefusal.badStringIndex})

  const shortDigests = indexWith({section: IntersectionIndexSection.digests, replacement: new Array(DIGEST_BYTES).fill(0)})
  const names = decodeIntersectionIndex(indexBytes).table.paths
  deepStrictEqual(names, expected.index.paths, "the file names the digests make")
  strictEqual(names[0], packedFileName({kind: PackedKind.intersectionShard, sha256: expected.index.sha256s[0]}))
  expectRefusal({label: "digests of another length", result: decodeIntersectionIndex(shortDigests), reason: PackedRefusal.badSectionSize})
}

async function checkBounds() {
  for (const {load, bound, label} of [
    {load: loadIntersectionShard, bound: INTERSECTION_SHARD_EXPANDED_BYTES_MAX, label: "a shard"},
    {load: loadIntersectionIndex, bound: INTERSECTION_INDEX_EXPANDED_BYTES_MAX, label: "an index"},
  ]) {
    const tooLarge = new Uint8Array(bound + BOUND_PAD_BYTES)
    const compressedStream = new Blob([tooLarge]).stream().pipeThrough(new CompressionStream("gzip"))
    const compressed = await new Response(compressedStream).arrayBuffer()
    const result = await load(new Uint8Array(compressed))
    expectRefusal({label: `${label} expanding past its bound`, result, reason: PackedRefusal.tooLarge})
  }
}

// --- The lookup ------------------------------------------------------------

const index = decodeIntersectionIndex(indexBytes).table
const shard = decodeIntersectionShard(shardBytes).table

function planOf(text) {
  return planIntersection({text, index})
}

function searchText({text, table = shard, near = SEATTLE_CENTER}) {
  const plan = planOf(text)
  strictEqual(plan.kind, IntersectionLookupKind.plan, `a plan for ${text}`)
  return searchIntersection({query: plan.query, shard: table, near})
}

function labelOf(entry) {
  return entry.label
}

function latOf(entry) {
  return entry.lat
}

function labelsOf(result) {
  strictEqual(result.kind, IntersectionLookupKind.found)
  return Array.from(result.results, labelOf)
}

function checkPlans() {
  for (const text of TYPED_PLANS) {
    const plan = planOf(text)
    strictEqual(plan.kind, IntersectionLookupKind.plan, text)
    strictEqual(plan.path, expected.index.paths[EMPTY_PREFIX_SHARD], `${text} is in the shard of the empty prefix`)
  }

  const pine = planOf("Pine and 3rd")
  deepStrictEqual(pine.query.first, {preDirection: "", name: "PINE", type: "", sufDirection: ""})
  deepStrictEqual(pine.query.second, {preDirection: "", name: "3RD", type: "", sufDirection: ""})

  const ownName = planOf("Pike & 3rd")
  deepStrictEqual([ownName.prefix, ownName.path], ["PIKE$", expected.index.paths[OWN_NAME_SHARD]], "a street named by the prefix alone")

  const longer = planOf("Pikeville Rd & Main")
  deepStrictEqual([longer.prefix, longer.path], ["PIKE", expected.index.paths[EXTENDED_PREFIX_SHARD]], "a street a prefix extends")

  const multibyte = planOf("École Rd & 3rd")
  strictEqual(multibyte.prefix, "ÉCOLE", "a multibyte prefix")

  for (const text of NOT_INTERSECTIONS) {
    const reason = NotAnIntersectionReason.notTwoStreets
    deepStrictEqual(planOf(text), {kind: IntersectionLookupKind.notAnIntersection, reason}, `"${text}"`)
  }
}

function checkNoShard() {
  const withoutEmptyPrefix = {...index, prefixes: ["PIKE$"], paths: ["a"], shardCount: 1}
  const plan = planIntersection({text: "Elm & Oak", index: withoutEmptyPrefix})
  deepStrictEqual(plan, {kind: IntersectionLookupKind.noShard})
}

function checkFourthAndPike() {
  const fourth = searchText({text: "4th & Pike"})
  const labels = labelsOf(fourth)
  deepStrictEqual(labels, ["4TH AVE & PIKE ST"])
  strictEqual(fourth.results[0].lat, PIKE_AT_FOURTH.lat)
  strictEqual(fourth.results[0].lon, PIKE_AT_FOURTH.lon)
  strictEqual(fourth.results[0].omittedPartCount, OMITTED_BOTH_TYPES, "the types of both streets were left out")
}

function checkOtherForms() {
  const pine = searchText({text: "Pine and 3rd"})
  deepStrictEqual(labelsOf(pine), ["PINE ST & 3RD AVE"])

  const typed = searchText({text: "3rd Ave @ Pine St"})
  deepStrictEqual(labelsOf(typed), ["3RD AVE & PINE ST"])
  strictEqual(typed.results[0].omittedPartCount, 0)

  const slash = searchText({text: "Pike / 4th"})
  deepStrictEqual(labelsOf(slash), ["PIKE ST & 4TH AVE"], "the order typed is either street first")

  const corner = searchText({text: "Pole & équateur"})
  deepStrictEqual([corner.results[0].lat, corner.results[0].lon], [POLE_CORNER.lat, POLE_CORNER.lon], "a multibyte street at the corner of the globe")

  const zed = searchText({text: "Zed & 3rd"})
  deepStrictEqual([zed.results[0].lat, zed.results[0].lon], [0, 0])
}

function checkMisses() {
  for (const text of MISSING_TEXTS) {
    const result = searchText({text})
    deepStrictEqual(result, {kind: IntersectionLookupKind.missing}, text)
  }
}

function microdegrees(degrees) {
  return Math.round(degrees * MICRODEGREES_PER_DEGREE)
}

function positionsAt(latitudes) {
  const positions = []

  for (const lat of latitudes) {
    positions.push(microdegrees(lat), microdegrees(SEATTLE_CENTER.lon))
  }

  return Int32Array.from(positions)
}

// Every crossing of the table below is with the second of its strings.
function otherIndexOf() {
  return 1
}

// A table of one street, "MAIN ST", and its crossings with "1ST AVE" at the
// latitudes, one point each.
function mainTable(latitudes) {
  return {
    streetCount: 1,
    strings: MAIN_KEYS,
    keys: Uint32Array.from([0]),
    crossingStarts: Uint32Array.from([0, latitudes.length]),
    others: Uint32Array.from(latitudes, otherIndexOf),
    positions: positionsAt(latitudes),
  }
}

function checkNearness() {
  const result = searchText({text: "Main & 1st", table: mainTable(MAIN_AT_FIRST_LATITUDES)})
  const latitudes = Array.from(result.results, latOf)
  deepStrictEqual(latitudes, Array.from(MAIN_AT_FIRST_NEAREST_FIRST), "nearest first, by distance from the point")

  const nearestMeters = Math.round((SEATTLE_CENTER.lat - MAIN_LATITUDE_NEAREST) * METERS_PER_DEGREE)
  strictEqual(result.results[0].distanceM, nearestMeters, "the distance in meters")

  const steps = Array.from({length: MANY_CROSSING_COUNT}, stepOf)
  const many = searchText({text: "Main & 1st", table: mainTable(steps)})
  strictEqual(many.results.length, RESULT_COUNT_MAX, "at most five")
}

function stepOf(_value, step) {
  return MAIN_LATITUDE_NEAREST + step * LATITUDE_STEP
}

checkDecodes()
await checkLoads()
checkHeaderRefusals()
checkShardKeyAndCountRefusals()
checkShardPositionRefusals()
checkIndexRefusals()
await checkBounds()
checkPlans()
checkNoShard()
checkFourthAndPike()
checkOtherForms()
checkMisses()
checkNearness()
console.log("intersection_lookup_check: ok")
