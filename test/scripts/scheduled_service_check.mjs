// Checks the vehicle positions and stop arrivals an offline page computes
// from its saved snapshots, as pure functions of hand-written timetables
// encoded to the snapshot files and decoded by the page's own readers: a
// trip placed between two stops by the time, a trip waiting at a stop, a
// trip not yet started or ended, a trip past midnight, a trip of the
// previous service date, the routes the filter keeps, the validity of a
// date, the chunks a page reads, and the bounds on markers, chunks, and
// arrivals. Run it with `node test/scripts/scheduled_service_check.mjs`; it
// exits non-zero on the first case that differs.

import {deepStrictEqual, fail, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {TableKind} from "../../assets/js/offline_answers.js"
import {DecodeKind, decodeConnections, decodePositions, decodeTrips} from "../../assets/js/routing_snapshot.js"
import {
  ARRIVAL_COUNT_MAX,
  ARRIVAL_HORIZON_SECONDS,
  CHUNK_READ_COUNT_MAX,
  KeptKind,
  chunksAt,
  scheduledArrivals,
  scheduledMarkers
} from "../../assets/js/scheduled_service.js"
import {seconds, snapshotOf} from "./routing_timetable.js"

// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC, past
// the change of daylight saving time, so the next date starts a day later.
const DAY_START_MS = 1794124800000
const DAY_MS = 24 * 60 * 60 * 1000
const NEXT_DAY_START_MS = DAY_START_MS + DAY_MS
const SECOND_MS = 1000
const HALF_MINUTE_MS = 30 * 1000
const MINUTE_MS = 60 * 1000
const HOUR_SECONDS = 60 * 60
const MARKER_COLOR = "#9ca3af"
const MARKER_COUNT_MAX = 3000
const EVERY_ROUTE = Object.freeze({kind: KeptKind.every})

// S1 is 1.1 km south of S2, and S3 750 m east of S2.
const SOUTH_LAT_MICRODEGREES = 47600000
const NORTH_LAT_MICRODEGREES = 47610000
const WEST_LON_MICRODEGREES = -122300000
const EAST_LON_MICRODEGREES = -122290000
const S1 = [SOUTH_LAT_MICRODEGREES, WEST_LON_MICRODEGREES]
const S2 = [NORTH_LAT_MICRODEGREES, WEST_LON_MICRODEGREES]
const S3 = [NORTH_LAT_MICRODEGREES, EAST_LON_MICRODEGREES]

function found(table) {
  return {kind: TableKind.found, table}
}

function decoded(result) {
  deepStrictEqual(result.kind, DecodeKind.decoded, "a fixture file decodes")
  return result.records
}

function indexesOf(stopIds) {
  const indexes = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    indexes.set(stopId, index)
  }

  return indexes
}

function decodeChunk(buffer) {
  return decoded(decodeConnections(buffer))
}

// The saved snapshot of `fixture` as the page reads it from the bundle,
// with `names`, a names table or missing, and every chunk decoded.
function savedOf({fixture, names}) {
  const snapshot = snapshotOf(fixture)
  const {entry, filesByPath, stopIds} = snapshot
  const tripsBuffer = filesByPath.get(entry.files.trips.path)
  const positionsBuffer = filesByPath.get(entry.files.positions.path)
  const trips = decoded(decodeTrips(tripsBuffer))
  const positions = decoded(decodePositions(positionsBuffer))

  return {
    serviceDate: entry.serviceDate,
    serviceDayStartMs: entry.serviceDayStartMs,
    connectionChunks: entry.connectionChunks,
    stopIndexes: indexesOf(stopIds),
    trips: found(trips),
    positions: found(positions),
    names,
    connections: Array.from(snapshot.files.connectionChunks, decodeChunk)
  }
}

function clockMs({dayStartMs, clockText}) {
  return dayStartMs + seconds(clockText) * SECOND_MS
}

function todayAt(clockText) {
  return clockMs({dayStartMs: DAY_START_MS, clockText})
}

function tomorrowAt(clockText) {
  return clockMs({dayStartMs: NEXT_DAY_START_MS, clockText})
}

const routes = {
  R1: {shortName: "1", longName: null, color: "112233", agencyId: "1"},
  R2: {shortName: null, longName: "Second Line", color: null, agencyId: "1"}
}

// A1 runs S1 to S3 and waits two minutes at S2; B1 runs the other way;
// LATE runs past midnight; UNK ends at a stop with no known position; S4
// has no trip.
const todayFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  stops: ["S4"],
  positions: {S1, S2, S3, S4: S1},
  trips: [
    {id: "A1", route: "R1", stopTimes: [["S1", "08:00"], ["S2", "08:10", "08:12"], ["S3", "08:20"]]},
    {id: "B1", route: "R2", stopTimes: [["S3", "08:00"], ["S1", "08:20"]]},
    {id: "LATE", route: "R1", stopTimes: [["S1", "23:50"], ["S2", "24:10"], ["S3", "24:20"]]},
    {id: "UNK", route: "R2", stopTimes: [["S1", "08:00"], ["U", "08:10"]]}
  ]
}

// The stops file is in identifier order: S1, S2, S3, S4, U.
const todayNames = found({
  stopNames: ["First", "Second", "Third", "Fourth", null],
  stopCodes: [null, null, null, null, null],
  tripHeadsigns: ["1 Downtown", "Airport", "1 Late Downtown", null],
  routes,
  agencyNames: {1: "Metro"}
})

// The next date holds LATE's connections that depart after it starts, as
// the previous date's run, and a morning trip of its own.
const tomorrowFixture = {
  serviceDate: "2026-11-09",
  serviceDayStartMs: NEXT_DAY_START_MS,
  positions: {S1, S2, S3},
  trips: [
    {id: "LATE", route: "R1", serviceDayOffset: 1, firstSequence: 1, stopTimes: [["S2", "00:10"], ["S3", "00:20"]]},
    {id: "MORNING", route: "R1", stopTimes: [["S1", "06:00"], ["S2", "06:10"]]}
  ]
}

const tomorrowNames = found({
  stopNames: ["First", "Second", "Third"],
  stopCodes: [null, null, null],
  tripHeadsigns: ["1 Late Downtown", "1 Downtown"],
  routes,
  agencyNames: {1: "Metro"}
})

const today = savedOf({fixture: todayFixture, names: todayNames})
const todayUnnamed = savedOf({fixture: todayFixture, names: {kind: TableKind.missing}})
const tomorrow = savedOf({fixture: tomorrowFixture, names: tomorrowNames})

function markersAt({snapshots, nowMs, kept = EVERY_ROUTE, countMax = MARKER_COUNT_MAX}) {
  return scheduledMarkers({snapshots, nowMs, kept, color: MARKER_COLOR, countMax})
}

function markerIdOf(marker) {
  return marker.id
}

function markerIdsAt(options) {
  const {markers} = markersAt(options)
  return Array.from(markers, markerIdOf)
}

// The marker of `id` at `nowMs`, which the case expects to find.
function markerAt({snapshots, nowMs, id}) {
  const {markers} = markersAt({snapshots, nowMs})

  for (const marker of markers) {
    if (marker.id === id) {
      return marker
    }
  }

  return fail(`no marker of ${id} is placed`)
}

function placementOf(marker) {
  return {lat: marker.lat, lon: marker.lon, nextStop: marker.next_stop}
}

const A1_ID = "scheduled/2026-11-08/A1"
const B1_ID = "scheduled/2026-11-08/B1"
const LATE_ID = "scheduled/2026-11-08/LATE"

deepStrictEqual(
  markerAt({snapshots: [today], nowMs: todayAt("08:05"), id: A1_ID}),
  {
    id: A1_ID,
    vehicle_id: null,
    lat: 47.605,
    lon: -122.3,
    color: MARKER_COLOR,
    heading: null,
    route_id: "R1",
    route: "1",
    headsign: "1 Downtown",
    schedule: null,
    next_stop: "Second, 5 min away",
    status: "scheduled",
    location_age: "No location reported",
    real_time: "No"
  },
  "a trip between two stops is placed on the straight line between them by the time"
)

const placementCases = [
  [{snapshots: [today], nowMs: todayAt("08:05"), id: B1_ID}, {lat: 47.6075, lon: -122.2925, nextStop: "First, 15 min away"}, "a trip a quarter of the way along its hop is a quarter of the way between the stops"],
  [{snapshots: [today], nowMs: todayAt("08:11"), id: A1_ID}, {lat: 47.61, lon: -122.3, nextStop: "Third, 9 min away"}, "a trip waiting at a stop stands at the stop and names the stop after it"],
  [{snapshots: [today], nowMs: todayAt("08:10"), id: A1_ID}, {lat: 47.61, lon: -122.3, nextStop: "Second, under 1 min away"}, "a trip arriving at a stop stands at the stop"],
  [{snapshots: [today], nowMs: todayAt("24:00"), id: LATE_ID}, {lat: 47.605, lon: -122.3, nextStop: "Second, 10 min away"}, "a trip past midnight is placed by its times past 24:00"],
  [{snapshots: [tomorrow, today], nowMs: tomorrowAt("00:15"), id: LATE_ID}, {lat: 47.61, lon: -122.295, nextStop: "Third, 5 min away"}, "past midnight the previous date's trip is placed from the date now running"],
  [{snapshots: [tomorrow], nowMs: tomorrowAt("00:15"), id: LATE_ID}, {lat: 47.61, lon: -122.295, nextStop: "Third, 5 min away"}, "a previous date's trip is placed from the next date's snapshot alone, under its own date"]
]

for (const [options, expected, message] of placementCases) {
  const marker = markerAt(options)
  deepStrictEqual(placementOf(marker), expected, message)
}

const presenceCases = [
  [{snapshots: [today], nowMs: todayAt("07:50")}, [], "a trip not yet started has no marker"],
  [{snapshots: [today], nowMs: todayAt("08:25")}, [], "a trip that has ended has no marker"],
  [{snapshots: [tomorrow, today], nowMs: tomorrowAt("00:15")}, [LATE_ID], "a trip both dates hold is placed once"],
  [{snapshots: [today], nowMs: todayAt("24:15")}, [], "a date past its last departure places nothing"],
  [{snapshots: [today], nowMs: todayAt("08:05"), kept: {kind: KeptKind.routes, routeIds: ["R2"]}}, [B1_ID], "only the routes the filter keeps are placed"],
  [{snapshots: [today], nowMs: todayAt("08:05"), kept: {kind: KeptKind.routes, routeIds: []}}, [], "a filter that keeps no route places nothing"],
  [{snapshots: [], nowMs: todayAt("08:05")}, [], "no saved snapshot places nothing"]
]

for (const [options, expected, message] of presenceCases) {
  deepStrictEqual(markerIdsAt(options), expected, message)
}

deepStrictEqual(markersAt({snapshots: [today], nowMs: todayAt("08:05")}).unplacedCount, 1, "a trip to a stop with no known position is counted and not placed")

const bounded = markersAt({snapshots: [today], nowMs: todayAt("08:05"), countMax: 1})
deepStrictEqual([bounded.markers.length, bounded.droppedCount], [1, 1], "past the bound the markers left are counted")

const unnamed = markerAt({snapshots: [todayUnnamed], nowMs: todayAt("08:05"), id: A1_ID})
deepStrictEqual([unnamed.route, unnamed.headsign, unnamed.next_stop], ["R1", null, "5 min away"], "with no names file a marker shows its route's identifier and the time to the next stop alone")

function markersAtNoTime() {
  return markersAt({snapshots: [today], nowMs: Number.NaN})
}

function markersWithFractionalBound() {
  return markersAt({snapshots: [today], nowMs: todayAt("08:05"), countMax: 0.5})
}

throws(markersAtNoTime, AssertionError, "the time is a number")
throws(markersWithFractionalBound, AssertionError, "the bound is a whole number")

// A chunk holding every departure of the hour starting at `clockText`.
function hourChunk(clockText) {
  const departureSMin = seconds(clockText)
  return {path: `/fixture/connections-${clockText}.bin`, departureSMin, departureSMax: departureSMin + HOUR_SECONDS - 1, count: 1}
}

const hourlyEntry = {serviceDayStartMs: DAY_START_MS, connectionChunks: Array.from(["06:00", "07:00", "08:00", "09:00", "10:00"], hourChunk)}

function chunkPathOf(chunk) {
  return chunk.path
}

function chunkPathsAt({entry, nowMs}) {
  const chunks = chunksAt({entry, nowMs})
  return Array.from(chunks, chunkPathOf)
}

const chunkCases = [
  [{entry: hourlyEntry, nowMs: todayAt("08:30")}, ["/fixture/connections-07:00.bin", "/fixture/connections-08:00.bin", "/fixture/connections-09:00.bin"], "a page reads the chunks from an hour before the time to the arrivals' horizon"],
  [{entry: hourlyEntry, nowMs: todayAt("05:30")}, ["/fixture/connections-06:00.bin"], "before the date's first departure a page reads the chunks its arrivals reach"],
  [{entry: hourlyEntry, nowMs: todayAt("11:30")}, [], "past the date's last departure a page reads nothing"]
]

for (const [options, expected, message] of chunkCases) {
  deepStrictEqual(chunkPathsAt(options), expected, message)
}

function sameHourChunk(_value, index) {
  return {path: `/fixture/connections-same-${index}.bin`, departureSMin: seconds("08:00"), departureSMax: seconds("08:00"), count: 1}
}

const crowdedChunks = Array.from({length: CHUNK_READ_COUNT_MAX + 1}, sameHourChunk)
const crowdedEntry = {serviceDayStartMs: DAY_START_MS, connectionChunks: crowdedChunks}
deepStrictEqual(chunksAt({entry: crowdedEntry, nowMs: todayAt("08:00")}).length, CHUNK_READ_COUNT_MAX, "a page reads at most CHUNK_READ_COUNT_MAX chunks")

// H is passed through by every trip: M arrives at 08:05 and leaves at
// 08:09, F starts there at 08:07, N starts there with no boarding, P has
// passed, L is past the horizon at 08:00, and O comes by twice.
const arrivalsFixture = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  stops: ["EMPTY"],
  trips: [
    {id: "M", route: "R1", stopTimes: [["A", "08:00"], ["H", "08:05", "08:09"], ["Z", "08:20"]]},
    {id: "F", route: "R2", stopTimes: [["H", "08:07"], ["Z", "08:20"]]},
    {id: "N", route: "R1", noBoarding: ["H"], stopTimes: [["H", "08:03"], ["Z", "08:10"]]},
    {id: "P", route: "R1", stopTimes: [["A", "07:40"], ["H", "07:59"], ["Z", "08:10"]]},
    {id: "L", route: "R1", stopTimes: [["H", "08:40"], ["Z", "08:50"]]},
    {id: "O", route: "R1", stopTimes: [["H", "08:02"], ["A", "08:04"], ["H", "08:06"], ["Z", "08:10"]]}
  ]
}

// The stops file is A, EMPTY, H, Z; the trips are in the fixture's order.
const arrivalsNames = found({
  stopNames: ["A", "Empty", "Hub", "Z"],
  stopCodes: [null, null, null, null],
  tripHeadsigns: ["1 Downtown", "Airport", "1 Downtown", "1 Downtown", "1 Downtown", "1 Loop"],
  routes,
  agencyNames: {1: "Metro"}
})

const arrivalsSaved = savedOf({fixture: arrivalsFixture, names: arrivalsNames})

// The whole minutes from `nowMs` to `clockText` of the date of `dayStartMs`.
function minutesUntil({nowMs, clockText, dayStartMs = DAY_START_MS}) {
  const arrivalMs = clockMs({dayStartMs, clockText})
  return Math.floor((arrivalMs - nowMs) / MINUTE_MS)
}

function line({route, headsign, nowMs, clockText}) {
  return {route, headsign, minutes: minutesUntil({nowMs, clockText}), predicted: false}
}

function arrivalsAt({snapshots, stopId, nowMs}) {
  return scheduledArrivals({snapshots, stopId, nowMs})
}

const EIGHT_O_CLOCK_MS = todayAt("08:00")

deepStrictEqual(
  arrivalsAt({snapshots: [arrivalsSaved], stopId: "H", nowMs: EIGHT_O_CLOCK_MS}),
  {
    stop_id: "H",
    status: "arrivals",
    age_minutes: 0,
    scheduled: true,
    arrivals: [
      line({route: "1", headsign: "Loop", nowMs: EIGHT_O_CLOCK_MS, clockText: "08:02"}),
      line({route: "1", headsign: "Downtown", nowMs: EIGHT_O_CLOCK_MS, clockText: "08:05"}),
      line({route: "Second Line", headsign: "Airport", nowMs: EIGHT_O_CLOCK_MS, clockText: "08:07"})
    ]
  },
  "a stop's arrivals are each trip's next visit within the horizon, the soonest first, by the arrival or a first stop's departure"
)

function minutesOf(arrival) {
  return arrival.minutes
}

// The minutes of the arrivals at `clockTexts`, as the case expects them at `nowMs`.
function expectedMinutes({nowMs, clockTexts}) {
  const minutes = []

  for (const clockText of clockTexts) {
    minutes.push(minutesUntil({nowMs, clockText}))
  }

  return minutes
}

const arrivalMinuteCases = [
  [EIGHT_O_CLOCK_MS + HALF_MINUTE_MS, ["08:02", "08:05", "08:07"], "the minutes until an arrival are whole minutes, rounded down"],
  [todayAt("08:03"), ["08:05", "08:06", "08:07"], "a trip that came by once and comes again shows its next visit"],
  [todayAt("08:06"), ["08:06", "08:07", "08:40"], "a visit inside the minute is 0 minutes away, and the horizon moves with the time"]
]

for (const [nowMs, clockTexts, message] of arrivalMinuteCases) {
  const shown = arrivalsAt({snapshots: [arrivalsSaved], stopId: "H", nowMs})
  const minutes = Array.from(shown.arrivals, minutesOf)
  deepStrictEqual(minutes, expectedMinutes({nowMs, clockTexts}), message)
}

deepStrictEqual(minutesUntil({nowMs: EIGHT_O_CLOCK_MS + HALF_MINUTE_MS, clockText: "08:02"}), 1, "half a minute short of two minutes is one")

deepStrictEqual(
  arrivalsAt({snapshots: [arrivalsSaved], stopId: "EMPTY", nowMs: EIGHT_O_CLOCK_MS}),
  {stop_id: "EMPTY", status: "arrivals", age_minutes: 0, scheduled: true, arrivals: []},
  "a stop no trip serves has no arrivals"
)

deepStrictEqual(
  arrivalsAt({snapshots: [arrivalsSaved], stopId: "1_NOPE", nowMs: EIGHT_O_CLOCK_MS}),
  {stop_id: "1_NOPE", status: "refused"},
  "a stop no saved snapshot holds is refused"
)

const AFTER_MIDNIGHT_MS = tomorrowAt("00:05")
const lateArrivals = arrivalsAt({snapshots: [tomorrow, today], stopId: "S3", nowMs: AFTER_MIDNIGHT_MS}).arrivals
const lateMinutes = minutesUntil({nowMs: AFTER_MIDNIGHT_MS, clockText: "00:20", dayStartMs: NEXT_DAY_START_MS})
deepStrictEqual(lateArrivals, [{route: "1", headsign: "Late Downtown", minutes: lateMinutes, predicted: false}], "a previous date's trip arriving after midnight is shown once")

deepStrictEqual(ARRIVAL_HORIZON_SECONDS < seconds("08:40") - seconds("08:00"), true, "the fixture's later trip is past the horizon at 08:00")

// Ten trips reach H a minute apart from 08:01.
const BUSY_CLOCK_TEXTS = ["08:01", "08:02", "08:03", "08:04", "08:05", "08:06", "08:07", "08:08", "08:09", "08:10"]

function busyTrip(clockText) {
  return {id: `T${clockText}`, route: "R1", stopTimes: [["H", clockText], ["Z", "08:30"]]}
}

const busyFixture = {serviceDate: "2026-11-08", serviceDayStartMs: DAY_START_MS, trips: Array.from(BUSY_CLOCK_TEXTS, busyTrip)}
const busySaved = savedOf({fixture: busyFixture, names: {kind: TableKind.missing}})
const busy = arrivalsAt({snapshots: [busySaved], stopId: "H", nowMs: EIGHT_O_CLOCK_MS})
const busyMinutes = Array.from(busy.arrivals, minutesOf)
const soonestClockTexts = BUSY_CLOCK_TEXTS.slice(0, ARRIVAL_COUNT_MAX)
deepStrictEqual(busyMinutes, expectedMinutes({nowMs: EIGHT_O_CLOCK_MS, clockTexts: soonestClockTexts}), "at most ARRIVAL_COUNT_MAX arrivals are shown, the soonest first")
deepStrictEqual(busy.arrivals[0], line({route: "R1", headsign: null, nowMs: EIGHT_O_CLOCK_MS, clockText: "08:01"}), "with no names file an arrival shows its route's identifier and no headsign")

function arrivalsAtNoTime() {
  return arrivalsAt({snapshots: [arrivalsSaved], stopId: "H", nowMs: Number.NaN})
}

throws(arrivalsAtNoTime, AssertionError, "the arrivals' time is a number")

console.log("scheduled service: every case passed")
