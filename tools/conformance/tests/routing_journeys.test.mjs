// Checks the journey loader over hand-written timetables served from memory
// through the fetch function the driver takes: that loading stops at the window
// after the earliest arrival and still returns the whole snapshot's frontier
// cut at that cutoff, that a start from a position walks to the stops within
// the walking radius, that no fetched path carries the position, that a
// ride names the stops it passes and a journey the positions of its stops,
// and which service date a departure is routed in. The driver is the web
// shell's and runs the JavaScript core, so its cases run once; each
// implementation then answers the same queries driven in memory, and its
// answers are compared with the driver's.

import {beforeAll, describe, expect, test} from "vitest"
import {unreachable} from "../../../assets/js/core/assert.js"
import {FailureReason, FetchKind, FromKind, JourneysKind} from "../../../assets/js/core/routing_journeys.js"
import {routeJourneys, routeJourneysArrivingBy} from "../../../assets/js/routing_driver.js"
import {TRANSFER_RULES, clock, seconds, snapshotOf} from "../../../test/scripts/routing_timetable.js"
import {IMPLEMENTATIONS} from "../implementations.mjs"

// The driver's own vocabulary is the JavaScript core's.
const {LegKind} = IMPLEMENTATIONS[0].routingEngine

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
const ARRIVE_BY_CHUNK_COUNT = 4
const ARRIVE_BY_LOADED_CHUNK_COUNT = 2
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
    {id: "L", stopTimes: [["A", "13:00"], ["C", "13:10"]]}
  ]
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
    {id: "T4", stopTimes: [["U", "08:00"], ["T", "08:02"]]}
  ],
  positions: {
    N1: [RIDER_LAT_MICRODEGREES + NORTH_100_M_MICRODEGREES, RIDER_LON_MICRODEGREES],
    N2: [RIDER_LAT_MICRODEGREES + NORTH_300_M_MICRODEGREES, RIDER_LON_MICRODEGREES],
    FAR: [RIDER_LAT_MICRODEGREES + NORTH_500_M_MICRODEGREES, RIDER_LON_MICRODEGREES],
    T: [TARGET_LAT_MICRODEGREES, RIDER_LON_MICRODEGREES]
  }
}

// P runs A, B, C; Q departs X between P's departures from A and from B.
const passedFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "P", stopTimes: [["A", "08:00"], ["B", "08:10"], ["C", "08:20"]]},
    {id: "Q", stopTimes: [["X", "08:05"], ["Y", "08:15"]]}
  ]
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
    {id: "T9", stopTimes: [["X", "23:30"], ["Y", "23:40"]]}
  ]
}

const lateTodayFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [{id: "L", stopTimes: [["A", "23:50"], ["C", "24:30"]]}]
}

const tomorrowFixture = {
  serviceDate: "2026-11-09",
  serviceDayStartMs: DAY_START_MS + DAY_MS,
  trips: [{id: "M", stopTimes: [["A", "05:12"], ["C", "05:40"]]}]
}

// Arriving by 09:00 at C from A, the latest journey changes once and leaves
// at 08:10 from the chunk of hour 8, so the window reaches back to 07:25.
// The direct trip leaves at 07:50 from the chunk of hour 7, which the loader
// has to fetch; the early trip at 06:00 is in a chunk wholly before the
// window, and the late trip at 09:30 in one after the arrival.
const arriveByFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "E", stopTimes: [["A", "06:00"], ["C", "06:30"]]},
    {id: "D", stopTimes: [["A", "07:50"], ["C", "08:55"]]},
    {id: "W1", stopTimes: [["A", "08:10"], ["B", "08:25"]]},
    {id: "W2", stopTimes: [["B", "08:30"], ["C", "08:50"]]},
    {id: "LATE", stopTimes: [["A", "09:30"], ["C", "09:45"]]}
  ]
}

const windowQuery = {from: {kind: FromKind.stop, stopId: "A"}, toStopId: "C", departureS: seconds("08:30")}
const lateQuery = {serviceDate: todayFixture.serviceDate, from: {kind: FromKind.stop, stopId: "A"}, toStopId: "C"}
const arriveByQuery = {serviceDate: arriveByFixture.serviceDate, from: {kind: FromKind.stop, stopId: "A"}, toStopId: "C", arrivalS: seconds("09:00")}
const previousDayQuery = {serviceDate: tomorrowFixture.serviceDate, from: {kind: FromKind.stop, stopId: "A"}, toStopId: "C"}
const fromRider = {kind: FromKind.position, lat: RIDER.lat, lon: RIDER.lon}
const farAway = {kind: FromKind.position, lat: RIDER.lat - 1, lon: RIDER.lon}

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

function isTodayPath(path) {
  return path.startsWith("/today/")
}

function isTomorrowPathList(paths) {
  return paths.some(isTomorrowPath)
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
      return unreachable(leg.kind, "routing journeys test: a leg of unknown kind")
  }
}

function readable(journeys) {
  const result = []

  for (const journey of journeys) {
    const legs = Array.from(journey.legs, readableLeg)
    result.push({arrive: clock(journey.arrivalS), changes: journey.changes, isEarliest: journey.isEarliest, legs})
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

// The journeys of an answer arriving by a time, each with when it leaves.
function leavingReadable(journeys) {
  const result = []

  for (const [index, journey] of datedReadable(journeys).entries()) {
    const {isEarliest, ...rest} = journey
    expect(isEarliest).toBe(undefined)
    const depart = clock(journeys[index].departureS)
    result.push({depart, isLatest: journeys[index].isLatest, ...rest})
  }

  return result
}

// The snapshots and the driver's answers every case reads.
const shared = {}

beforeAll(async () => {
  shared.windowSnapshot = snapshotOf(windowFixture)
  shared.positionSnapshot = snapshotOf(positionFixture)
  shared.passedSnapshot = snapshotOf(passedFixture)
  shared.today = snapshotOf(todayFixture, "/today")
  shared.tomorrow = snapshotOf(tomorrowFixture, "/tomorrow")
  shared.lateToday = snapshotOf(lateTodayFixture, "/today")
  shared.arriveBySnapshot = snapshotOf(arriveByFixture)

  shared.windowFetch = memoryFetch(shared.windowSnapshot)
  const windowManifest = manifestOf(shared.windowSnapshot)
  const windowOptions = {manifest: windowManifest, serviceDate: windowFixture.serviceDate, fetchFile: shared.windowFetch.fetchFile, ...windowQuery}
  shared.windowed = await routeJourneys(windowOptions)

  shared.arriveByFetch = memoryFetch(shared.arriveBySnapshot)
  const arriveByManifest = manifestOf(shared.arriveBySnapshot)
  shared.arrivingBy = await routeJourneysArrivingBy({manifest: arriveByManifest, fetchFile: shared.arriveByFetch.fetchFile, ...arriveByQuery})

  shared.positionFetch = memoryFetch(shared.positionSnapshot)
  const positionManifest = manifestOf(shared.positionSnapshot)
  const positionOptions = {manifest: positionManifest, serviceDate: positionFixture.serviceDate, fetchFile: shared.positionFetch.fetchFile}
  shared.located = await routeJourneys({...positionOptions, from: fromRider, toStopId: "T", departureS: seconds("07:50")})
})

describe("routing driver", () => {
  // Loading by window: the truncated set's journeys are the whole set's
  // frontier cut at the cutoff, and the chunks past the cutoff are not fetched.
  test("loading by window stops at the cutoff", () => {
    const {windowed, windowFetch, windowSnapshot} = shared
    expect(windowed.kind).toBe(JourneysKind.found)
    expect(readable(windowed.journeys)).toStrictEqual([
      {arrive: "10:10", changes: 1, isEarliest: false, legs: ["ride M1 A 08:45 E 09:50", "ride M2 E 10:00 C 10:10"]},
      {arrive: "09:30", changes: 2, isEarliest: true, legs: ["ride R1 A 08:40 B 08:55", "ride R2 B 09:00 D 09:10", "ride R3 D 09:15 C 09:30"]}
    ])
    expect(windowSnapshot.entry.connectionChunks.length).toBe(WINDOW_CHUNK_COUNT)
    expect(windowed.loaded.chunkCount).toBe(WINDOW_LOADED_CHUNK_COUNT)
    expect(windowFetch.requested.includes("/fixture/connections-11.bin")).toBe(false)
  })

  // A departure after the earliest trips starts from the chunk of its own hour.
  test("a later departure starts from the chunk of its own hour", async () => {
    const {windowSnapshot} = shared
    const laterFetch = memoryFetch(windowSnapshot)
    const windowManifest = manifestOf(windowSnapshot)
    const later = await routeJourneys({
      manifest: windowManifest,
      serviceDate: windowFixture.serviceDate,
      fetchFile: laterFetch.fetchFile,
      ...windowQuery,
      departureS: seconds("10:30")
    })
    expect(readable(later.journeys)).toStrictEqual([{arrive: "11:30", changes: 0, isEarliest: true, legs: ["ride S A 11:00 C 11:30"]}])
    expect(laterFetch.requested.includes("/fixture/connections-8.bin")).toBe(false)
  })

  // A destination no loaded chunk reaches reads every chunk and finds none.
  test("an unreachable destination reads every chunk and finds none", async () => {
    const {windowSnapshot} = shared
    const noneFetch = memoryFetch(windowSnapshot)
    const windowManifest = manifestOf(windowSnapshot)
    const from = {kind: FromKind.stop, stopId: "C"}
    const none = await routeJourneys({manifest: windowManifest, serviceDate: windowFixture.serviceDate, fetchFile: noneFetch.fetchFile, from, toStopId: "A", departureS: seconds("08:00")})
    expect(none).toStrictEqual({kind: JourneysKind.none, loaded: {chunkCount: WINDOW_CHUNK_COUNT, byteCount: none.loaded.byteCount}})
  })

  // The journey from the position takes the stop whose trip arrives first, and
  // no path fetched holds the position.
  test("a journey from a position takes the stop whose trip arrives first", () => {
    expect(readable(shared.located.journeys)).toStrictEqual([
      {arrive: "08:10", changes: 0, isEarliest: true, legs: ["walkFromPosition N2 250", "ride T2 N2 08:05 T 08:10"]}
    ])
  })

  // A journey holds the positions of the stops it names, in degrees, and a
  // stop with no known position has none.
  test("a journey holds the positions of the stops it names", () => {
    expect(shared.located.journeys[0].stopPositions).toStrictEqual({
      N2: {lat: (RIDER_LAT_MICRODEGREES + NORTH_300_M_MICRODEGREES) / MICRODEGREES_PER_DEGREE, lon: RIDER.lon},
      T: {lat: TARGET_LAT_MICRODEGREES / MICRODEGREES_PER_DEGREE, lon: RIDER.lon}
    })
  })

  // A ride names every stop it passes, in order, while another trip's
  // connections depart between its own.
  test("a ride names every stop it passes", async () => {
    const {passedSnapshot} = shared
    const passedManifest = manifestOf(passedSnapshot)
    const passedFetch = memoryFetch(passedSnapshot)
    const from = {kind: FromKind.stop, stopId: "A"}
    const passed = await routeJourneys({manifest: passedManifest, serviceDate: passedFixture.serviceDate, fetchFile: passedFetch.fetchFile, from, toStopId: "C", departureS: seconds("07:55")})
    expect(passed.journeys[0].legs[0].stopIds).toStrictEqual(["A", "B", "C"])
    expect(passed.journeys[0].stopPositions).toStrictEqual({})
  })

  test("every path fetched for a position is a snapshot file", () => {
    const {positionFetch, positionSnapshot} = shared

    for (const path of positionFetch.requested) {
      expect(positionSnapshot.filesByPath.has(path)).toBe(true)
    }
  })

  // A position with no stop within the radius has nowhere to start.
  test("a position with no stop within the radius", async () => {
    const {positionSnapshot} = shared
    const farFetch = memoryFetch(positionSnapshot)
    const positionManifest = manifestOf(positionSnapshot)
    const nowhere = await routeJourneys({manifest: positionManifest, serviceDate: positionFixture.serviceDate, fetchFile: farFetch.fetchFile, from: farAway, toStopId: "T", departureS: seconds("07:50")})
    expect(nowhere).toStrictEqual({kind: JourneysKind.noStartStop})
  })

  // An identifier the stops file does not hold, a file of another size, and a
  // manifest of another format version are refused before any routing.
  test("an identifier the stops file does not hold", async () => {
    const {windowSnapshot} = shared
    const windowManifest = manifestOf(windowSnapshot)
    const windowFetch = memoryFetch(windowSnapshot)
    const unknown = await routeJourneys({manifest: windowManifest, serviceDate: windowFixture.serviceDate, fetchFile: windowFetch.fetchFile, ...windowQuery, toStopId: "Z"})
    expect(unknown).toStrictEqual({kind: JourneysKind.unknownStop, stopId: "Z"})
  })

  test("a file of another size", async () => {
    const resized = snapshotOf(windowFixture)
    resized.entry.files.trips = {...resized.entry.files.trips, byteSize: resized.entry.files.trips.byteSize + 1}
    const resizedManifest = manifestOf(resized)
    const resizedFetch = memoryFetch(resized)
    const sizeMismatch = await routeJourneys({manifest: resizedManifest, serviceDate: windowFixture.serviceDate, fetchFile: resizedFetch.fetchFile, ...windowQuery})
    expect(sizeMismatch).toStrictEqual({kind: JourneysKind.failed, reason: FailureReason.sizeMismatch, path: "/fixture/trips.bin"})
  })

  test("a manifest of another format version", async () => {
    const {windowSnapshot} = shared
    const windowManifest = manifestOf(windowSnapshot)
    const otherVersion = {...windowManifest, formatVersion: 1}
    const windowFetch = memoryFetch(windowSnapshot)
    const refused = await routeJourneys({manifest: otherVersion, serviceDate: windowFixture.serviceDate, fetchFile: windowFetch.fetchFile, ...windowQuery})
    expect(refused).toStrictEqual({kind: JourneysKind.failed, reason: FailureReason.unsupportedVersion, path: ""})
  })

  // A failed fetch is an outcome naming the file.
  test("a failed fetch names the file", async () => {
    const missing = snapshotOf(windowFixture)
    missing.filesByPath.delete("/fixture/connections-9.bin")
    const missingManifest = manifestOf(missing)
    const missingFetch = memoryFetch(missing)
    const failedFetch = await routeJourneys({manifest: missingManifest, serviceDate: windowFixture.serviceDate, fetchFile: missingFetch.fetchFile, ...windowQuery})
    expect(failedFetch).toStrictEqual({kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: "/fixture/connections-9.bin"})
  })

  // Late at night a query continues into the next service date: a departure
  // after today's last trip from A finds tomorrow's first, marked with
  // tomorrow's date and timed in its service day.
  test("a late query continues into the next service date", async () => {
    const {today, tomorrow} = shared
    const lateManifest = manifestOf(today, tomorrow)
    const lateFiles = served(today, tomorrow)
    const lateFetch = memoryFetch(lateFiles)
    const nextMorning = await routeJourneys({manifest: lateManifest, fetchFile: lateFetch.fetchFile, ...lateQuery, departureS: seconds("23:00")})
    expect(datedReadable(nextMorning.journeys)).toStrictEqual([
      {serviceDate: "2026-11-09", arrive: "05:40", changes: 0, isEarliest: true, legs: ["ride M A 05:12 C 05:40"]}
    ])
  })

  // A journey that arrives before today's last connection stays on today and
  // fetches nothing of tomorrow.
  test("an evening journey stays on today", async () => {
    const {today, tomorrow} = shared
    const lateManifest = manifestOf(today, tomorrow)
    const lateFiles = served(today, tomorrow)
    const eveningFetch = memoryFetch(lateFiles)
    const evening = await routeJourneys({manifest: lateManifest, fetchFile: eveningFetch.fetchFile, ...lateQuery, departureS: seconds("21:30")})
    expect(datedReadable(evening.journeys)).toStrictEqual([
      {serviceDate: "2026-11-08", arrive: "22:20", changes: 0, isEarliest: true, legs: ["ride T1 A 22:00 C 22:20"]}
    ])
    const isTomorrowFetched = eveningFetch.requested.some(isTomorrowPath)
    expect(isTomorrowFetched).toBe(false)
  })

  // With no later snapshot the late query answers from today alone.
  test("with no later snapshot the late query answers from today alone", async () => {
    const {today} = shared
    const todayManifest = manifestOf(today)
    const todayFetch = memoryFetch(today)
    const lastDate = await routeJourneys({manifest: todayManifest, fetchFile: todayFetch.fetchFile, ...lateQuery, departureS: seconds("23:00")})
    expect(lastDate.kind).toBe(JourneysKind.none)
  })

  // A journey arriving after today's last connection continues into tomorrow,
  // whose chunks wait past the window of today's arrival, so today's journey
  // is the answer and no chunk of tomorrow is fetched.
  test("a journey past midnight stays on today", async () => {
    const {lateToday, tomorrow} = shared
    const pastMidnightManifest = manifestOf(lateToday, tomorrow)
    const pastMidnightFiles = served(lateToday, tomorrow)
    const pastMidnightFetch = memoryFetch(pastMidnightFiles)
    const pastMidnight = await routeJourneys({manifest: pastMidnightManifest, fetchFile: pastMidnightFetch.fetchFile, ...lateQuery, departureS: seconds("23:00")})
    expect(datedReadable(pastMidnight.journeys)).toStrictEqual([
      {serviceDate: "2026-11-08", arrive: "24:30", changes: 0, isEarliest: true, legs: ["ride L A 23:50 C 24:30"]}
    ])
    expect(pastMidnightFetch.requested.includes("/tomorrow/stops.bin")).toBe(true)
    expect(pastMidnightFetch.requested.includes("/tomorrow/connections-5.bin")).toBe(false)
  })

  // Loading by window backward: the truncated set's journeys are the whole
  // set's frontier cut at the latest departure less the window, and neither
  // the chunk before the window nor the one after the arrival is fetched.
  test("loading by window backward", () => {
    const {arrivingBy, arriveByFetch, arriveBySnapshot} = shared
    expect(arrivingBy.kind).toBe(JourneysKind.found)
    expect(leavingReadable(arrivingBy.journeys)).toStrictEqual([
      {depart: "07:50", isLatest: false, serviceDate: "2026-11-08", arrive: "08:55", changes: 0, legs: ["ride D A 07:50 C 08:55"]},
      {depart: "08:10", isLatest: true, serviceDate: "2026-11-08", arrive: "08:50", changes: 1, legs: ["ride W1 A 08:10 B 08:25", "ride W2 B 08:30 C 08:50"]}
    ])
    expect(arriveBySnapshot.entry.connectionChunks.length).toBe(ARRIVE_BY_CHUNK_COUNT)
    expect(arrivingBy.loaded.chunkCount).toBe(ARRIVE_BY_LOADED_CHUNK_COUNT)
    expect(arriveByFetch.requested.includes("/fixture/connections-6.bin")).toBe(false)
    expect(arriveByFetch.requested.includes("/fixture/connections-9.bin")).toBe(false)
  })

  // An arrival the network cannot meet: every trip to C arrives after 06:20,
  // so the query reads every chunk departing by then and finds none.
  test("an arrival the network cannot meet", async () => {
    const {arriveBySnapshot} = shared
    const arriveByManifest = manifestOf(arriveBySnapshot)
    const tooEarlyFetch = memoryFetch(arriveBySnapshot)
    const tooEarly = await routeJourneysArrivingBy({manifest: arriveByManifest, fetchFile: tooEarlyFetch.fetchFile, ...arriveByQuery, arrivalS: seconds("06:20")})
    expect(tooEarly).toStrictEqual({kind: JourneysKind.none, loaded: {chunkCount: 1, byteCount: tooEarly.loaded.byteCount}})
    expect(tooEarlyFetch.requested.includes("/fixture/connections-7.bin")).toBe(false)
  })

  // An arrival before the date's first connection departs reads no chunk.
  test("an arrival before the date's first connection reads no chunk", async () => {
    const {arriveBySnapshot} = shared
    const arriveByManifest = manifestOf(arriveBySnapshot)
    const arriveByFetch = memoryFetch(arriveBySnapshot)
    const beforeService = await routeJourneysArrivingBy({manifest: arriveByManifest, fetchFile: arriveByFetch.fetchFile, ...arriveByQuery, arrivalS: seconds("05:00")})
    expect(beforeService).toStrictEqual({kind: JourneysKind.none, loaded: {chunkCount: 0, byteCount: beforeService.loaded.byteCount}})
  })

  // A start from a position arriving by a time walks to the stop whose trip
  // leaves latest, and leaves the position that walk before the trip.
  test("a position arriving by a time walks to the stop whose trip leaves latest", async () => {
    const {positionSnapshot} = shared
    const positionManifest = manifestOf(positionSnapshot)
    const positionFetch = memoryFetch(positionSnapshot)
    const locatedBy = await routeJourneysArrivingBy({
      manifest: positionManifest,
      serviceDate: positionFixture.serviceDate,
      fetchFile: positionFetch.fetchFile,
      from: fromRider,
      toStopId: "T",
      arrivalS: seconds("08:15")
    })
    expect(readable(locatedBy.journeys)).toStrictEqual([
      {arrive: "08:10", changes: 0, isEarliest: undefined, legs: ["walkFromPosition N2 250", "ride T2 N2 08:05 T 08:10"]}
    ])
    expect(locatedBy.journeys[0].departureS).toBe(seconds("08:05") - N2_WALK_S)
  })

  // A position with no stop within the radius has nowhere to start.
  test("a position arriving by a time with no stop within the radius", async () => {
    const {positionSnapshot} = shared
    const positionManifest = manifestOf(positionSnapshot)
    const positionFetch = memoryFetch(positionSnapshot)
    const nowhereBy = await routeJourneysArrivingBy({
      manifest: positionManifest,
      serviceDate: positionFixture.serviceDate,
      fetchFile: positionFetch.fetchFile,
      from: farAway,
      toStopId: "T",
      arrivalS: seconds("08:15")
    })
    expect(nowhereBy).toStrictEqual({kind: JourneysKind.noStartStop})
  })

  // An identifier the stops file does not hold is refused.
  test("an identifier arriving by a time the stops file does not hold", async () => {
    const {arriveBySnapshot} = shared
    const arriveByManifest = manifestOf(arriveBySnapshot)
    const arriveByFetch = memoryFetch(arriveBySnapshot)
    const unknownBy = await routeJourneysArrivingBy({manifest: arriveByManifest, fetchFile: arriveByFetch.fetchFile, ...arriveByQuery, toStopId: "Z"})
    expect(unknownBy).toStrictEqual({kind: JourneysKind.unknownStop, stopId: "Z"})
  })

  // Arriving by 00:45 on the 9th, the 9th's snapshot holds no journey, since
  // the trip past midnight departs before the 9th starts. The query goes back
  // into the 8th, the arrival moved into its seconds, and finds that trip,
  // marked with the 8th's date and timed in its service day.
  test("an arrival past midnight goes back into the previous date", async () => {
    const {lateToday, tomorrow} = shared
    const twoDayManifest = manifestOf(lateToday, tomorrow)
    const twoDayFiles = served(lateToday, tomorrow)
    const previousDayFetch = memoryFetch(twoDayFiles)
    const pastMidnightBy = await routeJourneysArrivingBy({manifest: twoDayManifest, fetchFile: previousDayFetch.fetchFile, ...previousDayQuery, arrivalS: seconds("00:45")})
    expect(leavingReadable(pastMidnightBy.journeys)).toStrictEqual([
      {depart: "23:50", isLatest: true, serviceDate: "2026-11-08", arrive: "24:30", changes: 0, legs: ["ride L A 23:50 C 24:30"]}
    ])
    expect(previousDayFetch.requested.includes("/today/connections-23.bin")).toBe(true)
  })

  // A journey of the 9th itself stays on the 9th and fetches nothing of the 8th.
  test("a journey of the 9th stays on the 9th", async () => {
    const {lateToday, tomorrow} = shared
    const twoDayManifest = manifestOf(lateToday, tomorrow)
    const twoDayFiles = served(lateToday, tomorrow)
    const morningFetch = memoryFetch(twoDayFiles)
    const morningBy = await routeJourneysArrivingBy({manifest: twoDayManifest, fetchFile: morningFetch.fetchFile, ...previousDayQuery, arrivalS: seconds("06:00")})
    expect(leavingReadable(morningBy.journeys)).toStrictEqual([
      {depart: "05:12", isLatest: true, serviceDate: "2026-11-09", arrive: "05:40", changes: 0, legs: ["ride M A 05:12 C 05:40"]}
    ])
    const isTodayFetched = morningFetch.requested.some(isTodayPath)
    expect(isTodayFetched).toBe(false)
  })

  // With no earlier snapshot, the 9th's answer stands alone.
  test("with no earlier snapshot the 9th's answer stands alone", async () => {
    const {tomorrow} = shared
    const tomorrowManifest = manifestOf(tomorrow)
    const tomorrowFetch = memoryFetch(tomorrow)
    const firstDateBy = await routeJourneysArrivingBy({manifest: tomorrowManifest, fetchFile: tomorrowFetch.fetchFile, ...previousDayQuery, arrivalS: seconds("00:45")})
    expect(firstDateBy.kind).toBe(JourneysKind.none)
  })
})

describe.each(IMPLEMENTATIONS)("routing journeys ($name)", ({routingEngine, routingJourneys, routingSnapshot, routingWalk}) => {
  const {OriginKind} = routingEngine
  const {ROUND_COUNT_MAX, ServiceDateKind, StepKind, TimeKind, WINDOW_SECONDS, loadEngine, resumeQuery, serviceDateAt, startQuery} = routingJourneys

  function readableEngineLegs({snapshot, journey}) {
    const legs = []

    for (const leg of journey.legs) {
      const board = snapshot.connections[leg.boardConnection]
      const alight = snapshot.connections[leg.alightConnection]
      const parts = ["ride", snapshot.tripIds[board.trip], snapshot.stopIds[board.departureStop], clock(board.departureS), snapshot.stopIds[alight.arrivalStop], clock(alight.arrivalS)]
      legs.push(parts.join(" "))
    }

    return legs
  }

  // The engine's frontier over every chunk, cut at the earliest arrival plus
  // the window, as the readable form of the loader's journeys.
  function wholeFrontierByCutoff({snapshot, from, to, departureS}) {
    const engine = loadEngine({files: snapshot.files, minimumTransferS: TRANSFER_RULES.minimumTransferS})
    const origin = {kind: OriginKind.stop, stop: snapshot.stopIndex.get(from)}
    const target = snapshot.stopIndex.get(to)
    const frontier = engine.route({origin, target, departureS})
    const earliestS = frontier[frontier.length - 1].arrivalS
    const result = []

    for (const journey of frontier) {
      if (journey.arrivalS <= earliestS + WINDOW_SECONDS) {
        const legs = readableEngineLegs({snapshot, journey})
        result.push({arrive: clock(journey.arrivalS), changes: journey.changes, isEarliest: journey.arrivalS === earliestS, legs})
      }
    }

    return result
  }

  // The engine's frontier over every chunk arriving by `arrivalS`, cut at the
  // latest departure less the window, in the readable form of the loader's.
  function wholeArrivingByCutoff({snapshot, from, to, arrivalS}) {
    const engine = loadEngine({files: snapshot.files, minimumTransferS: TRANSFER_RULES.minimumTransferS})
    const origin = {kind: OriginKind.stop, stop: snapshot.stopIndex.get(from)}
    const target = snapshot.stopIndex.get(to)
    const frontier = engine.routeArrivingBy({origin, target, arrivalS})
    const latestS = frontier[frontier.length - 1].departureS
    const result = []

    for (const journey of frontier) {
      if (journey.departureS >= latestS - WINDOW_SECONDS) {
        const legs = readableEngineLegs({snapshot, journey})
        const depart = clock(journey.departureS)
        const arrive = clock(journey.arrivalS)
        result.push({depart, isLatest: journey.departureS === latestS, serviceDate: snapshot.entry.serviceDate, arrive, changes: journey.changes, legs})
      }
    }

    return result
  }

  function pathOf(file) {
    return file.path
  }

  // The core alone, with no fetch of its own: a query asks for files and is
  // resumed with every file the caller holds.
  function driveInMemory({manifest, request, snapshot}) {
    const held = new Map()
    const rounds = []
    let {state, step} = startQuery({manifest, request})

    for (let round = 0; round < ROUND_COUNT_MAX; round++) {
      if (step.kind === StepKind.done) {
        return {answer: step.answer, rounds}
      }

      const paths = Array.from(step.files, pathOf)
      rounds.push(paths)
      const fetched = []

      for (const file of step.files) {
        const buffer = snapshot.filesByPath.get(file.path)
        held.set(file.path, buffer)
        fetched.push({kind: FetchKind.fetched, buffer})
      }

      const resumed = resumeQuery({manifest, state, fetched, files: held})
      state = resumed.state
      step = resumed.step
    }

    return unreachable(step.kind, "routing journeys test: a query asked for files past the round bound")
  }

  function windowRequest() {
    return {kind: TimeKind.leaving, serviceDate: windowFixture.serviceDate, seconds: windowQuery.departureS, from: windowQuery.from, toStopId: windowQuery.toStopId}
  }

  test("the windowed journeys are the whole frontier cut at the cutoff", () => {
    const {windowed, windowSnapshot} = shared
    const whole = wholeFrontierByCutoff({snapshot: windowSnapshot, from: "A", to: "C", departureS: windowQuery.departureS})
    expect(readable(windowed.journeys)).toStrictEqual(whole)
  })

  test("the journeys arriving by a time are the whole frontier cut at the latest departure", () => {
    const {arrivingBy, arriveBySnapshot} = shared
    const whole = wholeArrivingByCutoff({snapshot: arriveBySnapshot, from: "A", to: "C", arrivalS: arriveByQuery.arrivalS})
    expect(leavingReadable(arrivingBy.journeys)).toStrictEqual(whole)
  })

  // A start from a position walks to N1 and N2, the stops within 400 m, nearest
  // first, each at 1.2 m/s rounded up to the second.
  test("a start from a position walks to the stops within the radius", () => {
    const {positionSnapshot} = shared
    const positionsFile = positionSnapshot.filesByPath.get("/fixture/positions.bin")
    const positionsResult = routingSnapshot.decodePositions(positionsFile)
    const starts = routingWalk.startsNear({position: RIDER, positions: positionsResult.records, transferRules: TRANSFER_RULES})
    expect(starts).toStrictEqual([
      {stop: positionSnapshot.stopIndex.get("N1"), walkS: N1_WALK_S},
      {stop: positionSnapshot.stopIndex.get("N2"), walkS: N2_WALK_S}
    ])
  })

  // The service date of a departure is the latest one started by then: past
  // midnight that is the new date, whose snapshot holds the previous date's
  // trips still running.
  function dayEntry(dayIndex) {
    return {
      serviceDate: DAY_SERVICE_DATES[dayIndex],
      serviceDayStartMs: DAY_START_MS + dayIndex * DAY_MS,
      connectionChunks: [{departureSMin: 0, departureSMax: LAST_DEPARTURE_HOUR * HOUR_SECONDS}]
    }
  }

  const days = {formatVersion: FORMAT_VERSION, snapshots: [dayEntry(1), dayEntry(0)]}
  const nextStartMs = DAY_START_MS + DAY_MS

  const serviceDateCases = [
    {name: "past midnight", departureMs: nextStartMs + HALF_HOUR_MS, serviceDate: "2026-11-09", departureS: HALF_HOUR_MS / SECOND_MS},
    {name: "before midnight", departureMs: nextStartMs - HALF_HOUR_MS, serviceDate: "2026-11-08", departureS: (DAY_MS - HALF_HOUR_MS) / SECOND_MS}
  ]

  test.each(serviceDateCases)("the service date $name", ({departureMs, serviceDate, departureS}) => {
    expect(serviceDateAt({manifest: days, departureMs})).toStrictEqual({kind: ServiceDateKind.found, serviceDate, departureS})
  })

  test("no service date before the first", () => {
    expect(serviceDateAt({manifest: days, departureMs: DAY_START_MS - 1})).toStrictEqual({kind: ServiceDateKind.none})
  })

  test("no service date past the last departure", () => {
    const departureMs = nextStartMs + (LAST_DEPARTURE_HOUR + 1) * HOUR_MS
    expect(serviceDateAt({manifest: days, departureMs})).toStrictEqual({kind: ServiceDateKind.none})
  })

  // Driven synchronously over the files in memory, a query asks for the four
  // tables at once, then one chunk a round, and ends with the answer the
  // driver gives over the same files.
  test("a query driven in memory asks for the tables, then a chunk a round", () => {
    const {windowed, windowSnapshot} = shared
    const windowManifest = manifestOf(windowSnapshot)
    const windowDriven = driveInMemory({manifest: windowManifest, request: windowRequest(), snapshot: windowSnapshot})
    expect(windowDriven.answer).toStrictEqual(windowed)
    expect(windowDriven.rounds[0]).toStrictEqual(["/fixture/stops.bin", "/fixture/trips.bin", "/fixture/transfers.bin", "/fixture/positions.bin"])
    expect(windowDriven.rounds.length).toBe(1 + WINDOW_LOADED_CHUNK_COUNT)

    for (const paths of windowDriven.rounds.slice(1)) {
      expect(paths.length).toBe(1)
    }
  })

  test("a query arriving by a time driven in memory gives the driver's answer", () => {
    const {arrivingBy, arriveBySnapshot} = shared
    const arriveByRequest = {kind: TimeKind.arrivingBy, serviceDate: arriveByQuery.serviceDate, seconds: arriveByQuery.arrivalS, from: arriveByQuery.from, toStopId: arriveByQuery.toStopId}
    const arriveByManifest = manifestOf(arriveBySnapshot)
    const arriveByDriven = driveInMemory({manifest: arriveByManifest, request: arriveByRequest, snapshot: arriveBySnapshot})
    expect(arriveByDriven.answer).toStrictEqual(arrivingBy)
  })

  // Into the next date, the core asks for the second date's tables after the
  // first date's chunks.
  test("into the next date the core asks for the second date's tables", async () => {
    const {today, tomorrow} = shared
    const lateRequest = {kind: TimeKind.leaving, serviceDate: lateQuery.serviceDate, seconds: seconds("23:00"), from: lateQuery.from, toStopId: lateQuery.toStopId}
    const lateServed = served(today, tomorrow)
    const lateManifest = manifestOf(today, tomorrow)
    const lateDriven = driveInMemory({manifest: lateManifest, request: lateRequest, snapshot: lateServed})
    const lateFetch = memoryFetch(lateServed)
    const lateDriver = await routeJourneys({manifest: lateManifest, fetchFile: lateFetch.fetchFile, ...lateQuery, departureS: seconds("23:00")})
    expect(lateDriven.answer).toStrictEqual(lateDriver)
    const isTomorrowAsked = lateDriven.rounds.some(isTomorrowPathList)
    expect(isTomorrowAsked).toBe(true)
  })

  function failedOutcome() {
    return {kind: FetchKind.failed, reason: FailureReason.timedOut}
  }

  function shortOutcome() {
    return {kind: FetchKind.fetched, buffer: new ArrayBuffer(1)}
  }

  // A failed fetch and a file of another size are outcomes naming the file,
  // decided by the core from the outcome the caller hands it.
  test("a failed fetch handed to the core names the file", () => {
    const windowManifest = manifestOf(shared.windowSnapshot)
    const startedWindow = startQuery({manifest: windowManifest, request: windowRequest()})
    const failedOutcomes = Array.from(startedWindow.step.files, failedOutcome)
    const failedStep = resumeQuery({manifest: windowManifest, state: startedWindow.state, fetched: failedOutcomes, files: new Map()}).step
    const answer = {kind: JourneysKind.failed, reason: FailureReason.timedOut, path: "/fixture/stops.bin"}
    expect(failedStep).toStrictEqual({kind: StepKind.done, answer})
  })

  test("a file of another size handed to the core names the file", () => {
    const windowManifest = manifestOf(shared.windowSnapshot)
    const startedWindow = startQuery({manifest: windowManifest, request: windowRequest()})
    const shortOutcomes = Array.from(startedWindow.step.files, shortOutcome)
    const shortStep = resumeQuery({manifest: windowManifest, state: startedWindow.state, fetched: shortOutcomes, files: new Map()}).step
    const answer = {kind: JourneysKind.failed, reason: FailureReason.sizeMismatch, path: "/fixture/stops.bin"}
    expect(shortStep).toStrictEqual({kind: StepKind.done, answer})
  })
})
