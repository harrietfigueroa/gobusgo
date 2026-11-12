// Checks how an offline page moves a scheduled vehicle between placements: a
// vehicle of the saved schedule follows the road path decoded from a saved
// trip path shard, follows the straight lines between its stops for a trip no
// shard covers, and stands where the placement puts it with no path at all.
// Each case runs the pure functions over a marker the saved schedule places
// and a path prepared as the page prepares it. Run it with
// `node test/scripts/scheduled_motion_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {METERS_PER_DEGREE, distanceMeters} from "../../assets/js/core/math/geodesy.js"
import {nearestAlong} from "../../assets/js/core/math/polyline.js"
import {TableKind} from "../../assets/js/core/offline_answers.js"
import {KeptKind, scheduledMarkers} from "../../assets/js/core/scheduled_service.js"
import {TripPathLookup, decodeTripPathShard, tripPathFromShard} from "../../assets/js/core/trip_path_shard.js"
import {DrawnKind, PREDICTION_HORIZON_MS, preparePath} from "../../assets/js/vehicle_prediction.js"
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
} from "../../assets/js/vehicle_motion.js"
import {seconds} from "./routing_timetable.js"
import {savedOf} from "./saved_timetable.js"

const SECOND_MS = 1000
const SHARD_ROUTE_ID = "1_7994"
const SHARD_TRIP_ID = "1_1137791"
const SHARD_SERVICE_DATE_MS = 1_794_211_200_000
// The shard's trip leaves its first stop at 27,900 s and reaches its second,
// 777 m along its path, at 28,080 s.
const SHARD_FIRST_DEPARTURE_SECONDS = 27900
const SHARD_SECOND_ARRIVAL_SECONDS = 28080
const SHARD_SECOND_STOP_METERS = 777
const POSITION_TOLERANCE_METERS = 0.01
const DEGREES_TOLERANCE = 1e-7
const DISTANCE_TOLERANCE_METERS = 0.01
const TEN_SECONDS = 10
const SIXTY_SECONDS = 60
const EVERY_ROUTE = Object.freeze({kind: KeptKind.every})
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

function distanceOffPath({path, position}) {
  const [lon, lat] = position
  const x = lon * path.metersPerDegreeLon
  const y = lat * METERS_PER_DEGREE
  const nearest = nearestAlong({xs: path.xs, ys: path.ys, cumulative: path.cumulativeMeters, x, y, alongMin: 0})
  return nearest.offset
}

// The road path of the shard fixture's trip, prepared as the page prepares a
// path it reads from a saved shard.
const shardUrl = new URL("../fixtures/routing/trip-paths-v1/shard.bin", import.meta.url)
const shardFile = readFileSync(fileURLToPath(shardUrl))
const shardBytes = new Uint8Array(shardFile)
const decodedShard = decodeTripPathShard(shardBytes)
deepStrictEqual(decodedShard.kind, "decoded", "the shard fixture decodes")
const shardTrip = {tripId: SHARD_TRIP_ID, routeId: SHARD_ROUTE_ID, serviceDateMs: SHARD_SERVICE_DATE_MS}
const decodedPath = tripPathFromShard(decodedShard.shard, shardTrip)
ok(decodedPath.kind !== TripPathLookup.missing, "the shard holds the trip")
const roadPath = preparePath(decodedPath)

const roadMarker = savedMarker({tripId: SHARD_TRIP_ID, serviceDateMs: SHARD_SERVICE_DATE_MS, position: decodedPath.points[0]})

function roadMs(secondsAfterStart) {
  return SHARD_SERVICE_DATE_MS + secondsAfterStart * SECOND_MS
}

deepStrictEqual(motionPlan(roadMarker).kind, MotionPlanKind.scheduled, "a marker the saved schedule places is a scheduled plan")

const onlineScheduledMarker = {...roadMarker, is_saved_schedule: undefined}
deepStrictEqual(motionPlan(onlineScheduledMarker).kind, MotionPlanKind.asFetched, "a scheduled marker the server sends stands where the fetch puts it")

const startSeconds = SHARD_FIRST_DEPARTURE_SECONDS + 100
const roadPlacedMs = roadMs(startSeconds)
const roadTracked = trackedVehicle({tracked: null, marker: roadMarker, path: roadPath, atMs: roadPlacedMs})
ok(isAnimated(roadTracked), "a scheduled vehicle with a road path moves")
deepStrictEqual(roadTracked.drawn.kind, DrawnKind.alongPath, "it is drawn along its path")
deepStrictEqual(markerPositionKind(roadTracked), MarkerPositionKind.fetched, "its marker stands where the schedule puts it")

const hopSeconds = SHARD_SECOND_ARRIVAL_SECONDS - SHARD_FIRST_DEPARTURE_SECONDS
const placedMeters = SHARD_SECOND_STOP_METERS * 100 / hopSeconds
ok(Math.abs(roadTracked.drawn.distanceMeters - placedMeters) <= DISTANCE_TOLERANCE_METERS, `placed ${roadTracked.drawn.distanceMeters} m along its path, expected ${placedMeters} m`)

const laterMs = roadPlacedMs + TEN_SECONDS * SECOND_MS
const roadLater = drawnVehicle({tracked: roadTracked, atMs: laterMs})
const laterMeters = SHARD_SECOND_STOP_METERS * (100 + TEN_SECONDS) / hopSeconds
ok(Math.abs(roadLater.drawn.distanceMeters - laterMeters) <= DISTANCE_TOLERANCE_METERS, `ten seconds later ${roadLater.drawn.distanceMeters} m along its path, expected ${laterMeters} m`)
ok(distanceOffPath({path: roadPath, position: roadLater.drawn.position}) <= POSITION_TOLERANCE_METERS, "it is drawn on its road path")

const stoppedMs = roadPlacedMs + PREDICTION_HORIZON_MS + SIXTY_SECONDS * SECOND_MS
const roadStopped = drawnVehicle({tracked: roadTracked, atMs: stoppedMs})
const horizonMeters = SHARD_SECOND_STOP_METERS * (100 + PREDICTION_HORIZON_MS / SECOND_MS) / hopSeconds
ok(roadStopped.drawn.distanceMeters <= horizonMeters + DISTANCE_TOLERANCE_METERS, "a vehicle no placement refreshes stops at the prediction horizon")

const replaced = trackedVehicle({tracked: roadLater, marker: roadMarker, path: roadPath, atMs: laterMs})
ok(Math.abs(replaced.drawn.distanceMeters - roadLater.drawn.distanceMeters) <= DISTANCE_TOLERANCE_METERS, "a placement of the same trip continues from where it was drawn")
const replacedFromSource = placedAtFetch({tracked: replaced, atMs: laterMs})
ok(isAnimated(replacedFromSource), "a vehicle the source draws keeps moving once the canvas takes it")

deepStrictEqual(pathTrip(roadTracked), {kind: PathTripKind.trip, trip: {tripId: SHARD_TRIP_ID, routeId: SHARD_ROUTE_ID, serviceDateMs: SHARD_SERVICE_DATE_MS}}, "a scheduled vehicle on a saved date names its trip for the shards")

const undated = {...roadMarker, service_date_ms: null}
const undatedTracked = trackedVehicle({tracked: null, marker: undated, path: null, atMs: roadPlacedMs})
deepStrictEqual(pathTrip(undatedTracked), {kind: PathTripKind.none}, "a scheduled vehicle with no saved date names no trip for the shards")

const unmoved = trackedVehicle({tracked: null, marker: roadMarker, path: null, atMs: roadPlacedMs})
deepStrictEqual([isAnimated(unmoved), unmoved.drawn], [false, {kind: DrawnKind.atPoint, position: [roadMarker.lon, roadMarker.lat]}], "a scheduled vehicle with no path stands where the placement puts it")
deepStrictEqual(drawnVehicle({tracked: unmoved, atMs: laterMs}), unmoved, "and stays there")

// A1 runs S1 to S3 and waits two minutes at S2, on straight lines.
const timetable = {
  serviceDate: "2026-11-08",
  serviceDayStartMs: DAY_START_MS,
  positions: {S1, S2, S3},
  trips: [{id: "A1", route: "R1", stopTimes: [["S1", "08:00"], ["S2", "08:10", "08:12"], ["S3", "08:20"]]}]
}
const saved = savedOf({fixture: timetable, names: {kind: TableKind.missing}})
const placedAt = DAY_START_MS + seconds("08:05") * SECOND_MS
const placement = scheduledMarkers({snapshots: [saved], nowMs: placedAt, kept: EVERY_ROUTE, color: MARKER_COLOR, countMax: MARKER_COUNT_MAX})
const [straightMarker] = placement.markers
const fallback = placement.fallbackPathOf(straightMarker.id)
deepStrictEqual(fallback.kind, TableKind.found, "the trip no shard covers has a fallback path")
const straightPath = preparePath(fallback.path)
const straightTracked = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: placedAt})
ok(isAnimated(straightTracked), "a scheduled vehicle with the fallback path moves")

function nearStop({position, stop, message}) {
  const offset = distanceMeters(position, pointOfStop(stop))
  ok(offset <= POSITION_TOLERANCE_METERS, `${message}: ${offset} m from the stop`)
}

const minuteLater = drawnVehicle({tracked: straightTracked, atMs: placedAt + SIXTY_SECONDS * SECOND_MS})
const [, minuteLat] = minuteLater.drawn.position
const firstHopSeconds = seconds("08:10") - seconds("08:00")
const elapsedSeconds = seconds("08:05") - seconds("08:00") + SIXTY_SECONDS
const expectedLat = pointOfStop(S1)[1] + (pointOfStop(S2)[1] - pointOfStop(S1)[1]) * elapsedSeconds / firstHopSeconds
ok(Math.abs(minuteLat - expectedLat) <= DEGREES_TOLERANCE, `a minute later it is on the line between its stops: ${minuteLat}, expected ${expectedLat}`)
deepStrictEqual(minuteLater.drawn.position[0], pointOfStop(S1)[0], "the line between its first two stops runs due north")

const waitingMs = DAY_START_MS + seconds("08:11") * SECOND_MS
const waitingTracked = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: waitingMs})
const waiting = drawnVehicle({tracked: waitingTracked, atMs: waitingMs})
nearStop({position: waiting.drawn.position, stop: S2, message: "it waits at the stop for its dwell"})

const afterDwellMs = DAY_START_MS + seconds("08:16") * SECOND_MS
const afterDwell = trackedVehicle({tracked: null, marker: straightMarker, path: straightPath, atMs: afterDwellMs})
const [afterLon, afterLat] = afterDwell.drawn.position
const secondHopSeconds = seconds("08:20") - seconds("08:12")
const secondElapsedSeconds = seconds("08:16") - seconds("08:12")
const expectedLon = pointOfStop(S2)[0] + (pointOfStop(S3)[0] - pointOfStop(S2)[0]) * secondElapsedSeconds / secondHopSeconds
const isOnLine = Math.abs(afterLon - expectedLon) <= DEGREES_TOLERANCE
const isDueEast = Math.abs(afterLat - pointOfStop(S2)[1]) <= DEGREES_TOLERANCE
ok(isOnLine && isDueEast, `after its dwell it runs the line to its third stop: ${afterLon}, ${afterLat}`)

console.log("scheduled motion: every case passed")
