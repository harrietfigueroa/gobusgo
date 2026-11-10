// Checks how the vehicle page follows each vehicle between fetches: which
// vehicles are predicted, which stand at their last report, and which stand
// where the fetch puts them; where a predicted vehicle is drawn as time
// passes, when its path arrives, when a new report puts it behind or ahead
// of its drawn marker, when a fetch places it in the map's source, and when
// it moves from the source onto the canvas; and which way its chevron
// points and how it turns back to its reported heading. Each case runs the pure
// functions over markers, as the server sends them, on a straight street
// written here. Run it with `node test/scripts/vehicle_motion_check.mjs`; it
// exits non-zero on the first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {distanceMeters, metersPerDegreeLongitude} from "../../assets/js/math/geodesy.js"
import {CorrectionKind, DrawnKind, PREDICTION_HORIZON_MS, preparePath} from "../../assets/js/vehicle_prediction.js"
import {
  HEADING_TURN_DURATION_MS,
  HeadingKind,
  MotionPlanKind,
  MarkerPositionKind,
  drawnHeading,
  drawnVehicle,
  headingTurns,
  turnedHeading,
  isAnimated,
  markerPositionKind,
  motionPlan,
  pathTrip,
  placedAtFetch,
  resumedOnCanvas,
  trackedVehicle
} from "../../assets/js/vehicle_motion.js"

const LON_ORIGIN = -122.33
const LAT_ORIGIN = 47.6
const METERS_PER_DEGREE_LON = metersPerDegreeLongitude(LAT_ORIGIN)
const SERVICE_DATE_MS = 1794038400000
const MS_PER_SECOND = 1000
const TOLERANCE_METERS = 1
const TRIP_ID = "1_100"
const ROUTE_ID = "1_7"
// The schedule drives the street at 5 m/s from 10:00, with no lateness.
const SPEED_METERS_PER_SECOND = 5
const START_SECONDS = 36000
const HALF = 2
// The source's position stands this far behind the report.
const SOURCE_BEHIND_METERS = 30
const PAST_HORIZON_SECONDS = 30
// The prediction half a second into the glide of a path's arrival.
const PREDICTION_AT_HALF_GLIDE_METERS = 127.5
// Where a glide had the source draw the vehicle.
const MID_GLIDE_METERS = 160

function at({east}) {
  return [LON_ORIGIN + east / METERS_PER_DEGREE_LON, LAT_ORIGIN]
}

function msAt({seconds}) {
  return SERVICE_DATE_MS + (START_SECONDS + seconds) * MS_PER_SECOND
}

function eastOf(position) {
  return (position[0] - LON_ORIGIN) * METERS_PER_DEGREE_LON
}

function isNear({position, east, message}) {
  const offset = distanceMeters(position, at({east}))
  ok(offset <= TOLERANCE_METERS, `${message}: ${offset} m from ${east} m east`)
}

const street = preparePath({
  tripId: TRIP_ID,
  serviceDateMs: SERVICE_DATE_MS,
  points: [at({east: 0}), at({east: 1000}), at({east: 2000})],
  stops: [
    {distanceMeters: 0, arrivalSeconds: START_SECONDS, departureSeconds: START_SECONDS},
    {distanceMeters: 2000, arrivalSeconds: START_SECONDS + 400, departureSeconds: START_SECONDS + 400}
  ]
})

// A marker as the server sends it, reported `east` meters along the street
// at `seconds` past 10:00, with the source's position behind it.
function marker({east, seconds, status = "reported", hasReport = true, tripId = TRIP_ID}) {
  const [lon, lat] = at({east: east - SOURCE_BEHIND_METERS})
  let report = null

  if (hasReport) {
    const [reportLon, reportLat] = at({east})
    report = {lon: reportLon, lat: reportLat, time_ms: msAt({seconds})}
  }

  return {id: "1_bus", lat, lon, status, report, trip_id: tripId, route_id: ROUTE_ID, service_date_ms: SERVICE_DATE_MS}
}

// Which plan each kind of marker gets.
const planCases = [
  {name: "a reported vehicle on a trip is predicted", input: marker({east: 100, seconds: 20}), expected: MotionPlanKind.predicted},
  {name: "a reported vehicle with no trip stands at its report", input: marker({east: 100, seconds: 20, tripId: null}), expected: MotionPlanKind.atReport},
  {name: "a stale vehicle stands at its report", input: marker({east: 100, seconds: 20, status: "stale"}), expected: MotionPlanKind.atReport},
  {name: "a stale vehicle with no report stands where fetched", input: marker({east: 100, seconds: 20, status: "stale", hasReport: false}), expected: MotionPlanKind.asFetched},
  {name: "a schedule-only vehicle stands where fetched", input: marker({east: 100, seconds: 20, status: "scheduled", hasReport: false}), expected: MotionPlanKind.asFetched},
  {name: "a vehicle with no report time stands where fetched", input: marker({east: 100, seconds: 20, status: "unknown", hasReport: false}), expected: MotionPlanKind.asFetched}
]

for (const {name, input, expected} of planCases) {
  deepStrictEqual(motionPlan(input).kind, expected, name)
}

// A predicted vehicle moves along its path as time passes, and stops at the
// report's horizon.
const fetched = marker({east: 100, seconds: 20})
const tracked = trackedVehicle({tracked: null, marker: fetched, path: street, atMs: msAt({seconds: 20})})
isNear({position: tracked.drawn.position, east: 100, message: "a first fetch draws the vehicle at its prediction"})
const later = drawnVehicle({tracked, atMs: msAt({seconds: 30})})
isNear({position: later.drawn.position, east: 150, message: "ten seconds on, the vehicle is 50 m further"})
ok(isAnimated(later), "a vehicle along its path is animated")
// The first report is at 20 s and 100 m, on the schedule.
const REPORT_SECONDS = 20
const REPORT_METERS = 100
const horizonSeconds = REPORT_SECONDS + PREDICTION_HORIZON_MS / MS_PER_SECOND
const pastHorizon = drawnVehicle({tracked: later, atMs: msAt({seconds: horizonSeconds + PAST_HORIZON_SECONDS})})
isNear({position: pastHorizon.drawn.position, east: REPORT_METERS + SPEED_METERS_PER_SECOND * (horizonSeconds - REPORT_SECONDS), message: "past its horizon the vehicle holds"})

// A stale vehicle stands at its report, and a schedule-only one where the
// fetch puts it, whatever the time.
const stale = trackedVehicle({tracked: null, marker: marker({east: 100, seconds: 20, status: "stale"}), path: street, atMs: msAt({seconds: 20})})
isNear({position: drawnVehicle({tracked: stale, atMs: msAt({seconds: 60})}).drawn.position, east: 100, message: "a stale vehicle stays at its report"})
ok(!isAnimated(stale), "a stale vehicle is not animated")
const scheduled = trackedVehicle({tracked: null, marker: marker({east: 100, seconds: 20, status: "scheduled", hasReport: false}), path: null, atMs: msAt({seconds: 20})})
isNear({position: drawnVehicle({tracked: scheduled, atMs: msAt({seconds: 60})}).drawn.position, east: 70, message: "a schedule-only vehicle stays where fetched"})
ok(!isAnimated(scheduled), "a schedule-only vehicle is not animated")

// With no path, a predicted vehicle stands at its report until its path
// arrives, then glides onto the path.
const noPath = trackedVehicle({tracked: null, marker: fetched, path: null, atMs: msAt({seconds: 20})})
isNear({position: drawnVehicle({tracked: noPath, atMs: msAt({seconds: 25})}).drawn.position, east: 100, message: "with no path the vehicle stays at its report"})
ok(!isAnimated(noPath), "a vehicle with no path is not animated")
const drawnNoPath = drawnVehicle({tracked: noPath, atMs: msAt({seconds: 25})})
const pathArrived = trackedVehicle({tracked: drawnNoPath, marker: fetched, path: street, atMs: msAt({seconds: 25})})
deepStrictEqual(pathArrived.correction.kind, CorrectionKind.glide, "a path's arrival glides the vehicle onto it")
const glidedHalf = drawnVehicle({tracked: pathArrived, atMs: msAt({seconds: 25}) + MS_PER_SECOND / HALF})
ok(eastOf(glidedHalf.drawn.position) > 100, "halfway through the glide the vehicle has left its report")
ok(eastOf(glidedHalf.drawn.position) < PREDICTION_AT_HALF_GLIDE_METERS, "halfway through the glide the vehicle has not reached its prediction")

// A new report behind the drawn marker holds it until the prediction
// passes it.
const ahead = drawnVehicle({tracked, atMs: msAt({seconds: 40})})
isNear({position: ahead.drawn.position, east: 200, message: "the marker has driven to 200 m"})
const behindReport = marker({east: 150, seconds: 35})
const held = trackedVehicle({tracked: ahead, marker: behindReport, path: street, atMs: msAt({seconds: 40})})
deepStrictEqual(held.correction.kind, CorrectionKind.hold, "a report 25 m behind holds the marker")
isNear({position: drawnVehicle({tracked: held, atMs: msAt({seconds: 42})}).drawn.position, east: 200, message: "the held marker stays"})
isNear({position: drawnVehicle({tracked: held, atMs: msAt({seconds: 50})}).drawn.position, east: 225, message: "the held marker moves once the prediction passes it"})

// A new report ahead catches the marker up over 2 s.
const aheadReport = marker({east: 300, seconds: 40})
const caught = trackedVehicle({tracked: ahead, marker: aheadReport, path: street, atMs: msAt({seconds: 40})})
deepStrictEqual(caught.correction.kind, CorrectionKind.catchUp, "a report 100 m ahead catches the marker up")
const caughtMidway = eastOf(drawnVehicle({tracked: caught, atMs: msAt({seconds: 41})}).drawn.position)
ok(caughtMidway > 205, "a second into the catch-up the marker has gained")
ok(caughtMidway < 305, "a second into the catch-up the marker has not arrived")
isNear({position: drawnVehicle({tracked: caught, atMs: msAt({seconds: 42})}).drawn.position, east: 310, message: "after 2 s the marker is at the prediction"})

// A vehicle that keeps standing is anchored against the first report of its
// stand: after 100 s at 1,000 m it stays, where two reports 30 s apart
// alone would have it leave.
const standFirst = trackedVehicle({tracked: null, marker: marker({east: 1000, seconds: 200}), path: street, atMs: msAt({seconds: 200})})
const standSecond = trackedVehicle({tracked: standFirst, marker: marker({east: 1002, seconds: 270}), path: street, atMs: msAt({seconds: 270})})
const standThird = trackedVehicle({tracked: standSecond, marker: marker({east: 1004, seconds: 300}), path: street, atMs: msAt({seconds: 300})})
deepStrictEqual(standThird.previousReport.reportedAtMs, msAt({seconds: 200}), "a continued stand keeps its first report")
ok(!isAnimated(standThird), "a vehicle that has stood 100 s is not animated")

// The same report again changes nothing.
const same = trackedVehicle({tracked: ahead, marker: fetched, path: street, atMs: msAt({seconds: 40})})
deepStrictEqual(same.correction, ahead.correction, "the same report keeps the correction")

// A fetch placed in the map's source stands at the prediction, held or not.
const placed = placedAtFetch({tracked: held, atMs: msAt({seconds: 40})})
isNear({position: placed.drawn.position, east: 175, message: "a placed vehicle stands at its prediction"})
deepStrictEqual(placed.correction.kind, CorrectionKind.settled, "a placed vehicle has no correction")

// A vehicle moving from the source onto the canvas starts from where the
// source drew it: along its path where it stands at its placed prediction,
// and gliding from a point where a glide had it elsewhere.
const resumedAlong = resumedOnCanvas({tracked: placed, sourcePosition: placed.drawn.position, atMs: msAt({seconds: 45})})
deepStrictEqual(resumedAlong.drawn.kind, DrawnKind.alongPath, "a vehicle at its placed prediction stays along its path")
deepStrictEqual(resumedAlong.correction.kind, CorrectionKind.catchUp, "it catches up to where the time has taken it")
isNear({position: drawnVehicle({tracked: resumedAlong, atMs: msAt({seconds: 45})}).drawn.position, east: 175, message: "it starts where the source drew it"})
const resumedGliding = resumedOnCanvas({tracked: placed, sourcePosition: at({east: MID_GLIDE_METERS}), atMs: msAt({seconds: 45})})
deepStrictEqual(resumedGliding.correction.kind, CorrectionKind.glide, "a vehicle mid-glide glides on from where it was drawn")
isNear({position: drawnVehicle({tracked: resumedGliding, atMs: msAt({seconds: 45})}).drawn.position, east: 160, message: "it starts mid-glide"})

// The trip a predicted vehicle needs a path for, and none for any other.
deepStrictEqual(pathTrip(tracked), {kind: "trip", trip: {tripId: TRIP_ID, routeId: ROUTE_ID, serviceDateMs: SERVICE_DATE_MS}}, "a predicted vehicle names its trip")
deepStrictEqual(pathTrip(stale).kind, "none", "a stale vehicle names no trip")
const noRoute = trackedVehicle({tracked: null, marker: {...fetched, route_id: null}, path: null, atMs: msAt({seconds: 20})})
deepStrictEqual(pathTrip(noRoute).kind, "none", "a vehicle with no route names no trip")

// A path of another trip is a programmer error.
const otherTrip = marker({east: 100, seconds: 20, tripId: "1_other"})
function trackedOnOtherTrip() {
  return trackedVehicle({tracked: null, marker: otherTrip, path: street, atMs: msAt({seconds: 20})})
}

throws(trackedOnOtherTrip, AssertionError, "a path of another trip")

// Where each vehicle's marker stands, as its view says: an estimate along
// its path, its last report, or where the fetch puts it.
const positionCases = [
  {name: "a vehicle predicted along its path is an estimate", input: later, expected: MarkerPositionKind.estimated},
  {name: "a vehicle with no path stands at its last report", input: noPath, expected: MarkerPositionKind.lastReport},
  {name: "a stale vehicle stands at its last report", input: stale, expected: MarkerPositionKind.lastReport},
  {name: "a schedule-only vehicle stands where fetched", input: scheduled, expected: MarkerPositionKind.fetched}
]

for (const {name, input, expected} of positionCases) {
  deepStrictEqual(markerPositionKind(input), expected, name)
}

// Which way a vehicle's chevron points: along its path where it is drawn
// along it, and its reported heading otherwise. The street runs east.
const REPORTED_HEADING_DEGREES = 30
const EAST_DEGREES = 90
const HEADING_TOLERANCE_DEGREES = 0.1
const HALF_TURN_MS = HEADING_TURN_DURATION_MS / HALF
const headingCases = [
  {name: "a vehicle drawn along its path points along it", input: later, expected: {kind: HeadingKind.alongPath, degrees: EAST_DEGREES}},
  {name: "a vehicle with no path keeps its reported heading", input: noPath, expected: {kind: HeadingKind.reported}},
  {name: "a stale vehicle keeps its reported heading", input: stale, expected: {kind: HeadingKind.reported}},
  {name: "a vehicle that has stood 100 s keeps its reported heading", input: standThird, expected: {kind: HeadingKind.reported}}
]

for (const {name, input, expected} of headingCases) {
  const heading = drawnHeading(input)
  deepStrictEqual(heading.kind, expected.kind, name)
  if (expected.kind === HeadingKind.alongPath) {
    ok(Math.abs(heading.degrees - expected.degrees) < HEADING_TOLERANCE_DEGREES, `${name}: ${heading.degrees}`)
  }
}

// A chevron that leaves the path turns back to its reported heading the
// shorter way round, over the turn's duration, or at once under reduced motion.
const turnCases = [
  {name: "a turn starts at the path's bearing", input: {source: 350, target: REPORTED_HEADING_DEGREES, elapsedMs: 0}, expected: {degrees: 350, ended: false}},
  {name: "a turn across north goes the shorter way", input: {source: 350, target: REPORTED_HEADING_DEGREES, elapsedMs: HALF_TURN_MS}, expected: {degrees: 10, ended: false}},
  {name: "a turn the other way goes counterclockwise", input: {source: EAST_DEGREES, target: REPORTED_HEADING_DEGREES, elapsedMs: HALF_TURN_MS}, expected: {degrees: 60, ended: false}},
  {name: "a turn ends at the reported heading", input: {source: 350, target: REPORTED_HEADING_DEGREES, elapsedMs: HEADING_TURN_DURATION_MS}, expected: {degrees: REPORTED_HEADING_DEGREES, ended: true}}
]

for (const {name, input, expected} of turnCases) {
  const turn = turnedHeading(input)
  ok(Math.abs(turn.degrees - expected.degrees) < HEADING_TOLERANCE_DEGREES, `${name}: ${turn.degrees} is not ${expected.degrees}`)
  deepStrictEqual(turn.ended, expected.ended, name)
}

const turnKindCases = [
  {name: "a chevron off its reported heading turns back", input: {source: 350, target: REPORTED_HEADING_DEGREES, reducedMotion: false}, expected: true},
  {name: "a chevron snaps back under reduced motion", input: {source: 350, target: REPORTED_HEADING_DEGREES, reducedMotion: true}, expected: false},
  {name: "a chevron on its reported heading does not turn", input: {source: REPORTED_HEADING_DEGREES, target: REPORTED_HEADING_DEGREES, reducedMotion: false}, expected: false}
]

for (const {name, input, expected} of turnKindCases) {
  deepStrictEqual(headingTurns(input), expected, name)
}

console.log("vehicle motion check passed")
