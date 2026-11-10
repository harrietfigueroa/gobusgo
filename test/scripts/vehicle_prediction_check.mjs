// Checks where the vehicle prediction this script imports draws a vehicle
// between fetches. Cases written out by hand cover a moving bus, a dwell, a
// bus standing and leaving its stand, a layover before a trip's first
// departure, a trip's end, a layover, a loop route, a stale report, a missing path, a report off
// its path, a path of straight lines, each correction, and invalid inputs. A
// replay of real King County Metro fetches stored on 2026-11-08 then
// measures the error at the time of each later report and fails when its
// median or its 90th percentile moves more than 10 m from what was measured
// on the same cut, and replays the corrections a marker makes as each
// report arrives. Run it with
// `node test/scripts/vehicle_prediction_check.mjs`, or name the whole
// store's cut as its argument; it exits non-zero on the first case that
// differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {gunzipSync} from "node:zlib"
import {AssertionError} from "../../assets/js/assert.js"
import {METERS_PER_DEGREE, distanceMeters, metersPerDegreeLongitude} from "../../assets/js/math/geodesy.js"
import {
  CorrectionKind,
  DrawnKind,
  PREDICTION_HORIZON_MS,
  PredictionKind,
  anchorReport,
  beginCorrection,
  drawCorrected,
  predictPosition,
  preparePath,
  reportBefore
} from "../../assets/js/vehicle_prediction.js"

const LON_ORIGIN = -122.33
const LAT_ORIGIN = 47.6
const METERS_PER_DEGREE_LON = metersPerDegreeLongitude(LAT_ORIGIN)
const SERVICE_DATE_MS = 1794038400000
const MS_PER_SECOND = 1000
const TOLERANCE_METERS = 1
const DEVIATION_TOLERANCE_SECONDS = 0.1
const HORIZON_MS = 2 * 60 * 1000
const TRIP_ID = "1_100"
const OTHER_TRIP_ID = "1_99"

// A [lon, lat] position `east` and `north` meters from the origin.
function at({east, north = 0}) {
  return [LON_ORIGIN + east / METERS_PER_DEGREE_LON, LAT_ORIGIN + north / METERS_PER_DEGREE]
}

function msAt(seconds) {
  return SERVICE_DATE_MS + seconds * MS_PER_SECOND
}

function report({east, north = 0, seconds, tripId = TRIP_ID}) {
  return {position: at({east, north}), reportedAtMs: msAt(seconds), tripId, serviceDateMs: SERVICE_DATE_MS}
}

function near({actual, expected, message}) {
  ok(Math.abs(actual - expected) <= TOLERANCE_METERS, `${message}: ${actual} is not ${expected}`)
}

function isAt({position, expected, message}) {
  const offset = distanceMeters(position, at(expected))
  ok(offset <= TOLERANCE_METERS, `${message}: ${offset} m from where it belongs`)
}

function pathOfStops({points, stops}) {
  const positions = Array.from(points, at)
  return preparePath({tripId: TRIP_ID, serviceDateMs: SERVICE_DATE_MS, points: positions, stops})
}

// A trip east along a straight street: three stops 1,000 m apart, reached at
// 5 m/s with no dwell, so the schedule puts the bus at `5 * seconds` meters.
const streetPath = pathOfStops({
  points: [{east: 0}, {east: 500}, {east: 1000}, {east: 1500}, {east: 2000}],
  stops: [
    {distanceMeters: 0, arrivalSeconds: 0, departureSeconds: 0},
    {distanceMeters: 1000, arrivalSeconds: 200, departureSeconds: 200},
    {distanceMeters: 2000, arrivalSeconds: 400, departureSeconds: 400}
  ]
})

// A loop route that ends 5 m from where it starts.
const loopPath = pathOfStops({
  points: [{east: 0}, {east: 1000}, {east: 1000, north: 500}, {east: 0, north: 500}, {east: 0, north: 5}],
  stops: [
    {distanceMeters: 0, arrivalSeconds: 0, departureSeconds: 0},
    {distanceMeters: 1500, arrivalSeconds: 300, departureSeconds: 300},
    {distanceMeters: 2995, arrivalSeconds: 600, departureSeconds: 600}
  ]
})

// A path the builder drew as straight lines between stops, turning north at
// the middle stop.
const straightPath = pathOfStops({
  points: [{east: 0}, {east: 1000}, {east: 1000, north: 1000}],
  stops: [
    {distanceMeters: 0, arrivalSeconds: 0, departureSeconds: 0},
    {distanceMeters: 1000, arrivalSeconds: 200, departureSeconds: 200},
    {distanceMeters: 2000, arrivalSeconds: 400, departureSeconds: 400}
  ]
})

// A trip whose first stop departs 300 s after its service date, where a bus
// that has finished its previous trip lays over.
const layoverStartPath = pathOfStops({
  points: [{east: 0}, {east: 2000}],
  stops: [
    {distanceMeters: 0, arrivalSeconds: 300, departureSeconds: 300},
    {distanceMeters: 1000, arrivalSeconds: 500, departureSeconds: 500},
    {distanceMeters: 2000, arrivalSeconds: 700, departureSeconds: 700}
  ]
})

// A schedule that waits at the 1,000 m stop for ten minutes, so a
// prediction from before that stop stops there.
const dwellPath = pathOfStops({
  points: [{east: 0}, {east: 2000}],
  stops: [
    {distanceMeters: 0, arrivalSeconds: 0, departureSeconds: 0},
    {distanceMeters: 1000, arrivalSeconds: 200, departureSeconds: 800},
    {distanceMeters: 2000, arrivalSeconds: 1000, departureSeconds: 1000}
  ]
})

deepStrictEqual(PREDICTION_HORIZON_MS, HORIZON_MS, "the horizon is the stale age of a report")

// A bus at 500 m, 30 s behind its schedule.
const MOVING = {path: streetPath, last: {east: 500, seconds: 130}, previous: {east: 350, seconds: 100}}
const movingAnchor = anchorOf(MOVING)
deepStrictEqual(movingAnchor.kind, PredictionKind.alongPath, "a moving bus is anchored on its path")
const MOVING_DEVIATION_SECONDS = 30
const deviationOffset = Math.abs(movingAnchor.deviationSeconds - MOVING_DEVIATION_SECONDS)
ok(deviationOffset < DEVIATION_TOLERANCE_SECONDS, "the anchor's deviation is the report's lateness")

function anchorOf({path, last, previous}) {
  const lastReport = report(last)
  let previousReport = null
  if (previous !== undefined) {
    previousReport = report(previous)
  }
  return anchorReport({path, lastReport, previousReport})
}

function predictionOf(entry) {
  const anchor = anchorOf(entry)
  const atMs = msAt(entry.atSeconds)
  return predictPosition({path: entry.path, anchor, atMs})
}

const anchorCases = [
  {name: "the anchor is the report's distance along the path", ...MOVING, meters: 500},
  {
    name: "a loop route's last report is anchored on its second pass",
    path: loopPath,
    last: {east: 5, north: 2, seconds: 600},
    previous: {east: 0, north: 200, seconds: 570},
    meters: 2995
  },
  {
    name: "a report with no report before it on its trip is anchored on the first pass",
    path: loopPath,
    last: {east: 5, north: 2, seconds: 10},
    previous: {east: 100, north: 300, seconds: 0, tripId: OTHER_TRIP_ID},
    meters: 5
  },
  {name: "a report 40 m from its path is anchored on it", ...MOVING, last: {east: 500, north: 40, seconds: 130}, meters: 500}
]

for (const {name, meters, ...entry} of anchorCases) {
  const anchor = anchorOf(entry)
  deepStrictEqual(anchor.kind, PredictionKind.alongPath, name)
  near({actual: anchor.distanceMeters, expected: meters, message: name})
}

const alongCases = [
  {name: "a moving bus advances at the schedule's pace", ...MOVING, atSeconds: 190, meters: 800},
  {name: "a time before the report holds at the anchor", ...MOVING, atSeconds: 120, meters: 500},
  {name: "a report two minutes old reaches the horizon", ...MOVING, atSeconds: 250, meters: 1100},
  {name: "a stale report holds at the horizon", ...MOVING, atSeconds: 600, meters: 1100},
  {
    name: "a bus 40 s ahead of its schedule keeps that lead",
    path: streetPath,
    last: {east: 500, seconds: 60},
    previous: {east: 400, seconds: 30},
    atSeconds: 70,
    meters: 550
  },
  {
    name: "a trip's end clamps the prediction at the last stop",
    path: streetPath,
    last: {east: 1900, seconds: 390},
    previous: {east: 1800, seconds: 370},
    atSeconds: 480,
    meters: 2000
  },
  {
    // Its next trip not yet reported, a bus laying over waits at the last
    // stop of the trip it reported, where the next trip starts.
    name: "a layover waits at the end of the reported trip",
    path: streetPath,
    last: {east: 1990, seconds: 405},
    previous: {east: 1900, seconds: 385},
    atSeconds: 500,
    meters: 2000
  },
  {
    // The stand began at 210 s, so the bus leaves its stop at 240 s.
    name: "a bus that has stood under 90 s holds until 30 s after its stand began",
    path: streetPath,
    last: {east: 1004, seconds: 230},
    previous: {east: 1000, seconds: 210},
    atSeconds: 235,
    meters: 1004
  },
  {
    name: "a bus that has stood under 90 s then advances at the schedule's pace",
    path: streetPath,
    last: {east: 1004, seconds: 230},
    previous: {east: 1000, seconds: 210},
    atSeconds: 250,
    meters: 1050
  },
  {
    name: "a bus that last reported after 30 s of its stand leaves at once",
    path: streetPath,
    last: {east: 1004, seconds: 260},
    previous: {east: 1000, seconds: 210},
    atSeconds: 270,
    meters: 1050
  },
  {
    name: "a bus laying over at its trip's first stop holds until the scheduled departure",
    path: layoverStartPath,
    last: {east: 3, seconds: 200},
    previous: {east: 0, seconds: 50},
    atSeconds: 290,
    meters: 3
  },
  {
    name: "a bus laying over at its trip's first stop leaves at the scheduled departure",
    path: layoverStartPath,
    last: {east: 3, seconds: 200},
    previous: {east: 0, seconds: 50},
    atSeconds: 320,
    meters: 100
  }
]

for (const {name, meters, ...entry} of alongCases) {
  const prediction = predictionOf(entry)
  deepStrictEqual(prediction.kind, PredictionKind.alongPath, name)
  near({actual: prediction.distanceMeters, expected: meters, message: name})
}

const positionCases = [
  {name: "the prediction's position is its distance along the path", ...MOVING, atSeconds: 190, expected: {east: 800}},
  {
    name: "a straight-line path turns at its stop",
    path: straightPath,
    last: {east: 900, seconds: 180},
    previous: {east: 800, seconds: 160},
    atSeconds: 240,
    expected: {east: 1000, north: 200}
  }
]

for (const {name, expected, ...entry} of positionCases) {
  const prediction = predictionOf(entry)
  isAt({position: prediction.position, expected, message: name})
}

const reportCases = [
  {
    name: "a bus that has stood 90 s or more is drawn at its last report",
    path: streetPath,
    last: {east: 1004, seconds: 230},
    previous: {east: 1000, seconds: 140},
    atSeconds: 290,
    kind: PredictionKind.still
  },
  {
    name: "a bus that has stood past its trip's scheduled first departure is drawn at its last report",
    path: layoverStartPath,
    last: {east: 3, seconds: 400},
    previous: {east: 0, seconds: 250},
    atSeconds: 450,
    kind: PredictionKind.still
  },
  {
    name: "a standing bus with no path is drawn at its last report",
    path: null,
    last: {east: 1004, seconds: 230},
    previous: {east: 1000, seconds: 210},
    atSeconds: 290,
    kind: PredictionKind.still
  },
  {name: "a trip with no path is drawn at its report", ...MOVING, path: null, atSeconds: 190, kind: PredictionKind.noPath},
  {name: "a report 80 m from its path is drawn at the report", ...MOVING, last: {east: 500, north: 80, seconds: 130}, atSeconds: 190, kind: PredictionKind.offPath}
]

for (const {name, kind, ...entry} of reportCases) {
  const prediction = predictionOf(entry)
  deepStrictEqual(prediction, {kind, position: report(entry.last).position}, name)
}

// The report a new report is anchored against: the first report of the
// stand it continues, or the report before it.
const STAND_START = report({east: 1000, seconds: 100})
const STAND_NEXT = report({east: 1003, seconds: 130})
const reportBeforeCases = [
  {name: "a report that continues a stand is anchored against its first report", input: {report: report({east: 1006, seconds: 160}), lastReport: STAND_NEXT, previousReport: STAND_START}, expected: STAND_START},
  {name: "a report that leaves a stand is anchored against the report before it", input: {report: report({east: 1030, seconds: 160}), lastReport: STAND_NEXT, previousReport: STAND_START}, expected: STAND_NEXT},
  {name: "a report after a move is anchored against the report before it", input: {report: report({east: 1005, seconds: 160}), lastReport: STAND_NEXT, previousReport: report({east: 900, seconds: 100})}, expected: STAND_NEXT},
  {name: "a second report is anchored against the first", input: {report: STAND_NEXT, lastReport: STAND_START, previousReport: null}, expected: STAND_START}
]

for (const {name, input, expected} of reportBeforeCases) {
  deepStrictEqual(reportBefore(input), expected, name)
}

const movingPrediction = predictionOf({...MOVING, atSeconds: 190})
near({actual: movingPrediction.anchorDistanceMeters, expected: 500, message: "the prediction names the anchor's distance"})

// Corrections: how the drawn marker meets the first prediction of a new
// report, which here is at 800 m on the street 160 s into the trip, on time.
const NEW_REPORT = {path: streetPath, last: {east: 800, seconds: 160}, previous: {east: 700, seconds: 140}}
const NEW_REPORT_SECONDS = 160

function drawnAlong({meters, tripId = TRIP_ID}) {
  return {kind: DrawnKind.alongPath, position: at({east: meters}), distanceMeters: meters, tripId, serviceDateMs: SERVICE_DATE_MS}
}

function correctionOf({report: entry, drawn, seconds}) {
  const prediction = predictionOf({...entry, atSeconds: seconds})
  return beginCorrection({drawn: drawnAlong(drawn), prediction, atMs: msAt(seconds)})
}

const correctionKindCases = [
  {name: "a report up to 150 m behind the marker holds it", drawn: {meters: 900}, kind: CorrectionKind.hold},
  {name: "a report up to 500 m ahead of the marker catches it up", drawn: {meters: 700}, kind: CorrectionKind.catchUp},
  {name: "a report 300 m behind the marker glides it back", drawn: {meters: 1100}, kind: CorrectionKind.glide},
  {name: "a report 600 m ahead of the marker snaps it there", drawn: {meters: 200}, kind: CorrectionKind.snap},
  {name: "a marker moving onto another trip glides", drawn: {meters: 700, tripId: OTHER_TRIP_ID}, kind: CorrectionKind.glide},
  {name: "a report that agrees with the marker changes nothing", drawn: {meters: 800}, kind: CorrectionKind.settled}
]

for (const {name, drawn, kind} of correctionKindCases) {
  const correction = correctionOf({report: NEW_REPORT, drawn, seconds: NEW_REPORT_SECONDS})
  deepStrictEqual(correction.kind, kind, name)
}

function drawnAt({report: entry, correction, seconds}) {
  const prediction = predictionOf({...entry, atSeconds: seconds})
  return drawCorrected({path: entry.path, correction, prediction, atMs: msAt(seconds)})
}

// The prediction advances 5 m/s, so a marker held 100 m ahead of it is
// passed after 20 s; a catch-up of 100 m closes over 2 s while the
// prediction moves on; a glide of 300 m is halfway to the moving prediction
// after half a second.
// The dwell schedule's prediction stops at 1,000 m, short of a marker held
// at 1,100 m, so that hold ends with the report's horizon at 312 s.
const WAITING = {path: dwellPath, last: {east: 960, seconds: 192}, previous: {east: 860, seconds: 172}}
const WAITING_SECONDS = 192

const drawnCases = [
  {name: "a held marker stays while the prediction is behind it", report: NEW_REPORT, startSeconds: NEW_REPORT_SECONDS, drawn: {meters: 900}, seconds: 170, expected: {east: 900}},
  {name: "a held marker moves on once the prediction passes it", report: NEW_REPORT, startSeconds: NEW_REPORT_SECONDS, drawn: {meters: 900}, seconds: 190, expected: {east: 950}},
  {name: "a catch-up starts at the drawn marker", report: NEW_REPORT, startSeconds: NEW_REPORT_SECONDS, drawn: {meters: 700}, seconds: 160, expected: {east: 700}},
  {name: "a catch-up is halfway after 1 s", report: NEW_REPORT, startSeconds: NEW_REPORT_SECONDS, drawn: {meters: 700}, seconds: 161, expected: {east: 755}},
  {name: "a catch-up ends at the prediction after 2 s", report: NEW_REPORT, startSeconds: NEW_REPORT_SECONDS, drawn: {meters: 700}, seconds: 162, expected: {east: 810}},
  {name: "a glide is halfway after half a second", report: NEW_REPORT, startSeconds: NEW_REPORT_SECONDS, drawn: {meters: 1100}, seconds: 160.5, expected: {east: 951.25}},
  {name: "a hold lasts until the report reaches the horizon", report: WAITING, startSeconds: WAITING_SECONDS, drawn: {meters: 1100}, seconds: 311, expected: {east: 1100}},
  {name: "an expired hold glides back to the prediction", report: WAITING, startSeconds: WAITING_SECONDS, drawn: {meters: 1100}, seconds: 312.5, expected: {east: 1050}},
  {name: "an expired hold ends at the prediction", report: WAITING, startSeconds: WAITING_SECONDS, drawn: {meters: 1100}, seconds: 314, expected: {east: 1000}}
]

for (const {name, report: entry, startSeconds, drawn, seconds, expected} of drawnCases) {
  const correction = correctionOf({report: entry, drawn, seconds: startSeconds})
  const drawnMarker = drawnAt({report: entry, correction, seconds})
  isAt({position: drawnMarker.position, expected, message: name})
}

// Invalid inputs are programmer errors.
const OUT_OF_ORDER_TIMES = [
  {distanceMeters: 0, arrivalSeconds: 0, departureSeconds: 100},
  {distanceMeters: 1000, arrivalSeconds: 50, departureSeconds: 50}
]
const OUT_OF_ORDER_DISTANCES = [
  {distanceMeters: 600, arrivalSeconds: 0, departureSeconds: 0},
  {distanceMeters: 500, arrivalSeconds: 50, departureSeconds: 50}
]
const TWO_POINTS = [{east: 0}, {east: 1000}]
const NEGATIVE_MS = -1

const invalidCases = [
  {name: "a negative time", run: () => predictPosition({path: streetPath, anchor: movingAnchor, atMs: NEGATIVE_MS})},
  {name: "a negative report time", run: () => anchorReport({path: streetPath, lastReport: {...report(MOVING.last), reportedAtMs: NEGATIVE_MS}, previousReport: null})},
  {name: "an empty path", run: () => preparePath({tripId: TRIP_ID, serviceDateMs: SERVICE_DATE_MS, points: [], stops: []})},
  {name: "stop times out of order", run: () => pathOfStops({points: TWO_POINTS, stops: OUT_OF_ORDER_TIMES})},
  {name: "stop distances out of order", run: () => pathOfStops({points: TWO_POINTS, stops: OUT_OF_ORDER_DISTANCES})},
  {name: "a path of another trip", run: () => anchorOf({...MOVING, last: {...MOVING.last, tripId: OTHER_TRIP_ID}})}
]

for (const {name, run} of invalidCases) {
  throws(run, AssertionError, name)
}

console.log("vehicle prediction: hand-written cases hold")

// The replay. Each pair names the report the newest fetch before a later
// report held, and the later report: the error is the distance from the
// prediction for the later report's time to where it was reported.
const FIXTURE_URL = new URL("../fixtures/vehicle_prediction/kcm_2026-11-08.json.gz", import.meta.url)
const REPORT_TRIP_FIELD = 3
const REPORT_AGE_FIELD = 4
const DESIGN_TOLERANCE_METERS = 10

// What this module measures on the committed fixture, a sample of 60
// vehicles drawn with the seed the fixture records, and what it is expected
// to measure on the whole store's cut of every vehicle of the day (13,461
// pairs), the cut an argument names. The whole store's 128 m and 416 m are
// unmeasured under the rule that has a standing vehicle leave, for want
// of a Sunday store.
const SAMPLE_EXPECTED = Object.freeze({p50Meters: 131, p90Meters: 411, tripEndP90Meters: 65})
const WHOLE_STORE_EXPECTED = Object.freeze({p50Meters: 128, p90Meters: 416, tripEndP90Meters: 21})

// A vehicle that has just stopped is driven on until its next report shows
// it still, so the 90th percentile of standing still varies with how many
// stops a sample holds, and its median is what is asserted.
const STILL_P50_METERS_MAX = DESIGN_TOLERANCE_METERS
const MOVED_METERS_MIN = 15
// Two reports this close together are a vehicle standing, as the
// prediction judges it.
const STAND_METERS_MAX = 10
const TRIP_END_METERS = 150
const MEDIAN = 0.5
const NINETIETH = 0.9
const POLYLINE_PRECISION = 1e5
const POLYLINE_CHUNK_BITS = 5
const POLYLINE_CHUNK_MASK = 0x1f
const POLYLINE_CONTINUE = 0x20
const POLYLINE_OFFSET = 63

// Google's encoded polyline format, latitude first, at five decimals.
// https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-11-09
function decodePolyline(text) {
  const points = []
  const deltas = [0, 0]
  let index = 0

  while (index < text.length) {
    for (let coordinate = 0; coordinate < deltas.length; coordinate++) {
      let shift = 0
      let result = 0
      let chunk = POLYLINE_CONTINUE
      while (chunk >= POLYLINE_CONTINUE) {
        chunk = text.charCodeAt(index) - POLYLINE_OFFSET
        index++
        result |= (chunk & POLYLINE_CHUNK_MASK) << shift
        shift += POLYLINE_CHUNK_BITS
      }
      let delta = result >> 1
      if (result & 1) {
        delta = ~delta
      }
      deltas[coordinate] += delta
    }
    points.push([deltas[1] / POLYLINE_PRECISION, deltas[0] / POLYLINE_PRECISION])
  }

  return points
}

function percentile(values, fraction) {
  // A copy, since `sort` orders the caller's array in place.
  const sorted = Array.from(values).sort(byNumber)
  return sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))]
}

function byNumber(left, right) {
  return left - right
}

let fixtureUrl = FIXTURE_URL
let expected = SAMPLE_EXPECTED
const [, , fixtureArgument] = process.argv
if (fixtureArgument !== undefined) {
  fixtureUrl = new URL(fixtureArgument, `file://${process.cwd()}/`)
  expected = WHOLE_STORE_EXPECTED
}
const fixtureBytes = readFileSync(fixtureUrl)
const fixtureText = gunzipSync(fixtureBytes).toString("utf8")
const fixture = JSON.parse(fixtureText)

function stopOf([distanceMeters, arrivalSeconds, departureSeconds]) {
  return {distanceMeters, arrivalSeconds, departureSeconds}
}

const preparedPaths = new Map()
for (const [key, {points, stops}] of Object.entries(fixture.paths)) {
  const [tripId, serviceDateMs] = fixture.trips[Number(key)]
  const decodedPoints = decodePolyline(points)
  const pathStops = Array.from(stops, stopOf)
  preparedPaths.set(Number(key), preparePath({tripId, serviceDateMs, points: decodedPoints, stops: pathStops}))
}

// The prepared path of the trip `tripIndex` names, or null for a trip the
// fixture holds no path of, as the prediction takes it.
function pathParameterOf(tripIndex) {
  let path = null
  if (preparedPaths.has(tripIndex)) {
    path = preparedPaths.get(tripIndex)
  }
  return path
}

// A report of the fixture, as `fields.reports` describes it, on the trip
// `tripIndex` names.
function reportOf({entry, tripIndex}) {
  const [offsetMs, lon, lat] = entry
  const [tripId, serviceDateMs] = fixture.trips[tripIndex]
  return {position: [lon, lat], reportedAtMs: fixture.baseMs + offsetMs, tripId, serviceDateMs}
}

function reportsOf(entries) {
  const reports = []
  for (const entry of entries) {
    reports.push(reportOf({entry, tripIndex: entry[REPORT_TRIP_FIELD]}))
  }
  return reports
}

// The report each report is anchored against, as the page chooses it from
// the reports a vehicle's fetches bring in order: the first report of a
// stand the report continues, or the report before it.
function previousReportsOf(reports) {
  const previousReports = []
  let previousReport = null
  for (let index = 0; index < reports.length; index++) {
    if (index > 0) {
      previousReport = reportBefore({report: reports[index], lastReport: reports[index - 1], previousReport})
    }
    previousReports.push(previousReport)
  }
  return previousReports
}

// The report just before the one at `index`, which says whether a vehicle
// was standing when it sent that one, whatever the prediction makes of it.
function reportJustBefore({reports, index}) {
  let previousReport = null
  if (index > 0) {
    previousReport = reports[index - 1]
  }
  return previousReport
}

const errors = {headline: [], today: [], still: [], moving: [], layover: [], tripEnd: [], restarted: [], stayed: []}

function measurePair({entries, reports, previousReports, pair}) {
  const [lastIndex, truthIndex, sourceLon, sourceLat, tripIndex] = pair
  const lastReport = reportOf({entry: entries[lastIndex], tripIndex})
  const truth = reports[truthIndex]
  const previousReport = previousReports[lastIndex]
  const justBefore = reportJustBefore({reports, index: lastIndex})
  if (!preparedPaths.has(tripIndex)) {
    return
  }

  const path = preparedPaths.get(tripIndex)
  const anchor = anchorReport({path, lastReport, previousReport})
  const prediction = predictPosition({path, anchor, atMs: truth.reportedAtMs})
  const error = distanceMeters(prediction.position, truth.position)
  const isPreviousOnTrip = justBefore !== null && justBefore.tripId === lastReport.tripId
  const lone = anchorReport({path, lastReport, previousReport: null})
  const isOnPath = lone.kind === PredictionKind.alongPath
  const isMeasured = isPreviousOnTrip && isOnPath
  if (!isMeasured) {
    return
  }

  const isAtTripEnd = lone.distanceMeters > path.lengthMeters - TRIP_END_METERS
  if (isAtTripEnd) {
    errors.tripEnd.push(error)
  }
  if (truth.tripId !== lastReport.tripId) {
    errors.layover.push(error)
    return
  }

  errors.headline.push(error)
  errors.today.push(distanceMeters([sourceLon, sourceLat], truth.position))
  const isStill = distanceMeters(lastReport.position, truth.position) < MOVED_METERS_MIN
  if (isStill) {
    errors.still.push(error)
  } else {
    errors.moving.push(error)
  }
  const isAfterStand = distanceMeters(justBefore.position, lastReport.position) < STAND_METERS_MAX
  if (isAfterStand) {
    measureStand({error, isStill})
  }
}

function measureStand({error, isStill}) {
  if (isStill) {
    errors.stayed.push(error)
  } else {
    errors.restarted.push(error)
  }
}

for (const vehicle of fixture.vehicles) {
  const reports = reportsOf(vehicle.reports)
  const previousReports = previousReportsOf(reports)
  for (const pair of vehicle.pairs) {
    measurePair({entries: vehicle.reports, reports, previousReports, pair})
  }
}

function summary(values) {
  const p50 = Math.round(percentile(values, MEDIAN))
  const p90 = Math.round(percentile(values, NINETIETH))
  return `n ${values.length}, p50 ${p50} m, p90 ${p90} m`
}

const headlineP50 = percentile(errors.headline, MEDIAN)
const headlineP90 = percentile(errors.headline, NINETIETH)
console.log(`replay: ${summary(errors.headline)}; today's marker ${summary(errors.today)}`)
console.log(`replay: standing still ${summary(errors.still)}; moving ${summary(errors.moving)}`)
console.log(`replay: within ${TRIP_END_METERS} m of the trip's end ${summary(errors.tripEnd)}; onto the next trip ${summary(errors.layover)}`)
console.log(`replay: after a stand, moved on ${summary(errors.restarted)}; still standing ${summary(errors.stayed)}`)
const tripEndP90 = percentile(errors.tripEnd, NINETIETH)
ok(Math.abs(headlineP50 - expected.p50Meters) <= DESIGN_TOLERANCE_METERS, `the median error ${headlineP50} m is the measured ${expected.p50Meters} m`)
ok(Math.abs(headlineP90 - expected.p90Meters) <= DESIGN_TOLERANCE_METERS, `the 90th percentile ${headlineP90} m is the measured ${expected.p90Meters} m`)
ok(percentile(errors.still, MEDIAN) <= STILL_P50_METERS_MAX, "a vehicle standing still is drawn where it stands")
ok(tripEndP90 <= expected.tripEndP90Meters + DESIGN_TOLERANCE_METERS, `the trip's end's 90th percentile ${tripEndP90} m is within the measured ${expected.tripEndP90Meters} m`)
ok(headlineP90 < percentile(errors.today, NINETIETH), "the prediction is nearer than today's marker")

// The corrections, replayed: each vehicle's reports arrive at the first
// fetch that held them, each arrival begins a correction from where the
// marker is drawn, and at each later report's time the drawn marker and the
// bare prediction are both measured against that report.
const correctionCounts = new Map()
const corrected = {drawn: [], predicted: []}

function eventsOf(entries) {
  const events = []
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index]
    const reportedAtMs = fixture.baseMs + entry[0]
    events.push({atMs: reportedAtMs, index, isArrival: false})
    events.push({atMs: reportedAtMs + entry[REPORT_AGE_FIELD], index, isArrival: true})
  }
  return events.sort(byEventTime)
}

// A report reached at the time a fetch brings another is measured first,
// against what was drawn before that fetch.
function byEventTime(left, right) {
  if (left.atMs !== right.atMs) {
    return left.atMs - right.atMs
  }
  return Number(left.isArrival) - Number(right.isArrival)
}

function countCorrection(kind) {
  let count = 0
  if (correctionCounts.has(kind)) {
    count = correctionCounts.get(kind)
  }
  correctionCounts.set(kind, count + 1)
}

function replayCorrections(entries) {
  const reports = reportsOf(entries)
  const previousReports = previousReportsOf(reports)
  let shown = null

  for (const {atMs, index, isArrival} of eventsOf(entries)) {
    if (isArrival) {
      const path = pathParameterOf(entries[index][REPORT_TRIP_FIELD])
      const anchor = anchorReport({path, lastReport: reports[index], previousReport: previousReports[index]})
      const prediction = predictPosition({path, anchor, atMs})
      let correction = {kind: CorrectionKind.settled}
      if (shown !== null) {
        const shownPrediction = predictPosition({path: shown.path, anchor: shown.anchor, atMs})
        const drawn = drawCorrected({path: shown.path, correction: shown.correction, prediction: shownPrediction, atMs})
        correction = beginCorrection({drawn, prediction, atMs})
        countCorrection(correction.kind)
      }
      shown = {path, anchor, correction, index}
      continue
    }

    const isMeasured = shown !== null && shown.index < index
    if (!isMeasured) {
      continue
    }
    const isSameTrip = reports[shown.index].tripId === reports[index].tripId
    const isAlong = shown.anchor.kind === PredictionKind.alongPath
    const isCorrectable = isSameTrip && isAlong
    if (!isCorrectable) {
      continue
    }
    const prediction = predictPosition({path: shown.path, anchor: shown.anchor, atMs})
    const drawn = drawCorrected({path: shown.path, correction: shown.correction, prediction, atMs})
    corrected.predicted.push(distanceMeters(prediction.position, reports[index].position))
    corrected.drawn.push(distanceMeters(drawn.position, reports[index].position))
  }
}

for (const vehicle of fixture.vehicles) {
  replayCorrections(vehicle.reports)
}

const countsText = JSON.stringify(Object.fromEntries(correctionCounts))
console.log(`replay: corrections ${countsText}`)
console.log(`replay: along the path, drawn ${summary(corrected.drawn)}; predicted ${summary(corrected.predicted)}`)
const drawnP90 = percentile(corrected.drawn, NINETIETH)
const predictedP90 = percentile(corrected.predicted, NINETIETH)
ok(drawnP90 <= predictedP90 + DESIGN_TOLERANCE_METERS, `the corrections' 90th percentile ${drawnP90} m is within ${DESIGN_TOLERANCE_METERS} m of the prediction's ${predictedP90} m`)
