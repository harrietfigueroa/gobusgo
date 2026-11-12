// Where a vehicle is drawn between fetches: its last report, advanced along
// its trip's path at the schedule's pace and shifted by the lateness that
// report shows, or held where it stands until it is due to leave. Everything
// here is pure: the path, the reports, and
// the time asked about are given as values, so a prediction is a function of
// them alone and a replay of stored fetches measures it.
//
// Positions are [lon, lat]. Times are milliseconds on the source's clock,
// except a stop's scheduled times, which are seconds after the trip's
// service date as the source's schedule gives them.

import {assertCondition, unreachable} from "./core/assert.js"
import {glidePosition, glides} from "./marker_glide.js"
import {LAT, LON, METERS_PER_DEGREE, assertPlaneCovers, assertPosition, distanceMeters, initialBearingDegrees, tangentPlane} from "./core/math/geodesy.js"
import {clamp, lerp} from "./core/math/interpolation.js"
import {COORDINATES_PER_POINT, POINT_X, POINT_Y, nearestAlong, segmentIndexAt} from "./core/math/polyline.js"

/** The most points a path holds. */
export const PATH_POINT_COUNT_MAX = 20000

/** The most stops a path holds. */
export const PATH_STOP_COUNT_MAX = 500

/** How long after its report a prediction advances: the age at which a report is stale. */
export const PREDICTION_HORIZON_MS = 2 * 60 * 1000

// Two reports this close together are one vehicle standing, which the
// schedule would otherwise drive on through its stop.
const STILL_METERS_MAX = 10

// A vehicle that has stood less than the hold leaves this long after its
// stand began, and one that has stood the hold or longer stays, both the
// best of those measured on a weekday's replay of King County Metro and
// Sound Transit fetches.
const STAND_DWELL_SECONDS = 30
const STAND_HOLD_SECONDS = 90

// A vehicle this close to its trip's first stop, or to any stop, stands at
// that stop.
const FIRST_STOP_REACH_METERS = 50
const STOP_REACH_METERS = 30

// A report farther than this from its trip's path is not on that path.
const PATH_DISTANCE_METERS_MAX = 60

// A report projects at or after the report before it, less this much, so a
// loop route's second pass is never anchored on its first.
const PROJECTION_SLACK_METERS = 1

// A stop may stand this far past the path's end, the rounding of the
// encoded points the stop distances were measured over.
const STOP_DISTANCE_SLACK_METERS = 5

// A new prediction up to this far behind the drawn marker holds it there,
// and one up to the second bound ahead catches it up over the duration.
const HOLD_METERS_MAX = 150
const CATCH_UP_METERS_MAX = 500
const CATCH_UP_DURATION_MS = 2000

// A new prediction closer than this to the drawn marker is the same place,
// the difference the rounding of two projections leaves.
const SETTLED_METERS_MAX = 0.5

const MS_PER_SECOND = 1000
const HALF = 2

/** Where a prediction puts a vehicle: along its path, or at its report and why. */
export const PredictionKind = Object.freeze({alongPath: "alongPath", still: "still", noPath: "noPath", offPath: "offPath"})

/** How a marker meets a new prediction. */
export const CorrectionKind = Object.freeze({settled: "settled", hold: "hold", catchUp: "catchUp", glide: "glide", snap: "snap"})

/** Where a marker is drawn: at a distance along a path, or at a point. */
export const DrawnKind = Object.freeze({alongPath: "alongPath", atPoint: "atPoint"})

const SETTLED = Object.freeze({kind: CorrectionKind.settled})
const SNAP = Object.freeze({kind: CorrectionKind.snap})

function assertTimeMs(timeMs, message) {
  assertCondition(Number.isFinite(timeMs), `${message}: ${timeMs} is not a time`)
  assertCondition(timeMs >= 0, `${message}: ${timeMs} is negative`)
}

function assertReport(report, message) {
  assertPosition(report.position, message)
  assertTimeMs(report.reportedAtMs, `${message} time`)
  assertTimeMs(report.serviceDateMs, `${message} service date`)
  assertCondition(typeof report.tripId === "string", `${message}: trip ${report.tripId} is not an identifier`)
}

function assertStops({stops, lengthMeters}) {
  assertCondition(Array.isArray(stops), "a path's stops are a list")
  assertCondition(stops.length >= HALF, `a path has at least two stops, not ${stops.length}`)
  assertCondition(stops.length <= PATH_STOP_COUNT_MAX, `a path has at most ${PATH_STOP_COUNT_MAX} stops, not ${stops.length}`)
  const distanceMetersMax = lengthMeters + STOP_DISTANCE_SLACK_METERS
  let previous = {distanceMeters: 0, departureSeconds: 0}

  for (const stop of stops) {
    assertCondition(Number.isFinite(stop.distanceMeters), `stop distance ${stop.distanceMeters} is not a number`)
    assertCondition(stop.distanceMeters >= previous.distanceMeters, `stop distance ${stop.distanceMeters} is before ${previous.distanceMeters}`)
    assertCondition(stop.distanceMeters <= distanceMetersMax, `stop distance ${stop.distanceMeters} is past the path's ${lengthMeters} m`)
    assertCondition(Number.isFinite(stop.arrivalSeconds), `stop arrival ${stop.arrivalSeconds} is not a number`)
    assertCondition(stop.arrivalSeconds >= previous.departureSeconds, `stop arrival ${stop.arrivalSeconds} is before ${previous.departureSeconds}`)
    assertCondition(stop.departureSeconds >= stop.arrivalSeconds, `stop departure ${stop.departureSeconds} is before its arrival ${stop.arrivalSeconds}`)
    previous = stop
  }
}

/**
 * A trip's path made ready for predictions, from the trip's identifier, its
 * service date in milliseconds, its points as [lon, lat] in order of travel,
 * and its stops in order, each with its distance along the points in meters
 * and its scheduled arrival and departure in seconds after the service date.
 * Prepare a path once and predict from it many times.
 */
export function preparePath({tripId, serviceDateMs, points, stops}) {
  assertCondition(typeof tripId === "string", `trip ${tripId} is not an identifier`)
  assertTimeMs(serviceDateMs, "a path's service date")
  assertCondition(Array.isArray(points), "a path's points are a list")
  assertCondition(points.length >= HALF, `a path has at least two points, not ${points.length}`)
  assertCondition(points.length <= PATH_POINT_COUNT_MAX, `a path has at most ${PATH_POINT_COUNT_MAX} points, not ${points.length}`)

  // Projection works in meters on a plane tangent at the first point, whose
  // scale is asserted over the path's latitudes; distances along the path
  // are great-circle distances, the measure its stops are given in.
  const latOrigin = points[0][LAT]
  const plane = tangentPlane({referenceLatitudeDegrees: latOrigin})
  const {metersPerDegreeLon} = plane
  const xs = new Float64Array(points.length)
  const ys = new Float64Array(points.length)
  const coordinates = new Float64Array(points.length * COORDINATES_PER_POINT)
  const cumulativeMeters = new Float64Array(points.length)
  let latitudeDegreesMin = latOrigin
  let latitudeDegreesMax = latOrigin

  for (let index = 0; index < points.length; index++) {
    const point = points[index]
    assertPosition(point, `path point ${index}`)
    const lon = point[LON]
    const lat = point[LAT]
    xs[index] = lon * metersPerDegreeLon
    ys[index] = lat * METERS_PER_DEGREE
    coordinates[index * COORDINATES_PER_POINT + POINT_X] = lon
    coordinates[index * COORDINATES_PER_POINT + POINT_Y] = lat
    latitudeDegreesMin = Math.min(latitudeDegreesMin, lat)
    latitudeDegreesMax = Math.max(latitudeDegreesMax, lat)
    if (index > 0) {
      cumulativeMeters[index] = cumulativeMeters[index - 1] + distanceMeters(points[index - 1], point)
    }
  }

  const lengthMeters = cumulativeMeters[points.length - 1]
  assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})
  assertStops({stops, lengthMeters})

  return Object.freeze({tripId, serviceDateMs, points, stops, xs, ys, coordinates, cumulativeMeters, lengthMeters, metersPerDegreeLon})
}

// The nearest point of the path at or after `distanceMetersMin`, as its
// distance along the path and its distance from `position`.
function project({path, position, distanceMetersMin}) {
  const x = position[LON] * path.metersPerDegreeLon
  const y = position[LAT] * METERS_PER_DEGREE
  const alongMin = distanceMetersMin - PROJECTION_SLACK_METERS
  const nearest = nearestAlong({xs: path.xs, ys: path.ys, cumulative: path.cumulativeMeters, x, y, alongMin})
  return {offsetMeters: nearest.offset, distanceMeters: nearest.along}
}

// The schedule's time, in seconds after the service date, at which the
// trip reaches `meters` along its path: between a stop's departure and the
// next stop's arrival at an even pace.
function scheduledSeconds({stops, meters}) {
  if (meters <= stops[0].distanceMeters) {
    return stops[0].departureSeconds
  }

  for (let index = 0; index + 1 < stops.length; index++) {
    const source = stops[index]
    const target = stops[index + 1]
    if (meters <= target.distanceMeters) {
      const spanMeters = target.distanceMeters - source.distanceMeters
      let fraction = 1
      if (spanMeters > 0) {
        fraction = (meters - source.distanceMeters) / spanMeters
      }
      return lerp({from: source.departureSeconds, to: target.arrivalSeconds, fraction})
    }
  }

  return stops[stops.length - 1].arrivalSeconds
}

// The schedule's distance along the path `seconds` after the service date:
// at a stop from its arrival to its departure, between stops at an even
// pace, and at the first or last stop outside the trip's times.
function scheduledMeters({stops, seconds}) {
  const first = stops[0]
  const last = stops[stops.length - 1]
  if (seconds <= first.departureSeconds) {
    return first.distanceMeters
  }
  if (seconds >= last.arrivalSeconds) {
    return last.distanceMeters
  }

  for (let index = 0; index + 1 < stops.length; index++) {
    const source = stops[index]
    const target = stops[index + 1]
    if (seconds < target.arrivalSeconds) {
      if (seconds <= source.departureSeconds) {
        return source.distanceMeters
      }
      const spanSeconds = target.arrivalSeconds - source.departureSeconds
      const fraction = (seconds - source.departureSeconds) / spanSeconds
      return lerp({from: source.distanceMeters, to: target.distanceMeters, fraction})
    }
    if (seconds <= target.departureSeconds) {
      return target.distanceMeters
    }
  }

  return last.distanceMeters
}

// The [lon, lat] position `meters` along the path, found by halving the
// points, so a frame's cost grows with the logarithm of the path's length.
function positionAt({path, meters}) {
  const along = clamp({value: meters, min: 0, max: path.lengthMeters})
  const low = segmentIndexAt({cumulative: path.cumulativeMeters, along})
  const high = low + 1

  const segmentMeters = path.cumulativeMeters[high] - path.cumulativeMeters[low]
  let fraction = 0
  if (segmentMeters > 0) {
    fraction = (along - path.cumulativeMeters[low]) / segmentMeters
  }
  const source = low * COORDINATES_PER_POINT
  const target = high * COORDINATES_PER_POINT
  const lon = lerp({from: path.coordinates[source + POINT_X], to: path.coordinates[target + POINT_X], fraction})
  const lat = lerp({from: path.coordinates[source + POINT_Y], to: path.coordinates[target + POINT_Y], fraction})
  return [lon, lat]
}

/**
 * The bearing of `path`, a prepared path, at `meters` along it, in degrees
 * clockwise from true north: that of the segment holding the distance,
 * brought inside the path's ends, or of the nearest segment after it, then
 * before it, where that segment has no length.
 */
export function pathBearingDegrees({path, meters}) {
  assertCondition(Number.isFinite(meters), `a distance along a path is a number, got: ${meters}`)
  const along = clamp({value: meters, min: 0, max: path.lengthMeters})
  const segmentIndex = segmentIndexAt({cumulative: path.cumulativeMeters, along})
  const segmentCount = path.points.length - 1

  for (let index = segmentIndex; index < segmentCount; index++) {
    if (path.cumulativeMeters[index + 1] > path.cumulativeMeters[index]) {
      return initialBearingDegrees(path.points[index], path.points[index + 1])
    }
  }

  for (let index = segmentIndex - 1; index >= 0; index--) {
    if (path.cumulativeMeters[index + 1] > path.cumulativeMeters[index]) {
      return initialBearingDegrees(path.points[index], path.points[index + 1])
    }
  }

  assertCondition(path.lengthMeters > 0, `a path of ${path.lengthMeters} m has a bearing`)
  return unreachable(path.lengthMeters, "a path with length and no segment of length")
}

function atReport({kind, report}) {
  return Object.freeze({kind, position: report.position})
}

function isStanding({source, target}) {
  return distanceMeters(source.position, target.position) < STILL_METERS_MAX
}

/**
 * The report a vehicle's new report `report` is anchored against, given the
 * vehicle's last report `lastReport` and the report that one was anchored
 * against, `previousReport`, or null: the first report of a stand that
 * `report` continues, or `lastReport` otherwise.
 */
export function reportBefore({report, lastReport, previousReport}) {
  assertReport(report, "the new report")
  assertReport(lastReport, "the last report")
  if (previousReport === null) {
    return lastReport
  }

  const isStandHeld = isStanding({source: previousReport, target: lastReport})
  const isStandContinued = isStanding({source: previousReport, target: report})
  const isSameStand = isStandHeld && isStandContinued
  if (isSameStand) {
    return previousReport
  }
  return lastReport
}

// Whether a standing vehicle leaves its stand before its next report.
const StandDepartureKind = Object.freeze({leaves: "leaves", stays: "stays"})

// The schedule's time, in seconds after the service date, at which the
// trip leaves `meters` along its path: a stop's departure where a stop
// stands within reach, and the time it passes there otherwise.
function scheduledDepartureSeconds({stops, meters}) {
  for (const stop of stops) {
    if (Math.abs(stop.distanceMeters - meters) <= STOP_REACH_METERS) {
      return stop.departureSeconds
    }
  }
  return scheduledSeconds({stops, meters})
}

// When a vehicle standing at `meters` since `standSeconds`, last reported
// at `lastSeconds`, leaves, in seconds after the service date: at its
// trip's scheduled first departure while it lays over before it, and
// otherwise a dwell after its stand began, unless it has stood the hold
// already and stays.
function standDeparture({stops, meters, standSeconds, lastSeconds}) {
  const first = stops[0]
  const isAtFirstStop = meters <= first.distanceMeters + FIRST_STOP_REACH_METERS
  const isBeforeDeparture = lastSeconds < first.departureSeconds
  const isLayingOver = isAtFirstStop && isBeforeDeparture
  if (isLayingOver) {
    return {kind: StandDepartureKind.leaves, seconds: first.departureSeconds}
  }

  const stoodSeconds = lastSeconds - standSeconds
  if (stoodSeconds >= STAND_HOLD_SECONDS) {
    return {kind: StandDepartureKind.stays}
  }
  return {kind: StandDepartureKind.leaves, seconds: Math.max(lastSeconds, standSeconds + STAND_DWELL_SECONDS)}
}

// The anchor of a vehicle whose `lastReport` stands where `standReport`,
// the first report of its stand, did: along the path with the lateness that
// has it leave when `standDeparture` says, or at its report while it stays,
// has no path, or stands off it.
function standAnchor({path, lastReport, standReport}) {
  assertCondition(standReport.reportedAtMs <= lastReport.reportedAtMs, `a stand begins at ${standReport.reportedAtMs}, after its last report at ${lastReport.reportedAtMs}`)
  if (path === null) {
    return atReport({kind: PredictionKind.still, report: lastReport})
  }

  const projection = projectReport({path, lastReport, previousReport: standReport})
  if (projection.offsetMeters > PATH_DISTANCE_METERS_MAX) {
    return atReport({kind: PredictionKind.still, report: lastReport})
  }

  const lastSeconds = (lastReport.reportedAtMs - path.serviceDateMs) / MS_PER_SECOND
  const standSeconds = (standReport.reportedAtMs - path.serviceDateMs) / MS_PER_SECOND
  const departure = standDeparture({stops: path.stops, meters: projection.distanceMeters, standSeconds, lastSeconds})
  switch (departure.kind) {
    case StandDepartureKind.stays:
      return atReport({kind: PredictionKind.still, report: lastReport})
    case StandDepartureKind.leaves:
      break
    default:
      unreachable(departure.kind, "a stand of no kind")
  }

  const leavingSeconds = scheduledDepartureSeconds({stops: path.stops, meters: projection.distanceMeters})
  return alongAnchor({lastReport, distanceMeters: projection.distanceMeters, deviationSeconds: departure.seconds - leavingSeconds})
}

// The report's nearest point of its trip's path, at or after the projection
// of the report before it on the same run.
function projectReport({path, lastReport, previousReport}) {
  assertCondition(path.tripId === lastReport.tripId, `the path of trip ${path.tripId} is not that of trip ${lastReport.tripId}`)
  assertCondition(path.serviceDateMs === lastReport.serviceDateMs, `the path of ${path.serviceDateMs} is not that of ${lastReport.serviceDateMs}`)
  const distanceMetersMin = projectionFloor({path, lastReport, previousReport})
  return project({path, position: lastReport.position, distanceMetersMin})
}

function alongAnchor({lastReport, distanceMeters: anchorMeters, deviationSeconds}) {
  assertCondition(Number.isFinite(deviationSeconds), `deviation ${deviationSeconds} is not a number`)
  return Object.freeze({
    kind: PredictionKind.alongPath,
    position: lastReport.position,
    reportedAtMs: lastReport.reportedAtMs,
    tripId: lastReport.tripId,
    serviceDateMs: lastReport.serviceDateMs,
    distanceMeters: anchorMeters,
    deviationSeconds
  })
}

// The distance along the path at or after which `lastReport` projects: the
// projection of the report before it on the same trip, where that report is
// on the path, and the path's start otherwise.
function projectionFloor({path, lastReport, previousReport}) {
  if (previousReport === null) {
    return 0
  }

  const isSameTrip = previousReport.tripId === lastReport.tripId
  const isSameDate = previousReport.serviceDateMs === lastReport.serviceDateMs
  const isSameRun = isSameTrip && isSameDate
  if (!isSameRun) {
    return 0
  }

  const previous = project({path, position: previousReport.position, distanceMetersMin: 0})
  if (previous.offsetMeters > PATH_DISTANCE_METERS_MAX) {
    return 0
  }
  return previous.distanceMeters
}

/**
 * What a vehicle's last report says about where it goes next, worked out
 * once per report. `path` is a prepared path of the report's trip, or null
 * for a trip with no path; `previousReport` is the report `reportBefore`
 * gives, or null when there is none. A report is `{position, reportedAtMs,
 * tripId, serviceDateMs}`. The anchor is a vehicle that stays where it
 * stands, a trip with no path, or a report off its path, each drawn at the
 * report, or the report's distance along the path and its lateness against
 * the schedule there. A standing vehicle that leaves is anchored along its
 * path with the lateness that has it leave on time: at its trip's scheduled
 * first departure while it lays over before it, and otherwise 30 s after
 * its stand began, unless it has stood 90 s already, when it stays.
 */
export function anchorReport({path, lastReport, previousReport}) {
  assertReport(lastReport, "the last report")
  if (previousReport !== null) {
    assertReport(previousReport, "the report before the last")
    if (isStanding({source: previousReport, target: lastReport})) {
      return standAnchor({path, lastReport, standReport: previousReport})
    }
  }

  if (path === null) {
    return atReport({kind: PredictionKind.noPath, report: lastReport})
  }

  const projection = projectReport({path, lastReport, previousReport})
  if (projection.offsetMeters > PATH_DISTANCE_METERS_MAX) {
    return atReport({kind: PredictionKind.offPath, report: lastReport})
  }

  const reportSeconds = (lastReport.reportedAtMs - path.serviceDateMs) / MS_PER_SECOND
  const scheduleSeconds = scheduledSeconds({stops: path.stops, meters: projection.distanceMeters})
  return alongAnchor({lastReport, distanceMeters: projection.distanceMeters, deviationSeconds: reportSeconds - scheduleSeconds})
}

/**
 * The anchor of a vehicle of the saved schedule at `atMs`: the schedule's
 * distance along `path`, a prepared path of its trip, at that time, with no
 * lateness, so the prediction from it follows the schedule along the path.
 * The saved schedule has no report, so the anchor stands for the placement.
 */
export function scheduledAnchor({path, atMs}) {
  assertTimeMs(atMs, "the time of a scheduled anchor")
  const seconds = (atMs - path.serviceDateMs) / MS_PER_SECOND
  const meters = Math.min(scheduledMeters({stops: path.stops, seconds}), path.lengthMeters)
  return Object.freeze({
    kind: PredictionKind.alongPath,
    position: positionAt({path, meters}),
    reportedAtMs: atMs,
    tripId: path.tripId,
    serviceDateMs: path.serviceDateMs,
    distanceMeters: meters,
    deviationSeconds: 0
  })
}

/**
 * Where an anchored vehicle is at `atMs`. Along the path, the schedule's
 * position at that time less the anchor's lateness, never behind the
 * anchor, never past the last stop, and no further than the schedule
 * reaches two minutes after the report; with the anchor's distance kept, so
 * a line from the report to the marker follows the path. Any other anchor
 * is drawn at its report.
 */
export function predictPosition({path, anchor, atMs}) {
  assertTimeMs(atMs, "the time of a prediction")
  switch (anchor.kind) {
    case PredictionKind.still:
    case PredictionKind.noPath:
    case PredictionKind.offPath:
      return anchor
    case PredictionKind.alongPath:
      break
    default:
      unreachable(anchor.kind, "an anchor of no kind")
  }

  assertCondition(path.tripId === anchor.tripId, `the path of trip ${path.tripId} is not the anchor's ${anchor.tripId}`)
  const horizonMs = anchor.reportedAtMs + PREDICTION_HORIZON_MS
  const predictedAtMs = Math.min(atMs, horizonMs)
  const seconds = (predictedAtMs - path.serviceDateMs) / MS_PER_SECOND - anchor.deviationSeconds
  const scheduled = scheduledMeters({stops: path.stops, seconds})
  const ahead = Math.min(scheduled, path.lengthMeters)
  const predictedMeters = Math.max(anchor.distanceMeters, ahead)
  assertCondition(predictedMeters >= anchor.distanceMeters, `prediction ${predictedMeters} is behind its anchor ${anchor.distanceMeters}`)

  return Object.freeze({
    kind: PredictionKind.alongPath,
    position: positionAt({path, meters: predictedMeters}),
    distanceMeters: predictedMeters,
    anchorDistanceMeters: anchor.distanceMeters,
    reportedAtMs: anchor.reportedAtMs,
    tripId: anchor.tripId,
    serviceDateMs: anchor.serviceDateMs
  })
}

function isSameRun({drawn, prediction}) {
  const isDrawnAlong = drawn.kind === DrawnKind.alongPath
  const isPredictedAlong = prediction.kind === PredictionKind.alongPath
  const isBothAlong = isDrawnAlong && isPredictedAlong
  if (!isBothAlong) {
    return false
  }

  const isSameTrip = drawn.tripId === prediction.tripId
  const isSameDate = drawn.serviceDateMs === prediction.serviceDateMs
  const isSame = isSameTrip && isSameDate
  return isSame
}

/**
 * How a marker drawn at `drawn` meets `prediction`, the first prediction of
 * a new report, at `atMs`. On one trip's path, a prediction up to 150 m
 * behind holds the marker until the prediction passes it or stops
 * advancing, and one up to 500 m ahead catches it up over 2 s. Otherwise it
 * glides to the prediction, or snaps there where `glides` says a fetch's
 * marker snaps.
 */
export function beginCorrection({drawn, prediction, atMs}) {
  assertTimeMs(atMs, "the time of a correction")
  assertPosition(drawn.position, "the drawn marker")
  if (isSameRun({drawn, prediction})) {
    const deltaMeters = prediction.distanceMeters - drawn.distanceMeters
    if (Math.abs(deltaMeters) < SETTLED_METERS_MAX) {
      return SETTLED
    }

    const isBehind = deltaMeters < 0
    const isHeldBack = -deltaMeters <= HOLD_METERS_MAX
    const isHold = isBehind && isHeldBack
    if (isHold) {
      const untilMs = prediction.reportedAtMs + PREDICTION_HORIZON_MS
      return Object.freeze({kind: CorrectionKind.hold, distanceMeters: drawn.distanceMeters, position: drawn.position, untilMs})
    }

    const isAhead = deltaMeters > 0
    const isCaughtUp = deltaMeters <= CATCH_UP_METERS_MAX
    const isCatchUp = isAhead && isCaughtUp
    if (isCatchUp) {
      return Object.freeze({kind: CorrectionKind.catchUp, offsetMeters: deltaMeters, startedAtMs: atMs})
    }
  }

  if (glides({source: drawn.position, target: prediction.position, reducedMotion: false})) {
    return Object.freeze({kind: CorrectionKind.glide, source: drawn.position, startedAtMs: atMs})
  }
  return SNAP
}

function drawnOf(prediction) {
  if (prediction.kind === PredictionKind.alongPath) {
    return Object.freeze({
      kind: DrawnKind.alongPath,
      position: prediction.position,
      distanceMeters: prediction.distanceMeters,
      tripId: prediction.tripId,
      serviceDateMs: prediction.serviceDateMs
    })
  }
  return Object.freeze({kind: DrawnKind.atPoint, position: prediction.position})
}

function drawnAlong({path, prediction, meters}) {
  return Object.freeze({
    kind: DrawnKind.alongPath,
    position: positionAt({path, meters}),
    distanceMeters: meters,
    tripId: prediction.tripId,
    serviceDateMs: prediction.serviceDateMs
  })
}

function glidedTo({source, prediction, elapsedMs}) {
  const glide = glidePosition({source, target: prediction.position, elapsedMs})
  if (glide.ended) {
    return drawnOf(prediction)
  }
  return Object.freeze({kind: DrawnKind.atPoint, position: glide.position})
}

/**
 * Where the marker is drawn at `atMs`, under `correction` toward
 * `prediction`, the prediction of the same report at `atMs`. A drawn value
 * is a distance along a trip's path, or a point; either is what the next
 * correction starts from.
 */
export function drawCorrected({path, correction, prediction, atMs}) {
  assertTimeMs(atMs, "the time of a drawn marker")
  switch (correction.kind) {
    case CorrectionKind.settled:
    case CorrectionKind.snap:
      return drawnOf(prediction)
    case CorrectionKind.hold: {
      assertCondition(prediction.kind === PredictionKind.alongPath, `a hold draws along a path, not ${prediction.kind}`)
      if (prediction.distanceMeters >= correction.distanceMeters) {
        return drawnOf(prediction)
      }
      if (atMs < correction.untilMs) {
        return drawnAlong({path, prediction, meters: correction.distanceMeters})
      }
      return glidedTo({source: correction.position, prediction, elapsedMs: atMs - correction.untilMs})
    }
    case CorrectionKind.catchUp: {
      assertCondition(prediction.kind === PredictionKind.alongPath, `a catch-up draws along a path, not ${prediction.kind}`)
      const elapsedMs = Math.max(0, atMs - correction.startedAtMs)
      if (elapsedMs >= CATCH_UP_DURATION_MS) {
        return drawnOf(prediction)
      }
      const remaining = 1 - elapsedMs / CATCH_UP_DURATION_MS
      const meters = prediction.distanceMeters - correction.offsetMeters * remaining
      return drawnAlong({path, prediction, meters})
    }
    case CorrectionKind.glide:
      return glidedTo({source: correction.source, prediction, elapsedMs: atMs - correction.startedAtMs})
    default:
      return unreachable(correction.kind, "a correction of no kind")
  }
}
