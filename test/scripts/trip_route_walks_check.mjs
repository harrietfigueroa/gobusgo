// Checks how `routeTo` plans the walks at the ends of a trip over a snapshot
// served from memory and the golden walk graph's tiles held by a stand-in for
// the page's tile store: a walk from the rider's position and a walk to a
// destination point, planned along the streets where the snapshot's rules
// say so and as a straight line where they say so or the graph cannot be
// had, and the journeys that carry the note that their walk fell back. The
// time of a walk from a position is the length of the line `planWalk` draws.
// Run it with `node test/scripts/trip_route_walks_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, ok, strictEqual} from "node:assert/strict"
import {distanceMeters} from "../../assets/js/core/math/geodesy.js"
import {FromKind, JourneysKind} from "../../assets/js/core/routing_journeys.js"
import {decodePositions, decodeStops} from "../../assets/js/core/routing_snapshot.js"
import {PointJourneysKind} from "../../assets/js/core/point_journeys.js"
import {EndKind, PlannedKind} from "../../assets/js/core/trip_plan.js"
import {WALK_LIMITS, WalkPathKind, planWalk} from "../../assets/js/core/walk_path.js"
import {routeTo} from "../../assets/js/trip_route.js"
import {WindowFailure, WindowKind} from "../../assets/js/walk_tiles.js"
import {TRANSFER_RULES, seconds, snapshotOf} from "./routing_timetable.js"
import {goldenGraph} from "./walk_links_queries.mjs"

const MICRODEGREES = 1_000_000
const SERVICE_DATE = "2026-11-08"
const DAY_START_MS = 1794124800000
const WALK_SPEED_M_PER_S = 1.2
const FORMAT_VERSION = 2
const WEST_TILE_KEY = "4761_-8156"

const {indexTable, shardsByKey, points} = goldenGraph()
const index = indexTable.tileKeys

function pointNamed(name) {
  return points.find((candidate) => candidate.name === name)
}

function micro(degrees) {
  return Math.round(degrees * MICRODEGREES)
}

// The rider stands on the northern street. Stop A is on the southern street
// across a block with a missing link, so it is a street walk longer than its
// straight line, and stop B is on the island, which no street joins to the
// rider's: straight, B is nearer; by the streets, B is not reached.
const rider = pointNamed("north middle")
const southMiddle = pointNamed("south middle")
const island = pointNamed("island middle")
const FAR_LAT_DEGREES = 0.05
const FAR_LAT = rider.lat + FAR_LAT_DEGREES
const fixture = {
  serviceDate: SERVICE_DATE,
  serviceDayStartMs: DAY_START_MS,
  trips: [
    {id: "TA", stopTimes: [["A", "08:10"], ["T", "08:30"]]},
    {id: "TB", stopTimes: [["B", "08:05"], ["T", "08:15"]]}
  ],
  positions: {
    A: [micro(southMiddle.lat), micro(southMiddle.lon)],
    B: [micro(island.lat), micro(island.lon)],
    T: [micro(FAR_LAT), micro(rider.lon)]
  }
}

const snapshot = snapshotOf(fixture)
const stopIds = decodeStops(snapshot.files.stops).records
const positions = decodePositions(snapshot.filesByPath.get(snapshot.entry.files.positions.path)).records

// A stand-in for the page's file origin: the snapshot's files by path.
globalThis.fetch = async function fetchFromMemory(url) {
  const buffer = snapshot.filesByPath.get(url)
  ok(buffer !== undefined, "a file nobody holds was fetched: " + url)
  return {ok: true, headers: new Headers(), arrayBuffer: async () => buffer}
}

const searchFiles = {snapshotStops: async () => [stopIds, positions]}
const readyWindow = {kind: WindowKind.ready, index, loaded: shardsByKey}
const failedWindow = {kind: WindowKind.failed, reason: WindowFailure.timeout}
const OFFLINE_FAILURE_REASON = WindowFailure.source
const SECONDS_PER_MINUTE = 60

function walkTilesOf(window) {
  const asked = []

  async function fetchWindow({position, deadlineMs}) {
    asked.push({position, deadlineMs})
    return window
  }

  return {fetchWindow, asked}
}

function manifestWith(rules) {
  return {formatVersion: FORMAT_VERSION, snapshots: [{...snapshot.entry, transferRules: rules}]}
}

const streetRules = {...TRANSFER_RULES, walkBasis: "streets", walkStreetMetersMax: 600}
const leaving = {kind: PlannedKind.leaving, serviceDate: SERVICE_DATE, seconds: seconds("07:50")}
const fromRider = {kind: FromKind.position, lat: rider.lat, lon: rider.lon}
const toStop = {kind: EndKind.stop, stopId: "T", name: "T"}

async function routeWith({rules, window, from = fromRider, to = toStop}) {
  const walkTiles = walkTilesOf(window)
  const answer = await routeTo({origin: "", searchFiles, walkTiles, manifest: manifestWith(rules), planned: leaving, from, to})
  return {answer, walkTiles}
}

const drawn = planWalk({from: rider, to: southMiddle, index, loaded: shardsByKey, limits: WALK_LIMITS})
strictEqual(drawn.kind, WalkPathKind.found)
const streetWalkS = Math.ceil(drawn.meters / WALK_SPEED_M_PER_S)
ok(drawn.meters > pointDistance(rider, southMiddle), "the street walk to A is longer than its straight line")

function pointDistance(first, second) {
  return distanceMeters([first.lon, first.lat], [second.lon, second.lat])
}

// Along the streets, the island's stop is not reached: the journey takes A,
// walking the time of the line drawn to it, and says nothing of a fallback.
{
  const {answer, walkTiles} = await routeWith({rules: streetRules, window: readyWindow})
  strictEqual(answer.kind, JourneysKind.found)
  const [first] = answer.journeys[0].legs
  deepStrictEqual([first.kind, first.toStopId, first.durationS], ["walkFromPosition", "A", streetWalkS])
  strictEqual(answer.journeys[0].hasStraightLineWalk, false)
  strictEqual(walkTiles.asked.length, 1, "the tiles around the position are asked for once")
  deepStrictEqual(walkTiles.asked[0].position, {lat: rider.lat, lon: rider.lon})
}

// A mixed table plans the rider's walk on the streets too.
{
  const {answer} = await routeWith({rules: {...streetRules, walkBasis: "mixed"}, window: readyWindow})
  strictEqual(answer.journeys[0].legs[0].toStopId, "A")
  strictEqual(answer.journeys[0].legs[0].durationS, streetWalkS)
}

// Where the snapshot's rules are the straight line, the nearer island stop is
// the start, no tile is asked for, and no journey carries a note.
{
  const {answer, walkTiles} = await routeWith({rules: {...TRANSFER_RULES, walkBasis: "straight"}, window: readyWindow})
  strictEqual(answer.journeys[0].legs[0].toStopId, "B")
  strictEqual(answer.journeys[0].hasStraightLineWalk, false)
  strictEqual(walkTiles.asked.length, 0)
}

// A table that names no basis is read as the straight line.
{
  const {answer, walkTiles} = await routeWith({rules: TRANSFER_RULES, window: readyWindow})
  strictEqual(answer.journeys[0].legs[0].toStopId, "B")
  strictEqual(walkTiles.asked.length, 0)
}

// The graph not had, by a tile that failed, a deadline, or no network: the
// walk is the straight line of the snapshot's radius, so the journeys that
// exist without the streets still exist, and each says its walk is straight.
for (const reason of [WindowFailure.tiles, WindowFailure.timeout, OFFLINE_FAILURE_REASON]) {
  const {answer} = await routeWith({rules: streetRules, window: {kind: WindowKind.failed, reason}})
  strictEqual(answer.kind, JourneysKind.found, reason)
  strictEqual(answer.journeys[0].legs[0].toStopId, "B", reason)
  strictEqual(answer.journeys[0].hasStraightLineWalk, true, reason)
}

// A position off the graph falls back the same way: the rider far from any street.
{
  const offGraph = pointNamed("off the graph")
  const {answer} = await routeWith({rules: streetRules, window: readyWindow, from: {kind: FromKind.position, lat: offGraph.lat, lon: offGraph.lon}})
  strictEqual(answer.kind, JourneysKind.found)
  strictEqual(answer.journeys[0].hasStraightLineWalk, true)
}

// A destination point: the stops reached along the streets from it, each
// walked at its street meters, and the journeys' last walk is the line drawn.
{
  const to = {kind: EndKind.point, name: "Somewhere", lat: rider.lat, lon: rider.lon}
  const from = {kind: FromKind.stop, stopId: "T"}
  const toFixture = {
    serviceDate: SERVICE_DATE,
    serviceDayStartMs: DAY_START_MS,
    trips: [
      {id: "TA", stopTimes: [["T", "08:10"], ["A", "08:30"]]},
      {id: "TB", stopTimes: [["T", "08:10"], ["B", "08:20"]]}
    ],
    positions: fixture.positions
  }

  const pointSnapshot = snapshotOf(toFixture)
  const pointStops = decodeStops(pointSnapshot.files.stops).records
  const pointPositions = decodePositions(pointSnapshot.filesByPath.get(pointSnapshot.entry.files.positions.path)).records
  const pointFiles = {snapshotStops: async () => [pointStops, pointPositions]}

  globalThis.fetch = async function fetchPointFiles(url) {
    return {ok: true, headers: new Headers(), arrayBuffer: async () => pointSnapshot.filesByPath.get(url)}
  }

  async function routePoint({rules, window}) {
    const manifest = {formatVersion: FORMAT_VERSION, snapshots: [{...pointSnapshot.entry, transferRules: rules}]}
    return await routeTo({origin: "", searchFiles: pointFiles, walkTiles: walkTilesOf(window), manifest, planned: leaving, from, to})
  }

  function lastWalk(answer) {
    const [journey] = answer.journeys
    return journey.legs[journey.legs.length - 1]
  }

  const onStreets = await routePoint({rules: streetRules, window: readyWindow})
  strictEqual(onStreets.kind, PointJourneysKind.found)
  strictEqual(lastWalk(onStreets).fromStopId, "A")
  strictEqual(lastWalk(onStreets).durationS, streetWalkS)
  strictEqual(onStreets.journeys[0].hasStraightLineWalk, false)

  const fellBack = await routePoint({rules: streetRules, window: failedWindow})
  strictEqual(lastWalk(fellBack).fromStopId, "B")
  strictEqual(fellBack.journeys[0].hasStraightLineWalk, true)
  ok(lastWalk(fellBack).durationS < SECONDS_PER_MINUTE * SECONDS_PER_MINUTE, "the straight walk is an estimate under an hour")
}

// A snapshot of `trips` over the base fixture's stops, served from memory.
function serveTrips(trips, extraPositions) {
  const served = snapshotOf({...fixture, trips, positions: {...fixture.positions, ...extraPositions}})
  const servedStops = decodeStops(served.files.stops).records
  const servedPositions = decodePositions(served.filesByPath.get(served.entry.files.positions.path)).records

  globalThis.fetch = async function fetchServed(url) {
    return {ok: true, headers: new Headers(), arrayBuffer: async () => served.filesByPath.get(url)}
  }

  return {served, files: {snapshotStops: async () => [servedStops, servedPositions]}}
}

async function routeServed({served, files, rules, walkTiles, from = fromRider, to = toStop}) {
  const manifest = {formatVersion: FORMAT_VERSION, snapshots: [{...served.entry, transferRules: rules}]}
  return await routeTo({origin: "", searchFiles: files, walkTiles, manifest, planned: leaving, from, to})
}

function tilesPerPosition(windowOf) {
  async function fetchWindow({position}) {
    return windowOf(position)
  }

  return {fetchWindow}
}

// The street rules leave out the only stop with a trip to the destination:
// the island's B. Along the streets only A is reached, and A's trip goes
// nowhere, so the query is routed again from the straight-line starts and the
// journey that exists on the straight line is found, with the note.
{
  const {served, files} = serveTrips(
    [{id: "TA", stopTimes: [["A", "08:10"], ["X", "08:20"]]}, {id: "TB", stopTimes: [["B", "08:05"], ["T", "08:15"]]}],
    {X: [micro(FAR_LAT), micro(rider.lon + FAR_LAT_DEGREES)]}
  )

  const answer = await routeServed({served, files, rules: streetRules, walkTiles: walkTilesOf(readyWindow)})
  strictEqual(answer.kind, JourneysKind.found)
  strictEqual(answer.journeys[0].legs[0].toStopId, "B")
  strictEqual(answer.journeys[0].hasStraightLineWalk, true)
}

// The reasons a walk falls back, each leaving the journey of the straight
// line with the note: no stop in reach within the street bound, a window past
// the piece bound, and the snapshot's stops not read.
{
  const {served, files} = serveTrips(fixture.trips, {})
  const tinyBound = {...streetRules, walkStreetMetersMax: 5}
  const noneInReach = await routeServed({served, files, rules: tinyBound, walkTiles: walkTilesOf(readyWindow)})
  strictEqual(noneInReach.journeys[0].legs[0].toStopId, "B", "none in reach")
  strictEqual(noneInReach.journeys[0].hasStraightLineWalk, true, "none in reach")

  const heavy = new Map(shardsByKey)
  heavy.set(WEST_TILE_KEY, {pieceCount: 250_001, classes: new Uint8Array(0), pieceStarts: new Uint32Array(1), points: new Int32Array(0)})
  const capReached = await routeServed({served, files, rules: streetRules, walkTiles: walkTilesOf({...readyWindow, loaded: heavy})})
  strictEqual(capReached.journeys[0].legs[0].toStopId, "B", "cap reached")
  strictEqual(capReached.journeys[0].hasStraightLineWalk, true, "cap reached")

  const unread = {snapshotStops: async () => { throw new Error("the stops file is unreadable") }}
  const stopsNotRead = await routeServed({served, files: unread, rules: streetRules, walkTiles: walkTilesOf(readyWindow)})
  strictEqual(stopsNotRead.journeys[0].legs[0].toStopId, "B", "stops not read")
  strictEqual(stopsNotRead.journeys[0].hasStraightLineWalk, true, "stops not read")
}

// Both ends at positions: the walk from the rider's position and the walk to
// the destination point, each marked by its own end's fallback.
{
  // C stands on the rider's street and Z on the street the destination is
  // beside, in the golden graph's east tile, more than a walk from the rider.
  const near = pointNamed("north west")
  const eastEnd = pointNamed("east shard end")
  const beside = pointNamed("east shard off street")
  const {served, files} = serveTrips(
    [{id: "TC", stopTimes: [["C", "08:05"], ["Z", "08:15"]]}],
    {C: [micro(near.lat), micro(near.lon)], Z: [micro(eastEnd.lat), micro(eastEnd.lon)]}
  )

  const to = {kind: EndKind.point, name: "Near Z", lat: beside.lat, lon: beside.lon}

  function legFlags(answer) {
    const [first] = answer.journeys
    return Array.from(first.legs, (leg) => leg.isStraightLine === true)
  }

  const clean = await routeServed({served, files, rules: streetRules, walkTiles: walkTilesOf(readyWindow), to})
  deepStrictEqual(legFlags(clean), [false, false, false], "both ends on the streets")

  function failsAtDestination(position) {
    if (position.lat === beside.lat) {
      return failedWindow
    }

    return readyWindow
  }

  const endOnly = await routeServed({served, files, rules: streetRules, walkTiles: tilesPerPosition(failsAtDestination), to})
  deepStrictEqual(legFlags(endOnly), [false, false, true], "only the destination fell back")

  function failsAtStart(position) {
    if (position.lat === rider.lat) {
      return failedWindow
    }

    return readyWindow
  }

  const startOnly = await routeServed({served, files, rules: streetRules, walkTiles: tilesPerPosition(failsAtStart), to})
  deepStrictEqual(legFlags(startOnly), [true, false, false], "only the start fell back")

  const bothFail = await routeServed({served, files, rules: streetRules, walkTiles: walkTilesOf(failedWindow), to})
  deepStrictEqual(legFlags(bothFail), [true, false, true], "both ends fell back")
}

console.log("trip route walks: every case passed")
