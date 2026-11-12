// How the vehicle page follows each vehicle between fetches, as pure
// functions of the marker the server sends, the trip's prepared path or
// none, the previous state, and the time on the source's clock in
// milliseconds. A vehicle is predicted along its path, drawn at its last
// report, or drawn where the fetch puts it, by its status: only a reported
// vehicle on a trip moves. Each state is a frozen value the page
// keeps, and each function returns another.

import {assertCondition, unreachable} from "./core/assert.js"
import {DEGREES_PER_HALF_TURN, DEGREES_PER_TURN, normalizedDegrees} from "./core/math/angles.js"
import {LAT, LON} from "./core/math/geodesy.js"
import {
  CorrectionKind,
  DrawnKind,
  PredictionKind,
  anchorReport,
  beginCorrection,
  drawCorrected,
  pathBearingDegrees,
  predictPosition,
  reportBefore,
  scheduledAnchor
} from "./vehicle_prediction.js"

/**
 * How a vehicle is drawn: predicted along its trip, scheduled along its
 * trip for a vehicle of the saved schedule, at its last report, or where the
 * fetch puts it.
 */
export const MotionPlanKind = Object.freeze({predicted: "predicted", scheduled: "scheduled", atReport: "atReport", asFetched: "asFetched"})

/** Whether a vehicle names a trip whose path the page asks for. */
export const PathTripKind = Object.freeze({trip: "trip", none: "none"})

/** Where a vehicle's marker stands: an estimate along its trip, its last report, or where the fetch puts it. */
export const MarkerPositionKind = Object.freeze({estimated: "estimated", lastReport: "lastReport", fetched: "fetched"})

// The statuses of `GobusgoWeb.VehicleMarkers` whose report places a marker.
const REPORTED_STATUS = "reported"
const STALE_STATUS = "stale"

const SETTLED = Object.freeze({kind: CorrectionKind.settled})
const NO_TRIP = Object.freeze({kind: PathTripKind.none})

/** Which way a vehicle's chevron points: along its path, or its reported heading. */
export const HeadingKind = Object.freeze({alongPath: "alongPath", reported: "reported"})

/** How long a chevron takes to turn back to its reported heading. */
export const HEADING_TURN_DURATION_MS = 1000

const REPORTED_HEADING = Object.freeze({kind: HeadingKind.reported})

/**
 * Which way the chevron of `tracked` points as it is drawn now: along its
 * trip's path at the distance it is drawn at, in degrees clockwise from
 * true north, for a predicted vehicle drawn along its path, and its
 * reported heading for any other.
 */
export function drawnHeading(tracked) {
  const isPredicted = tracked.plan.kind === MotionPlanKind.predicted
  const isAlongPath = isPredicted && tracked.drawn.kind === DrawnKind.alongPath

  if (!isAlongPath) {
    return REPORTED_HEADING
  }

  const degrees = pathBearingDegrees({path: tracked.path, meters: tracked.drawn.distanceMeters})
  return Object.freeze({kind: HeadingKind.alongPath, degrees})
}

// The signed turn from `source` to `target`, in degrees from -180 up to
// 180, clockwise positive: the shorter way round.
function signedTurnDegrees({source, target}) {
  const clockwise = normalizedDegrees(target - source)

  if (clockwise > DEGREES_PER_HALF_TURN) {
    return clockwise - DEGREES_PER_TURN
  }

  return clockwise
}

/**
 * Whether a chevron drawn at `source` turns to `target`, both in degrees
 * clockwise from north, rather than standing there at once: never under
 * reduced motion, and never where the two are one heading.
 */
export function headingTurns({source, target, reducedMotion}) {
  if (reducedMotion) {
    return false
  }

  return signedTurnDegrees({source, target}) !== 0
}

/**
 * The heading of a chevron turning from `source` to `target` `elapsedMs`
 * after its turn began, the shorter way round at an even pace over
 * `HEADING_TURN_DURATION_MS`, and whether the turn has ended.
 */
export function turnedHeading({source, target, elapsedMs}) {
  if (elapsedMs >= HEADING_TURN_DURATION_MS) {
    return {degrees: target, ended: true}
  }

  const fraction = Math.max(0, elapsedMs) / HEADING_TURN_DURATION_MS
  const turn = signedTurnDegrees({source, target})
  return {degrees: normalizedDegrees(source + turn * fraction), ended: false}
}

function reportOf(marker) {
  const {report, trip_id: tripId, service_date_ms: serviceDateMs} = marker
  return Object.freeze({position: Object.freeze([report.lon, report.lat]), reportedAtMs: report.time_ms, tripId, serviceDateMs})
}

function atPoint(position) {
  return Object.freeze({kind: DrawnKind.atPoint, position})
}

/**
 * How `marker`, as the server sends it or as the saved schedule places it,
 * is drawn: scheduled along its trip's path for a marker the saved schedule
 * places on a trip, predicted from its report for a reported vehicle on a
 * trip, at its report for a stale one or a reported one on no trip, and
 * where the fetch puts it otherwise.
 */
export function motionPlan(marker) {
  const isSavedSchedule = marker.is_saved_schedule === true
  const hasSavedTrip = typeof marker.trip_id === "string"
  const isScheduled = isSavedSchedule && hasSavedTrip

  if (isScheduled) {
    const {route_id: routeId, trip_id: tripId, service_date_ms: serviceDateMs} = marker
    const position = Object.freeze([marker.lon, marker.lat])
    return Object.freeze({kind: MotionPlanKind.scheduled, position, routeId, tripId, serviceDateMs})
  }

  const hasReport = marker.report !== null
  const hasTrip = typeof marker.trip_id === "string"
  const hasDate = Number.isSafeInteger(marker.service_date_ms)
  const isOnTrip = hasTrip && hasDate
  const isReported = marker.status === REPORTED_STATUS && hasReport
  const isPredicted = isReported && isOnTrip
  const isStale = marker.status === STALE_STATUS && hasReport
  const isAtReport = isReported || isStale

  if (isPredicted) {
    return Object.freeze({kind: MotionPlanKind.predicted, report: reportOf(marker), routeId: marker.route_id})
  }

  if (isAtReport) {
    return Object.freeze({kind: MotionPlanKind.atReport, position: Object.freeze([marker.report.lon, marker.report.lat])})
  }

  return Object.freeze({kind: MotionPlanKind.asFetched, position: Object.freeze([marker.lon, marker.lat])})
}

function predictedOf(tracked) {
  return tracked !== null && tracked.plan.kind === MotionPlanKind.predicted
}

// The state of a vehicle of the saved schedule after a placement, or after
// its path arrives, at `atMs`: with a path it is anchored at the schedule's
// distance along it, and with none it stands where the placement puts it. A
// vehicle drawn before meets the new anchor with a correction.
function scheduledVehicle({tracked, plan, path, atMs}) {
  if (path === null) {
    return Object.freeze({plan, path: null, previousReport: null, anchor: null, correction: SETTLED, drawn: atPoint(plan.position)})
  }

  const anchor = scheduledAnchor({path, atMs})
  const prediction = predictPosition({path, anchor, atMs})
  let correction = SETTLED

  if (tracked !== null) {
    correction = beginCorrection({drawn: tracked.drawn, prediction, atMs})
  }

  const drawn = drawCorrected({path, correction, prediction, atMs})
  return Object.freeze({plan, path, previousReport: null, anchor, correction, drawn})
}

/**
 * The state of a vehicle after a fetch gives `marker`, or after its path,
 * `path`, prepared, or null for none, arrives, at `atMs`. A new report or a
 * new path anchors the vehicle again, and a vehicle drawn before meets its
 * new prediction with a correction from where it was drawn; the same
 * report and path keep the anchor and the correction.
 */
export function trackedVehicle({tracked, marker, path, atMs}) {
  const plan = motionPlan(marker)

  if (plan.kind === MotionPlanKind.scheduled) {
    return scheduledVehicle({tracked, plan, path, atMs})
  }

  if (plan.kind !== MotionPlanKind.predicted) {
    return Object.freeze({plan, path: null, previousReport: null, anchor: null, correction: SETTLED, drawn: atPoint(plan.position)})
  }

  // The report the last is anchored against is the one `reportBefore`
  // gives from the reports held before it, or the one the vehicle was
  // anchored against when the fetch repeats the report.
  const lastReport = plan.report
  let isRepeated = false
  let previousReport = null

  if (predictedOf(tracked)) {
    isRepeated = tracked.plan.report.reportedAtMs === lastReport.reportedAtMs
    if (isRepeated) {
      previousReport = tracked.previousReport
    } else {
      previousReport = reportBefore({report: lastReport, lastReport: tracked.plan.report, previousReport: tracked.previousReport})
    }
  }

  const isSamePath = tracked !== null && tracked.path === path
  const isKept = isRepeated && isSamePath

  if (isKept) {
    return Object.freeze({...tracked, plan})
  }

  const anchor = anchorReport({path, lastReport, previousReport})
  const prediction = predictPosition({path, anchor, atMs})
  let correction = SETTLED

  if (tracked !== null) {
    correction = beginCorrection({drawn: tracked.drawn, prediction, atMs})
  }

  const drawn = drawCorrected({path, correction, prediction, atMs})
  return Object.freeze({plan, path, previousReport, anchor, correction, drawn})
}

/** The state of a vehicle drawn at `atMs`, with `drawn` where it stands then. */
export function drawnVehicle({tracked, atMs}) {
  if (tracked.anchor === null) {
    return tracked
  }

  const prediction = predictPosition({path: tracked.path, anchor: tracked.anchor, atMs})
  const drawn = drawCorrected({path: tracked.path, correction: tracked.correction, prediction, atMs})
  return Object.freeze({...tracked, drawn})
}

/**
 * The state of a vehicle a fetch places in the map's source at `atMs`: at
 * its prediction then, with no correction, since the source glides it
 * there from where it stood.
 */
export function placedAtFetch({tracked, atMs}) {
  if (tracked.anchor === null) {
    return tracked
  }

  const prediction = predictPosition({path: tracked.path, anchor: tracked.anchor, atMs})
  const drawn = drawCorrected({path: tracked.path, correction: SETTLED, prediction, atMs})
  return Object.freeze({...tracked, correction: SETTLED, drawn})
}

function isSamePosition(source, target) {
  const isSameLon = source[LON] === target[LON]
  const isSameLat = source[LAT] === target[LAT]
  const isSame = isSameLon && isSameLat
  return isSame
}

/**
 * The state of a vehicle the source draws at `sourcePosition` that moves
 * onto the canvas at `atMs`: it starts where the source drew it, along its
 * path where that is the drawn prediction, and meets the prediction of
 * `atMs` with a correction from there.
 */
export function resumedOnCanvas({tracked, sourcePosition, atMs}) {
  if (tracked.anchor === null) {
    return tracked
  }

  let drawn = atPoint(sourcePosition)

  if (isSamePosition(tracked.drawn.position, sourcePosition)) {
    drawn = tracked.drawn
  }

  const prediction = predictPosition({path: tracked.path, anchor: tracked.anchor, atMs})
  const correction = beginCorrection({drawn, prediction, atMs})
  const resumed = Object.freeze({...tracked, correction, drawn})
  return drawnVehicle({tracked: resumed, atMs})
}

/**
 * Whether the vehicle moves between fetches: a predicted one along its
 * path, and a scheduled one along the path its schedule gives.
 */
export function isAnimated(tracked) {
  const isAnchored = tracked.anchor !== null
  const isAlongPath = isAnchored && tracked.anchor.kind === PredictionKind.alongPath
  return isAlongPath
}

/**
 * Where the marker of `tracked` stands: an estimate for a vehicle predicted
 * along its path, its last report for one drawn there, and where the fetch
 * puts it for any other.
 */
export function markerPositionKind(tracked) {
  switch (tracked.plan.kind) {
    case MotionPlanKind.predicted:
      if (isAnimated(tracked)) {
        return MarkerPositionKind.estimated
      }
      return MarkerPositionKind.lastReport
    case MotionPlanKind.atReport:
      return MarkerPositionKind.lastReport
    case MotionPlanKind.scheduled:
    case MotionPlanKind.asFetched:
      return MarkerPositionKind.fetched
    default:
      return unreachable(tracked.plan.kind, "a plan of no kind")
  }
}

function scheduledPathTrip({routeId, tripId, serviceDateMs}) {
  const hasRoute = typeof routeId === "string" && routeId !== ""
  const hasDate = Number.isSafeInteger(serviceDateMs)
  const isNamed = hasRoute && hasDate

  if (!isNamed) {
    return NO_TRIP
  }

  const trip = Object.freeze({tripId, routeId, serviceDateMs})
  return Object.freeze({kind: PathTripKind.trip, trip})
}

/**
 * The trip whose path a predicted or scheduled vehicle is drawn along, with
 * its `tripId`, `routeId`, and `serviceDateMs`, or none for a vehicle that
 * is neither, names no route, or is scheduled on a date whose snapshot is
 * not saved.
 */
export function pathTrip(tracked) {
  if (tracked.plan.kind === MotionPlanKind.scheduled) {
    return scheduledPathTrip(tracked.plan)
  }

  if (tracked.plan.kind !== MotionPlanKind.predicted) {
    return NO_TRIP
  }

  const {routeId, report} = tracked.plan
  const hasRoute = typeof routeId === "string" && routeId !== ""

  if (!hasRoute) {
    return NO_TRIP
  }

  assertCondition(typeof report.tripId === "string", "a predicted vehicle names its trip")
  const trip = Object.freeze({tripId: report.tripId, routeId, serviceDateMs: report.serviceDateMs})
  return Object.freeze({kind: PathTripKind.trip, trip})
}
