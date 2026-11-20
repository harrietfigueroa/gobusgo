// Checks how an offline page moves a scheduled vehicle between placements: a
// vehicle of the saved schedule follows the road path decoded from a saved
// trip path shard, follows the straight lines between its stops for a trip no
// shard covers, and stands where the placement puts it with no path at all.
// Each case runs the pure functions over a marker the saved schedule places
// and a path prepared as the page prepares it. The motion is the web shell's
// and stays JavaScript, so it is imported here directly; the shard's path,
// the markers, and their fallback paths come from each implementation of the
// core in turn.

import {beforeAll, describe, expect, test} from "vitest"
import {TableKind} from "../../../assets/js/core/offline_answers.js"
import {DrawnKind, PREDICTION_HORIZON_MS, preparePath} from "../../../assets/js/vehicle_prediction.js"
import {
  MarkerPositionKind,
  MotionPlanKind,
  PathTripKind,
  drawnVehicle,
  isAnimated,
  markerPositionKind,
  motionPlan,
  pathTrip,
  placedAtFetch,
  trackedVehicle
} from "../../../assets/js/vehicle_motion.js"
import {seconds} from "../../../test/scripts/routing_timetable.js"
import {savedOf} from "../../../test/scripts/saved_timetable.js"
import {fixtureBytes} from "../fixtures.mjs"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const SECOND_MS = 1000
const SHARD_ROUTE_ID = "1_7994"
const SHARD_TRIP_ID = "1_1137791"
const SHARD_SERVICE_DATE_MS = 1_794_211_200_000
// The shard's trip leaves its first stop at 27,900 s and reaches its second,
// 777 m along its path, at 28,080 s.
const SHARD_FIRST_DEPARTURE_SECONDS = 27900
const SHARD_SECOND_ARRIVAL_SECONDS = 28080
const SHARD_SECOND_STOP_METERS = 777
const PLACED_SECONDS_AFTER_DEPARTURE = 100
const POSITION_TOLERANCE_METERS = 0.01
const DEGREES_TOLERANCE = 1e-7
const DISTANCE_TOLERANCE_METERS = 0.01
const TEN_SECONDS = 10
const SIXTY_SECONDS = 60
const MARKER_COLOR = "#9ca3af"
const MARKER_COUNT_MAX = 3000
const DAY_START_MS = 1794124800000
const MICRODEGREES_PER_DEGREE = 1000000

const SOUTH_LAT_MICRODEGREES = 47600000
const NORTH_LAT_MICRODEGREES = 47610000
const WEST_LON_MICRODEGREES = -122300000
const EAST_LON_MICRODEGREES = -122290000
const S1 = [SOUTH_LAT_MICRODEGREES, WEST_LON_MICRODEGREES]
const S2 = [NORTH_LAT_MICRODEGREES, WEST_LON_MICRODEGREES]
const S3 = [NORTH_LAT_MICRODEGREES, EAST_LON_MICRODEGREES]

// A1 runs S1 to S3 and waits two minutes at S2, on straight lines.
const timetable = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  positions: {S1, S2, S3},
  trips: [{id: "A1", route: "R1", stopTimes: [["S1", "08:00"], ["S2", "08:10", "08:12"], ["S3", "08:20"]]}]
}
const saved = savedOf({fixture: timetable, names: {kind: TableKind.missing}})
const PLACED_AT_MS = DAY_START_MS + seconds("08:05") * SECOND_MS

function pointOfStop([latMicrodegrees, lonMicrodegrees]) {
  return [lonMicrodegrees / MICRODEGREES_PER_DEGREE, latMicrodegrees / MICRODEGREES_PER_DEGREE]
}

// A marker of the saved schedule, as the placement makes it, standing at
// `position` and naming `tripId` on `serviceDateMs`.
function savedMarker({tripId, serviceDateMs, position}) {
  return {
    id: `scheduled/${tripId}`,
    vehicle_id: null,
    lat: position[1],
    lon: position[0],
    color: MARKER_COLOR,
    heading: null,
    route_id: SHARD_ROUTE_ID,
    route: "1",
    headsign: null,
    schedule: null,
    next_stop: "5 min",
    status: "scheduled",
    location_age: "No location reported",
    real_time: "No",
    report: null,
    trip_id: tripId,
    service_date_ms: serviceDateMs,
    is_saved_schedule: true
  }
}

function roadMs(secondsAfterStart) {
  return SHARD_SERVICE_DATE_MS + secondsAfterStart * SECOND_MS
}

let shardBytes = null

beforeAll(async () => {
  const shardBuffer = await fixtureBytes("routing/trip-paths-v1/shard.bin")
  shardBytes = new Uint8Array(shardBuffer)
})

describe.each(IMPLEMENTATIONS)("scheduled motion ($name)", ({geodesy, polyline, scheduledService, tripPathShard}) => {
  const {KeptKind, scheduledMarkers} = scheduledService
  const {TripPathLookup, decodeTripPathShard, tripPathFromShard} = tripPathShard
  const hopSeconds = SHARD_SECOND_ARRIVAL_SECONDS - SHARD_FIRST_DEPARTURE_SECONDS
  const roadPlacedMs = roadMs(SHARD_FIRST_DEPARTURE_SECONDS + PLACED_SECONDS_AFTER_DEPARTURE)
  const laterMs = roadPlacedMs + TEN_SECONDS * SECOND_MS

  function distanceOffPath({path, position}) {
    const [lon, lat] = position
    const x = lon * path.metersPerDegreeLon
    const y = lat * geodesy.METERS_PER_DEGREE
    const nearest = polyline.nearestAlong({xs: path.xs, ys: path.ys, cumulative: path.cumulativeMeters, x, y, alongMin: 0})
    return nearest.offset
  }

  function offsetFromStop({position, stop}) {
    const stopPoint = pointOfStop(stop)
    return geodesy.distanceMeters(position, stopPoint)
  }

  // The road path of the shard fixture's trip, prepared as the page prepares a
  // path it reads from a saved shard, and the straight path of a trip no shard
  // covers.
  const states = {}

  beforeAll(() => {
    states.decodedShard = decodeTripPathShard(shardBytes)
    const shardTrip = {tripId: SHARD_TRIP_ID, routeId: SHARD_ROUTE_ID, serviceDateMs: SHARD_SERVICE_DATE_MS}
    states.decodedPath = tripPathFromShard(states.decodedShard.shard, shardTrip)
    states.roadPath = preparePath(states.decodedPath)
    states.roadMarker = savedMarker({tripId: SHARD_TRIP_ID, serviceDateMs: SHARD_SERVICE_DATE_MS, position: states.decodedPath.points[0]})
    states.roadTracked = trackedVehicle({tracked: null, marker: states.roadMarker, path: states.roadPath, atMs: roadPlacedMs})
    states.roadLater = drawnVehicle({tracked: states.roadTracked, atMs: laterMs})

    const everyRoute = {kind: KeptKind.every}
    states.placement = scheduledMarkers({snapshots: [saved], nowMs: PLACED_AT_MS, kept: everyRoute, color: MARKER_COLOR, countMax: MARKER_COUNT_MAX})
    const [straightMarker] = states.placement.markers
    states.straightMarker = straightMarker
    states.fallback = states.placement.fallbackPathOf(straightMarker.id)
    states.straightPath = preparePath(states.fallback.path)
  })

  test("the shard fixture decodes and holds the trip", () => {
    expect(states.decodedShard.kind).toBe("decoded")
    expect(states.decodedPath.kind !== TripPathLookup.missing).toBe(true)
  })

  test("a marker the saved schedule places is a scheduled plan", () => {
    expect(motionPlan(states.roadMarker).kind).toBe(MotionPlanKind.scheduled)
  })

  test("a scheduled marker the server sends stands where the fetch puts it", () => {
    const onlineScheduledMarker = {...states.roadMarker, is_saved_schedule: undefined}
    expect(motionPlan(onlineScheduledMarker).kind).toBe(MotionPlanKind.asFetched)
  })

  test("a scheduled vehicle with a road path moves along it from where the schedule puts it", () => {
    const {roadTracked} = states
    expect(isAnimated(roadTracked)).toBe(true)
    expect(roadTracked.drawn.kind).toBe(DrawnKind.alongPath)
    expect(markerPositionKind(roadTracked)).toBe(MarkerPositionKind.fetched)
    const placedMeters = SHARD_SECOND_STOP_METERS * PLACED_SECONDS_AFTER_DEPARTURE / hopSeconds
    expect(Math.abs(roadTracked.drawn.distanceMeters - placedMeters)).toBeLessThanOrEqual(DISTANCE_TOLERANCE_METERS)
  })

  test("ten seconds later it is drawn further along its road path", () => {
    const {roadLater, roadPath} = states
    const laterMeters = SHARD_SECOND_STOP_METERS * (PLACED_SECONDS_AFTER_DEPARTURE + TEN_SECONDS) / hopSeconds
    expect(Math.abs(roadLater.drawn.distanceMeters - laterMeters)).toBeLessThanOrEqual(DISTANCE_TOLERANCE_METERS)
    expect(distanceOffPath({path: roadPath, position: roadLater.drawn.position})).toBeLessThanOrEqual(POSITION_TOLERANCE_METERS)
  })

  test("a vehicle no placement refreshes stops at the prediction horizon", () => {
    const stoppedMs = roadPlacedMs + PREDICTION_HORIZON_MS + SIXTY_SECONDS * SECOND_MS
    const roadStopped = drawnVehicle({tracked: states.roadTracked, atMs: stoppedMs})
    const horizonSeconds = PLACED_SECONDS_AFTER_DEPARTURE + PREDICTION_HORIZON_MS / SECOND_MS
    const horizonMeters = SHARD_SECOND_STOP_METERS * horizonSeconds / hopSeconds
    expect(roadStopped.drawn.distanceMeters).toBeLessThanOrEqual(horizonMeters + DISTANCE_TOLERANCE_METERS)
  })

  test("a placement of the same trip continues from where it was drawn", () => {
    const {roadLater, roadMarker, roadPath} = states
    const replaced = trackedVehicle({tracked: roadLater, marker: roadMarker, path: roadPath, atMs: laterMs})
    expect(Math.abs(replaced.drawn.distanceMeters - roadLater.drawn.distanceMeters)).toBeLessThanOrEqual(DISTANCE_TOLERANCE_METERS)
    const replacedFromSource = placedAtFetch({tracked: replaced, atMs: laterMs})
    expect(isAnimated(replacedFromSource)).toBe(true)
  })

  test("a scheduled vehicle on a saved date names its trip for the shards", () => {
    const trip = {tripId: SHARD_TRIP_ID, routeId: SHARD_ROUTE_ID, serviceDateMs: SHARD_SERVICE_DATE_MS}
    expect(pathTrip(states.roadTracked)).toStrictEqual({kind: PathTripKind.trip, trip})
  })

  test("a scheduled vehicle with no saved date names no trip for the shards", () => {
    const undated = {...states.roadMarker, service_date_ms: null}
    const undatedTracked = trackedVehicle({tracked: null, marker: undated, path: null, atMs: roadPlacedMs})
    expect(pathTrip(undatedTracked)).toStrictEqual({kind: PathTripKind.none})
  })

  test("a scheduled vehicle with no path stands where the placement puts it, and stays there", () => {
    const {roadMarker} = states
    const unmoved = trackedVehicle({tracked: null, marker: roadMarker, path: null, atMs: roadPlacedMs})
    const standing = {kind: DrawnKind.atPoint, position: [roadMarker.lon, roadMarker.lat]}
    expect([isAnimated(unmoved), unmoved.drawn]).toStrictEqual([false, standing])
    expect(drawnVehicle({tracked: unmoved, atMs: laterMs})).toStrictEqual(unmoved)
  })

  test("a scheduled vehicle with the fallback path moves", () => {
    const {fallback, straightMarker, straightPath} = states
    expect(fallback.kind).toBe(TableKind.found)
    const straightTracked = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: PLACED_AT_MS})
    expect(isAnimated(straightTracked)).toBe(true)
  })

  test("a minute later it is on the due-north line between its first two stops", () => {
    const {straightMarker, straightPath} = states
    const straightTracked = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: PLACED_AT_MS})
    const minuteLater = drawnVehicle({tracked: straightTracked, atMs: PLACED_AT_MS + SIXTY_SECONDS * SECOND_MS})
    const [, minuteLat] = minuteLater.drawn.position
    const firstHopSeconds = seconds("08:10") - seconds("08:00")
    const elapsedSeconds = seconds("08:05") - seconds("08:00") + SIXTY_SECONDS
    const s1Point = pointOfStop(S1)
    const s2Point = pointOfStop(S2)
    const expectedLat = s1Point[1] + (s2Point[1] - s1Point[1]) * elapsedSeconds / firstHopSeconds
    expect(Math.abs(minuteLat - expectedLat)).toBeLessThanOrEqual(DEGREES_TOLERANCE)
    expect(minuteLater.drawn.position[0]).toBe(s1Point[0])
  })

  test("it waits at the stop for its dwell", () => {
    const {straightMarker, straightPath} = states
    const waitingMs = DAY_START_MS + seconds("08:11") * SECOND_MS
    const waitingTracked = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: waitingMs})
    const waiting = drawnVehicle({tracked: waitingTracked, atMs: waitingMs})
    expect(offsetFromStop({position: waiting.drawn.position, stop: S2})).toBeLessThanOrEqual(POSITION_TOLERANCE_METERS)
  })

  test("after its dwell it runs the line to its third stop", () => {
    const {straightMarker, straightPath} = states
    const afterDwellMs = DAY_START_MS + seconds("08:16") * SECOND_MS
    const afterDwell = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: afterDwellMs})
    const [afterLon, afterLat] = afterDwell.drawn.position
    const secondHopSeconds = seconds("08:20") - seconds("08:12")
    const secondElapsedSeconds = seconds("08:16") - seconds("08:12")
    const s2Point = pointOfStop(S2)
    const s3Point = pointOfStop(S3)
    const expectedLon = s2Point[0] + (s3Point[0] - s2Point[0]) * secondElapsedSeconds / secondHopSeconds
    const isOnLine = Math.abs(afterLon - expectedLon) <= DEGREES_TOLERANCE
    const isDueEast = Math.abs(afterLat - s2Point[1]) <= DEGREES_TOLERANCE
    expect(isOnLine).toBe(true)
    expect(isDueEast).toBe(true)
  })
})
