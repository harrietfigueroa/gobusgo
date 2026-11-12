// Checks how the arrivals board reads the scheduled departures at a stop
// from the routing manifest and the files it names, over fixture timetables
// encoded to the snapshot files and served from memory: the date a time
// falls in, which files a read asks for and which it spares, the bound, the
// route filter, a time past midnight, the next service date, a date no
// snapshot holds, a stop no snapshot holds, a names file that fails, and a
// file that fails or has the wrong size. Run it with
// `node test/scripts/departure_files_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {gzipSync} from "node:zlib"
import {KeptKind} from "../../assets/js/core/scheduled_service.js"
import {FetchKind, FailureReason} from "../../assets/js/core/routing_journeys.js"
import {DepartureLoadKind, EntriesKind, SERVICE_DAY_MS_MAX, entriesFor, loadDepartures} from "../../assets/js/departure_files.js"
import {seconds, snapshotOf} from "./routing_timetable.js"

// 2026-11-08 and 2026-11-09 at midnight in Seattle, the second a day later.
const DAY_START_MS = 1794124800000
const DAY_MS = 24 * 60 * 60 * 1000
const NEXT_DAY_START_MS = DAY_START_MS + DAY_MS
const FAR_DAY_OFFSET_MS = 4 * 24 * 60 * 60 * 1000
const FAR_DAY_START_MS = DAY_START_MS + FAR_DAY_OFFSET_MS
const SERVICE_DAY_MS_EXPECTED = 25 * 60 * 60 * 1000
const BOUND_SMALL = 2
const BOUND_EXACT = 5
const HOUR_08_CHUNK_INDEX = 2
const SECOND_MS = 1000
const EVERY_ROUTE = Object.freeze({kind: KeptKind.every})
const COUNT_MAX = 40
const ORIGIN_FREE_PATH_PREFIX = "/fixture"

const routes = {
  R1: {shortName: "1", longName: null, color: "112233", agencyId: "1"},
  R2: {shortName: null, longName: "Second Line", color: null, agencyId: "1"}
}

const todayFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "H06", route: "R1", stopTimes: [["S1", "06:10"], ["S2", "06:20"]]},
    {id: "H07", route: "R1", stopTimes: [["S1", "07:10"], ["S2", "07:20"]]},
    {id: "H08", route: "R1", stopTimes: [["S1", "08:10"], ["S2", "08:20"]]},
    {id: "H09", route: "R2", stopTimes: [["S1", "09:10"], ["S2", "09:20"]]},
    {id: "NIGHT", route: "R1", stopTimes: [["S1", "23:50"], ["S2", "24:10"], ["S3", "24:20"]]}
  ]
}

// The next date holds NIGHT's connections that depart after it starts, as the previous date's run.
const tomorrowFixture = {
  serviceDate: "2026-11-09",
  serviceDayStartMs: NEXT_DAY_START_MS,
  trips: [
    {id: "NIGHT", route: "R1", serviceDayOffset: 1, firstSequence: 1, stopTimes: [["S2", "00:10"], ["S3", "00:20"]]},
    {id: "E05", route: "R1", stopTimes: [["S1", "05:30"], ["S2", "05:40"]]},
    {id: "E06", route: "R2", stopTimes: [["S1", "06:30"], ["S2", "06:40"]]}
  ]
}

const todayNames = {stopNames: ["First", "Second", "Third"], stopCodes: [null, null, null], tripHeadsigns: ["1 Early", "1 Morning", "1 Late", "Airport", "1 Night"], routes, agencyNames: {1: "Metro"}}
const tomorrowNames = {stopNames: ["First", "Second", "Third"], stopCodes: [null, null, null], tripHeadsigns: ["1 Night", "1 Dawn", "Airport"], routes, agencyNames: {1: "Metro"}}

// The snapshot of `fixture` as a manifest entry with the names file the entry names, and the files by path.
function publishedOf({fixture, names, pathPrefix}) {
  const snapshot = snapshotOf(fixture, pathPrefix)
  const namesPath = `${pathPrefix}/names.json.gz`
  const namesBuffer = gzipSync(JSON.stringify({version: 1, ...names}))
  const bytes = new Uint8Array(namesBuffer)
  const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
  snapshot.filesByPath.set(namesPath, buffer)
  const files = {...snapshot.entry.files, names: {path: namesPath, byteSize: buffer.byteLength, sha256: ""}}
  const entry = {...snapshot.entry, files, tripCount: fixture.trips.length}
  return {entry, filesByPath: snapshot.filesByPath}
}

const today = publishedOf({fixture: todayFixture, names: todayNames, pathPrefix: `${ORIGIN_FREE_PATH_PREFIX}/today`})
const tomorrow = publishedOf({fixture: tomorrowFixture, names: tomorrowNames, pathPrefix: `${ORIGIN_FREE_PATH_PREFIX}/tomorrow`})
const manifest = {formatVersion: 2, snapshots: [today.entry, tomorrow.entry]}
const filesByPath = new Map([...today.filesByPath, ...tomorrow.filesByPath])

function clockMs({dayStartMs, clockText}) {
  return dayStartMs + seconds(clockText) * SECOND_MS
}

function todayAt(clockText) {
  return clockMs({dayStartMs: DAY_START_MS, clockText})
}

function tomorrowAt(clockText) {
  return clockMs({dayStartMs: NEXT_DAY_START_MS, clockText})
}

// A fetch of the files in memory that records the paths asked for; `broken` holds the paths that fail and `resized` those that arrive with an extra byte.
function filesFetch({broken = [], resized = []} = {}) {
  const requested = []

  async function fetchFile({path}) {
    requested.push(path)

    const isBroken = broken.includes(path)
    const isAbsent = filesByPath.has(path) === false
    const isFailed = isBroken || isAbsent

    if (isFailed) {
      return {kind: FetchKind.failed, reason: FailureReason.fetchFailed}
    }

    const buffer = filesByPath.get(path)

    if (resized.includes(path)) {
      return {kind: FetchKind.fetched, buffer: buffer.slice(0, buffer.byteLength - 1)}
    }

    return {kind: FetchKind.fetched, buffer}
  }

  return {fetchFile, requested}
}

async function loaded({fromMs, stopId, kept = EVERY_ROUTE, countMax = COUNT_MAX, fetches = filesFetch()}) {
  const outcome = await loadDepartures({fetchFile: fetches.fetchFile, manifest, fromMs, stopId, kept, countMax})
  return {outcome, requested: fetches.requested}
}

function timeOf(departure) {
  return departure.timeMs
}

function tripOf(departure) {
  return departure.tripId
}

function timesOf(outcome) {
  return Array.from(outcome.departures, timeOf)
}

function tripsOf(outcome) {
  return Array.from(outcome.departures, tripOf)
}

function isChunkPath(path) {
  return path.includes("connections-")
}

function isNextDatePath(path) {
  return path.includes("/tomorrow/")
}

function hourOfPath(path) {
  return path.slice(path.lastIndexOf("-") + 1, path.lastIndexOf("."))
}

function chunkHoursOf(requested) {
  const chunkPaths = requested.filter(isChunkPath)
  return Array.from(chunkPaths, hourOfPath)
}

function serviceDateOf(entry) {
  return entry.serviceDate
}

// Which entries a time reads: the date it falls in, with no date for a time outside the days the snapshots hold.
function serviceDatesOf(fromMs) {
  const found = entriesFor({manifest, fromMs})

  if (found.kind === EntriesKind.none) {
    return found.kind
  }

  return Array.from(found.entries, serviceDateOf)
}

deepStrictEqual(SERVICE_DAY_MS_MAX, SERVICE_DAY_MS_EXPECTED, "a service day spans at most 25 hours")
deepStrictEqual(serviceDatesOf(todayAt("12:00")), ["2026-11-08", "2026-11-09"], "a time falls in the latest date started, and the next date follows it")
deepStrictEqual(serviceDatesOf(tomorrowAt("00:00")), ["2026-11-09"], "the first instant of a date falls in it")
deepStrictEqual(serviceDatesOf(tomorrowAt("12:00")), ["2026-11-09"], "the last date has no next date")
deepStrictEqual(serviceDatesOf(DAY_START_MS - SECOND_MS), "none", "a time before the first date started falls in none")
deepStrictEqual(serviceDatesOf(FAR_DAY_START_MS), "none", "a time days past the last date falls in none")
deepStrictEqual(serviceDatesOf(NEXT_DAY_START_MS + SERVICE_DAY_MS_MAX), "none", "a time past the last date's longest day falls in none")

// A time within the first date lists its departures and reads no other date, nor the chunks before the time.
const evening = await loaded({fromMs: todayAt("08:00"), stopId: "S1"})
deepStrictEqual(evening.outcome.kind, DepartureLoadKind.listed, "a stop of the date lists")
deepStrictEqual(tripsOf(evening.outcome), ["H08", "H09", "NIGHT"], "the departures from a time at a stop, the soonest first")
deepStrictEqual(timesOf(evening.outcome), [todayAt("08:10"), todayAt("09:10"), todayAt("23:50")], "each at its scheduled time")
deepStrictEqual(evening.outcome.stopName, "First", "the stop's name from the names file")
deepStrictEqual(evening.outcome.isBounded, false, "a list under the bound is not bounded")
deepStrictEqual(chunkHoursOf(evening.requested), ["8", "9", "23", "24"], "only the chunks from the time onward are fetched")
const isNextDateRead = evening.requested.some(isNextDatePath)
deepStrictEqual(isNextDateRead, false, "the next date is not read while the date lists departures")

deepStrictEqual(
  [evening.outcome.departures[0].route, evening.outcome.departures[0].color, evening.outcome.departures[0].headsign],
  ["1", "#112233", "Late"],
  "a departure names its route, its color, and its headsign without the route's number"
)

// The bound stops the read: later chunks are not fetched once the list is full.
const bounded = await loaded({fromMs: todayAt("06:00"), stopId: "S1", countMax: BOUND_SMALL})
deepStrictEqual(tripsOf(bounded.outcome), ["H06", "H07"], "the list holds the earliest departures to the bound")
deepStrictEqual(bounded.outcome.isBounded, true, "a full list is bounded")
deepStrictEqual(chunkHoursOf(bounded.requested), ["6", "7"], "no chunk past the one that fills the list is fetched")

const unbounded = await loaded({fromMs: todayAt("06:00"), stopId: "S1", countMax: BOUND_EXACT})
deepStrictEqual(tripsOf(unbounded.outcome), ["H06", "H07", "H08", "H09", "NIGHT"], "a list that fills the bound exactly holds it")
deepStrictEqual(unbounded.outcome.isBounded, true, "and is bounded")

// The routes asked for are the ones listed.
const filtered = await loaded({fromMs: todayAt("06:00"), stopId: "S1", kept: {kind: KeptKind.routes, routeIds: ["R2"]}})
deepStrictEqual(tripsOf(filtered.outcome), ["H09"], "only the routes the filter keeps are listed")

// A time past midnight is the next date's, which holds the previous date's trip; the instant is the same.
const afterMidnight = await loaded({fromMs: tomorrowAt("00:05"), stopId: "S2"})
deepStrictEqual([tripsOf(afterMidnight.outcome), timesOf(afterMidnight.outcome)], [["NIGHT"], [tomorrowAt("00:10")]], "a time past midnight lists the previous date's trip from the next date's snapshot")

const beforeMidnight = await loaded({fromMs: todayAt("23:55"), stopId: "S2"})
deepStrictEqual(timesOf(beforeMidnight.outcome), [tomorrowAt("00:10")], "a trip past midnight departs at its time past 24:00 of the date it started")

// A time past the date's last departure at the stop goes on into the next service date.
const nextDate = await loaded({fromMs: todayAt("23:55"), stopId: "S1"})
deepStrictEqual(tripsOf(nextDate.outcome), ["E05", "E06"], "past the date's last departure the next date's departures are listed")
deepStrictEqual(timesOf(nextDate.outcome), [tomorrowAt("05:30"), tomorrowAt("06:30")], "at their times on the next date")

// A time on the last date after its last departure lists none, since no date follows it.
const lastDate = await loaded({fromMs: tomorrowAt("07:00"), stopId: "S1"})
deepStrictEqual([lastDate.outcome.kind, lastDate.outcome.departures, lastDate.outcome.isBounded], [DepartureLoadKind.listed, [], false], "a time past the last date's last departure lists none")

// A date no snapshot holds is said so, with no file fetched.
const unheld = await loaded({fromMs: FAR_DAY_START_MS, stopId: "S1"})
deepStrictEqual([unheld.outcome, unheld.requested], [{kind: DepartureLoadKind.noSchedule}, []], "a date no snapshot holds lists nothing and fetches nothing")

// A stop the date does not hold fetches no chunk.
const unknown = await loaded({fromMs: todayAt("08:00"), stopId: "ELSEWHERE"})
deepStrictEqual(unknown.outcome, {kind: DepartureLoadKind.unknownStop}, "a stop no snapshot holds is unknown")
deepStrictEqual(chunkHoursOf(unknown.requested), [], "and reads no chunk")

// A names file that fails leaves the identifiers.
const namesPath = today.entry.files.names.path
const unnamed = await loaded({fromMs: todayAt("08:00"), stopId: "S1", fetches: filesFetch({broken: [namesPath]})})
deepStrictEqual([unnamed.outcome.kind, unnamed.outcome.stopName, unnamed.outcome.departures[0].route, unnamed.outcome.departures[0].headsign], [DepartureLoadKind.listed, null, "R1", null], "with no names a departure shows its route's identifier and the stop has no name")

// A table or a chunk that fails, or arrives at another size, fails the read and names its file.
const stopsPath = today.entry.files.stops.path
const chunkPath = today.entry.connectionChunks[HOUR_08_CHUNK_INDEX].path
const failureCases = [
  {name: "a stops file that does not arrive", fetches: filesFetch({broken: [stopsPath]}), expected: {kind: DepartureLoadKind.failed, reason: FailureReason.fetchFailed, path: stopsPath}},
  {name: "a chunk that does not arrive", fetches: filesFetch({broken: [chunkPath]}), expected: {kind: DepartureLoadKind.failed, reason: FailureReason.fetchFailed, path: chunkPath}},
  {name: "a chunk of another size", fetches: filesFetch({resized: [chunkPath]}), expected: {kind: DepartureLoadKind.failed, reason: FailureReason.sizeMismatch, path: chunkPath}}
]

for (const {name, fetches, expected} of failureCases) {
  const failed = await loaded({fromMs: todayAt("06:00"), stopId: "S1", fetches})
  deepStrictEqual(failed.outcome, expected, name)
}

console.log("departure files: every case passed")
