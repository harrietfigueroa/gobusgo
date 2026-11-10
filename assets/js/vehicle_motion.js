// How the vehicle page follows each vehicle between fetches, as pure
// functions of the marker the server sends, the trip's prepared path or
// none, the previous state, and the time on the source's clock in
// milliseconds. A vehicle is predicted along its path, drawn at its last
// report, or drawn where the fetch puts it, by its status: only a reported
// vehicle on a trip moves. Each state is a frozen value the page
// keeps, and each function returns another.

import {assertCondition, unreachable} from "./assert.js"
import {LAT, LON} from "./math/geodesy.js"
import {
  CorrectionKind,
  DrawnKind,
  PredictionKind,
  anchorReport,
  beginCorrection,
  drawCorrected,
  predictPosition
} from "./vehicle_prediction.js"

/** How a vehicle is drawn: predicted along its trip, at its last report, or where the fetch puts it. */
export const MotionPlanKind = Object.freeze({predicted: "predicted", atReport: "atReport", asFetched: "asFetched"})

/** Whether a vehicle names a trip whose path the page asks for. */
export const PathTripKind = Object.freeze({trip: "trip", none: "none"})

/** Where a vehicle's marker stands: an estimate along its trip, its last report, or where the fetch puts it. */
export const MarkerPositionKind = Object.freeze({estimated: "estimated", lastReport: "lastReport", fetched: "fetched"})

// The statuses of `GobusgoWeb.VehicleMarkers` whose report places a marker.
const REPORTED_STATUS = "reported"
const STALE_STATUS = "stale"

const SETTLED = Object.freeze({kind: CorrectionKind.settled})
const NO_TRIP = Object.freeze({kind: PathTripKind.none})

function reportOf(marker) {
  const {report, trip_id: tripId, service_date_ms: serviceDateMs} = marker
  return Object.freeze({position: Object.freeze([report.lon, report.lat]), reportedAtMs: report.time_ms, tripId, serviceDateMs})
}

function atPoint(position) {
  return Object.freeze({kind: DrawnKind.atPoint, position})
}

/**
 * How `marker`, as the server sends it, is drawn: predicted from its
 * report for a reported vehicle on a trip, at its report for a stale one
 * or a reported one on no trip, and where the fetch puts it otherwise.
 */
export function motionPlan(marker) {
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

/**
 * The state of a vehicle after a fetch gives `marker`, or after its path,
 * `path`, prepared, or null for none, arrives, at `atMs`. A new report or a
 * new path anchors the vehicle again, and a vehicle drawn before meets its
 * new prediction with a correction from where it was drawn; the same
 * report and path keep the anchor and the correction.
 */
export function trackedVehicle({tracked, marker, path, atMs}) {
  const plan = motionPlan(marker)

  if (plan.kind !== MotionPlanKind.predicted) {
    return Object.freeze({plan, path: null, previousReport: null, anchor: null, correction: SETTLED, drawn: atPoint(plan.position)})
  }

  // The report before the last is the one held before it, or the one held
  // before that when the fetch repeats the report.
  const lastReport = plan.report
  let isRepeated = false
  let previousReport = null

  if (predictedOf(tracked)) {
    isRepeated = tracked.plan.report.reportedAtMs === lastReport.reportedAtMs
    previousReport = tracked.plan.report

    if (isRepeated) {
      previousReport = tracked.previousReport
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
  if (tracked.plan.kind !== MotionPlanKind.predicted) {
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
  if (tracked.plan.kind !== MotionPlanKind.predicted) {
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
  if (tracked.plan.kind !== MotionPlanKind.predicted) {
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

/** Whether the vehicle moves between fetches: a predicted one along its path. */
export function isAnimated(tracked) {
  const isPredicted = tracked.plan.kind === MotionPlanKind.predicted
  const isAlongPath = isPredicted && tracked.anchor.kind === PredictionKind.alongPath
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
    case MotionPlanKind.asFetched:
      return MarkerPositionKind.fetched
    default:
      return unreachable(tracked.plan.kind, "a plan of no kind")
  }
}

/**
 * The trip whose path a predicted vehicle is drawn along, with its
 * `tripId`, `routeId`, and `serviceDateMs`, or none for a vehicle that is
 * not predicted or names no route.
 */
export function pathTrip(tracked) {
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
