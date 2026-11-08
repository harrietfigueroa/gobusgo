// Checks the journey loader over hand-written timetables served from memory
// through the fetch function it takes: that loading stops at the window
// after the earliest arrival and still returns the whole snapshot's frontier
// cut at that cutoff, that a start from a position walks to the stops within
// the walking radius, that no fetched path carries the position, and which
// service date a departure is routed in. Run it with
// `node test/scripts/routing_journeys_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {unreachable} from "../../assets/js/assert.js"
import {LegKind, OriginKind} from "../../assets/js/routing_engine.js"
import {
  FailureReason,
  FetchKind,
  FromKind,
  JourneysKind,
  ServiceDateKind,
  WINDOW_SECONDS,
  loadEngine,
  routeJourneys,
  serviceDateAt,
} from "../../assets/js/routing_journeys.js"
import {decodePositions} from "../../assets/js/routing_snapshot.js"
import {startsNear} from "../../assets/js/routing_walk.js"
import {TRANSFER_RULES, clock, seconds, snapshotOf} from "./routing_timetable.js"

// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const DAY_START_MS = 1794124800000
const DAY_MS = 24 * 60 * 60 * 1000
const HOUR_MS = 60 * 60 * 1000
const SECOND_MS = 1000
const LAST_DEPARTURE_HOUR = 26
const HOUR_SECONDS = 60 * 60
const HALF_HOUR_MS = 30 * 60 * 1000
const FORMAT_VERSION = 2
const MICRODEGREES_PER_DEGREE = 1000000
const WINDOW_CHUNK_COUNT = 5
const WINDOW_LOADED_CHUNK_COUNT = 3
const DAY_SERVICE_DATES = ["2026-11-08", "2026-11-09"]
const RIDER_LAT_MICRODEGREES = 47600000
const RIDER_LON_MICRODEGREES = -122300000
const TARGET_LAT_MICRODEGREES = 47700000
// The microdegrees of latitude closest to 100 m, 300 m, and 500 m.
const NORTH_100_M_MICRODEGREES = 899
const NORTH_300_M_MICRODEGREES = 2697
const NORTH_500_M_MICRODEGREES = 4497
const N1_WALK_S = 84
const N2_WALK_S = 250

// The earliest journey changes twice and arrives at 09:30, so the cutoff is
// 10:15. One change arrives at 10:10 on a trip that leaves A in the chunk of
// hour 10, which the loader has to fetch; the direct trip leaves at 11:00, in
// a chunk past the cutoff, and arrives at 11:30, past it.
const windowFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "R1", stopTimes: [["A", "08:40"], ["B", "08:55"]]},
    {id: "R2", stopTimes: [["B", "09:00"], ["D", "09:10"]]},
    {id: "R3", stopTimes: [["D", "09:15"], ["C", "09:30"]]},
    {id: "M1", stopTimes: [["A", "08:45"], ["E", "09:50"]]},
    {id: "M2", stopTimes: [["E", "10:00"], ["C", "10:10"]]},
    {id: "S", stopTimes: [["A", "11:00"], ["C", "11:30"]]},
    {id: "L", stopTimes: [["A", "13:00"], ["C", "13:10"]]},
  ],
}

// The rider stands at 47.6 N, 122.3 W. N1 is 100 m north, N2 300 m, and FAR
// 500 m, past the walking radius; U has no known position.
const positionFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "T1", stopTimes: [["N1", "08:00"], ["T", "08:20"]]},
    {id: "T2", stopTimes: [["N2", "08:05"], ["T", "08:10"]]},
    {id: "T3", stopTimes: [["FAR", "08:00"], ["T", "08:01"]]},
    {id: "T4", stopTimes: [["U", "08:00"], ["T", "08:02"]]},
  ],
  positions: {
    N1: [RIDER_LAT_MICRODEGREES + NORTH_100_M_MICRODEGREES, RIDER_LON_MICRODEGREES],
    N2: [RIDER_LAT_MICRODEGREES + NORTH_300_M_MICRODEGREES, RIDER_LON_MICRODEGREES],
    FAR: [RIDER_LAT_MICRODEGREES + NORTH_500_M_MICRODEGREES, RIDER_LON_MICRODEGREES],
    T: [TARGET_LAT_MICRODEGREES, RIDER_LON_MICRODEGREES],
  },
}

const RIDER = {lat: RIDER_LAT_MICRODEGREES / MICRODEGREES_PER_DEGREE, lon: RIDER_LON_MICRODEGREES / MICRODEGREES_PER_DEGREE}

// Today's last trip from A leaves at 22:00 and its last connection at 23:30;
// tomorrow's first trip from A leaves at 05:12. A late variant of today
// leaves A at 23:50 and arrives at C past midnight, after that connection.
const todayFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "T1", stopTimes: [["A", "22:00"], ["C", "22:20"]]},
    {id: "T9", stopTimes: [["X", "23:30"], ["Y", "23:40"]]},
  ],
}

const lateTodayFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [{id: "L", stopTimes: [["A", "23:50"], ["C", "24:30"]]}],
}

const tomorrowFixture = {
  serviceDate: "2026-11-09",
  serviceDayStartMs: DAY_START_MS + DAY_MS,
  trips: [{id: "M", stopTimes: [["A", "05:12"], ["C", "05:40"]]}],
}

function manifestOf(...snapshots) {
  return {formatVersion: FORMAT_VERSION, snapshots: Array.from(snapshots, entryOf)}
}

function entryOf(snapshot) {
  return snapshot.entry
}

// The files of `snapshots` together, as one snapshot's `filesByPath`.
function served(...snapshots) {
  const filesByPath = new Map()

  for (const snapshot of snapshots) {
    for (const [path, buffer] of snapshot.filesByPath) {
      filesByPath.set(path, buffer)
    }
  }

  return {filesByPath}
}

function isTomorrowPath(path) {
  return path.startsWith("/tomorrow/")
}

// A fetch over the snapshot's files in memory, recording each path asked for.
function memoryFetch(snapshot) {
  const requested = []

  async function fetchFile({path}) {
    requested.push(path)
    const buffer = snapshot.filesByPath.get(path)

    if (buffer === undefined) {
      return {kind: FetchKind.failed, reason: FailureReason.fetchFailed}
    }

    return {kind: FetchKind.fetched, buffer}
  }

  return {fetchFile, requested}
}

function readableLeg(leg) {
  switch (leg.kind) {
    case LegKind.ride:
      return ["ride", leg.tripId, leg.fromStopId, clock(leg.departureS), leg.toStopId, clock(leg.arrivalS)].join(" ")
    case LegKind.walk:
      return ["walk", leg.fromStopId, leg.toStopId, leg.durationS].join(" ")
    case LegKind.walkFromPosition:
      return ["walkFromPosition", leg.toStopId, leg.durationS].join(" ")
    default:
      return unreachable(leg.kind, "routing journeys check: a leg of unknown kind")
  }
}

function readable(journeys) {
  const result = []

  for (const journey of journeys) {
    result.push({arrive: clock(journey.arrivalS), changes: journey.changes, isEarliest: journey.isEarliest, legs: Array.from(journey.legs, readableLeg)})
  }

  return result
}

// The readable journeys with the service date each one runs on.
function datedReadable(journeys) {
  const result = []

  for (const [index, journey] of readable(journeys).entries()) {
    result.push({serviceDate: journeys[index].serviceDate, ...journey})
  }

  return result
}

// The engine's frontier over every chunk, cut at the earliest arrival plus
// the window, as the readable form of the loader's journeys.
function wholeFrontierByCutoff({snapshot, from, to, departureS}) {
  const engine = loadEngine({files: snapshot.files, minimumTransferS: TRANSFER_RULES.minimumTransferS})
  const origin = {kind: OriginKind.stop, stop: snapshot.stopIndex.get(from)}
  const frontier = engine.route({origin, target: snapshot.stopIndex.get(to), departureS})
  const earliestS = frontier[frontier.length - 1].arrivalS
  const result = []

  for (const journey of frontier) {
    if (journey.arrivalS <= earliestS + WINDOW_SECONDS) {
      const legs = []

      for (const leg of journey.legs) {
        const board = snapshot.connections[leg.boardConnection]
        const alight = snapshot.connections[leg.alightConnection]
        const parts = ["ride", snapshot.tripIds[board.trip], snapshot.stopIds[board.departureStop], clock(board.departureS), snapshot.stopIds[alight.arrivalStop], clock(alight.arrivalS)]
        legs.push(parts.join(" "))
      }

      result.push({arrive: clock(journey.arrivalS), changes: journey.changes, isEarliest: journey.arrivalS === earliestS, legs})
    }
  }

  return result
}

// Loading by window: the truncated set's journeys are the whole set's
// frontier cut at the cutoff, and the chunks past the cutoff are not fetched.
const windowSnapshot = snapshotOf(windowFixture)
const windowFetch = memoryFetch(windowSnapshot)
const windowQuery = {from: {kind: FromKind.stop, stopId: "A"}, toStopId: "C", departureS: seconds("08:30")}
const windowed = await routeJourneys({manifest: manifestOf(windowSnapshot), serviceDate: windowFixture.serviceDate, fetchFile: windowFetch.fetchFile, ...windowQuery})
deepStrictEqual(windowed.kind, JourneysKind.found)

deepStrictEqual(readable(windowed.journeys), [
  {arrive: "10:10", changes: 1, isEarliest: false, legs: ["ride M1 A 08:45 E 09:50", "ride M2 E 10:00 C 10:10"]},
  {arrive: "09:30", changes: 2, isEarliest: true, legs: ["ride R1 A 08:40 B 08:55", "ride R2 B 09:00 D 09:10", "ride R3 D 09:15 C 09:30"]},
])

deepStrictEqual(readable(windowed.journeys), wholeFrontierByCutoff({snapshot: windowSnapshot, from: "A", to: "C", departureS: windowQuery.departureS}))
deepStrictEqual(windowSnapshot.entry.connectionChunks.length, WINDOW_CHUNK_COUNT)
deepStrictEqual(windowed.loaded.chunkCount, WINDOW_LOADED_CHUNK_COUNT)
deepStrictEqual(windowFetch.requested.includes("/fixture/connections-11.bin"), false)

// A departure after the earliest trips starts from the chunk of its own hour.
const laterFetch = memoryFetch(windowSnapshot)
const later = await routeJourneys({manifest: manifestOf(windowSnapshot), serviceDate: windowFixture.serviceDate, fetchFile: laterFetch.fetchFile, ...windowQuery, departureS: seconds("10:30")})
deepStrictEqual(readable(later.journeys), [{arrive: "11:30", changes: 0, isEarliest: true, legs: ["ride S A 11:00 C 11:30"]}])
deepStrictEqual(laterFetch.requested.includes("/fixture/connections-8.bin"), false)

// A destination no loaded chunk reaches reads every chunk and finds none.
const noneFetch = memoryFetch(windowSnapshot)
const none = await routeJourneys({manifest: manifestOf(windowSnapshot), serviceDate: windowFixture.serviceDate, fetchFile: noneFetch.fetchFile, from: {kind: FromKind.stop, stopId: "C"}, toStopId: "A", departureS: seconds("08:00")})
deepStrictEqual(none, {kind: JourneysKind.none, loaded: {chunkCount: WINDOW_CHUNK_COUNT, byteCount: none.loaded.byteCount}})

// A start from a position walks to N1 and N2, the stops within 400 m, nearest
// first, each at 1.2 m/s rounded up to the second.
const positionSnapshot = snapshotOf(positionFixture)
const positionsResult = decodePositions(positionSnapshot.filesByPath.get("/fixture/positions.bin"))
const starts = startsNear({position: RIDER, positions: positionsResult.records, transferRules: TRANSFER_RULES})

deepStrictEqual(starts, [
  {stop: positionSnapshot.stopIndex.get("N1"), walkS: N1_WALK_S},
  {stop: positionSnapshot.stopIndex.get("N2"), walkS: N2_WALK_S},
])

// The journey from the position takes the stop whose trip arrives first, and
// no path fetched holds the position.
const positionFetch = memoryFetch(positionSnapshot)
const fromRider = {kind: FromKind.position, lat: RIDER.lat, lon: RIDER.lon}
const located = await routeJourneys({manifest: manifestOf(positionSnapshot), serviceDate: positionFixture.serviceDate, fetchFile: positionFetch.fetchFile, from: fromRider, toStopId: "T", departureS: seconds("07:50")})
deepStrictEqual(readable(located.journeys), [{arrive: "08:10", changes: 0, isEarliest: true, legs: ["walkFromPosition N2 250", "ride T2 N2 08:05 T 08:10"]}])

for (const path of positionFetch.requested) {
  deepStrictEqual(positionSnapshot.filesByPath.has(path), true)
}

// A position with no stop within the radius has nowhere to start.
const farFetch = memoryFetch(positionSnapshot)
const farAway = {kind: FromKind.position, lat: RIDER.lat - 1, lon: RIDER.lon}
const nowhere = await routeJourneys({manifest: manifestOf(positionSnapshot), serviceDate: positionFixture.serviceDate, fetchFile: farFetch.fetchFile, from: farAway, toStopId: "T", departureS: seconds("07:50")})
deepStrictEqual(nowhere, {kind: JourneysKind.noStartStop})

// An identifier the stops file does not hold, a file of another size, and a
// manifest of another format version are refused before any routing.
const unknown = await routeJourneys({manifest: manifestOf(windowSnapshot), serviceDate: windowFixture.serviceDate, fetchFile: memoryFetch(windowSnapshot).fetchFile, ...windowQuery, toStopId: "Z"})
deepStrictEqual(unknown, {kind: JourneysKind.unknownStop, stopId: "Z"})

const resized = snapshotOf(windowFixture)
resized.entry.files.trips = {...resized.entry.files.trips, byteSize: resized.entry.files.trips.byteSize + 1}
const sizeMismatch = await routeJourneys({manifest: manifestOf(resized), serviceDate: windowFixture.serviceDate, fetchFile: memoryFetch(resized).fetchFile, ...windowQuery})
deepStrictEqual(sizeMismatch, {kind: JourneysKind.failed, reason: FailureReason.sizeMismatch, path: "/fixture/trips.bin"})

const otherVersion = {...manifestOf(windowSnapshot), formatVersion: 1}
const refused = await routeJourneys({manifest: otherVersion, serviceDate: windowFixture.serviceDate, fetchFile: memoryFetch(windowSnapshot).fetchFile, ...windowQuery})
deepStrictEqual(refused, {kind: JourneysKind.failed, reason: FailureReason.unsupportedVersion, path: ""})

// A failed fetch is an outcome naming the file.
const missing = snapshotOf(windowFixture)
missing.filesByPath.delete("/fixture/connections-9.bin")
const failedFetch = await routeJourneys({manifest: manifestOf(missing), serviceDate: windowFixture.serviceDate, fetchFile: memoryFetch(missing).fetchFile, ...windowQuery})
deepStrictEqual(failedFetch, {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: "/fixture/connections-9.bin"})

// The service date of a departure is the latest one started by then: past
// midnight that is the new date, whose snapshot holds the previous date's
// trips still running.
function dayEntry(dayIndex) {
  return {
    serviceDate: DAY_SERVICE_DATES[dayIndex],
    serviceDayStartMs: DAY_START_MS + dayIndex * DAY_MS,
    connectionChunks: [{departureSMin: 0, departureSMax: LAST_DEPARTURE_HOUR * HOUR_SECONDS}],
  }
}

const days = {formatVersion: FORMAT_VERSION, snapshots: [dayEntry(1), dayEntry(0)]}
const nextStartMs = DAY_START_MS + DAY_MS
deepStrictEqual(serviceDateAt({manifest: days, departureMs: nextStartMs + HALF_HOUR_MS}), {kind: ServiceDateKind.found, serviceDate: "2026-11-09", departureS: HALF_HOUR_MS / SECOND_MS})
deepStrictEqual(serviceDateAt({manifest: days, departureMs: nextStartMs - HALF_HOUR_MS}), {kind: ServiceDateKind.found, serviceDate: "2026-11-08", departureS: (DAY_MS - HALF_HOUR_MS) / SECOND_MS})
deepStrictEqual(serviceDateAt({manifest: days, departureMs: DAY_START_MS - 1}), {kind: ServiceDateKind.none})
deepStrictEqual(serviceDateAt({manifest: days, departureMs: nextStartMs + (LAST_DEPARTURE_HOUR + 1) * HOUR_MS}), {kind: ServiceDateKind.none})

// Late at night a query continues into the next service date: a departure
// after today's last trip from A finds tomorrow's first, marked with
// tomorrow's date and timed in its service day.
const today = snapshotOf(todayFixture, "/today")
const tomorrow = snapshotOf(tomorrowFixture, "/tomorrow")
const lateQuery = {serviceDate: todayFixture.serviceDate, from: {kind: FromKind.stop, stopId: "A"}, toStopId: "C"}
const nextMorning = await routeJourneys({manifest: manifestOf(today, tomorrow), fetchFile: memoryFetch(served(today, tomorrow)).fetchFile, ...lateQuery, departureS: seconds("23:00")})
deepStrictEqual(datedReadable(nextMorning.journeys), [{serviceDate: "2026-11-09", arrive: "05:40", changes: 0, isEarliest: true, legs: ["ride M A 05:12 C 05:40"]}])

// A journey that arrives before today's last connection stays on today and
// fetches nothing of tomorrow.
const eveningFetch = memoryFetch(served(today, tomorrow))
const evening = await routeJourneys({manifest: manifestOf(today, tomorrow), fetchFile: eveningFetch.fetchFile, ...lateQuery, departureS: seconds("21:30")})
deepStrictEqual(datedReadable(evening.journeys), [{serviceDate: "2026-11-08", arrive: "22:20", changes: 0, isEarliest: true, legs: ["ride T1 A 22:00 C 22:20"]}])
const isTomorrowFetched = eveningFetch.requested.some(isTomorrowPath)
deepStrictEqual(isTomorrowFetched, false)

// With no later snapshot the late query answers from today alone.
const lastDate = await routeJourneys({manifest: manifestOf(today), fetchFile: memoryFetch(today).fetchFile, ...lateQuery, departureS: seconds("23:00")})
deepStrictEqual(lastDate.kind, JourneysKind.none)

// A journey arriving after today's last connection continues into tomorrow,
// whose chunks wait past the window of today's arrival, so today's journey
// is the answer and no chunk of tomorrow is fetched.
const lateToday = snapshotOf(lateTodayFixture, "/today")
const pastMidnightFetch = memoryFetch(served(lateToday, tomorrow))
const pastMidnight = await routeJourneys({manifest: manifestOf(lateToday, tomorrow), fetchFile: pastMidnightFetch.fetchFile, ...lateQuery, departureS: seconds("23:00")})
deepStrictEqual(datedReadable(pastMidnight.journeys), [{serviceDate: "2026-11-08", arrive: "24:30", changes: 0, isEarliest: true, legs: ["ride L A 23:50 C 24:30"]}])
deepStrictEqual(pastMidnightFetch.requested.includes("/tomorrow/stops.bin"), true)
deepStrictEqual(pastMidnightFetch.requested.includes("/tomorrow/connections-5.bin"), false)

console.log("routing journeys: every case holds")
