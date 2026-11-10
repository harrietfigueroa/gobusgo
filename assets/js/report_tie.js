// The tie between a vehicle's last report and its marker, as pure functions
// of the vehicle's state between fetches: a ring at the report, and a line
// from the ring along the trip's path to where the marker is drawn. Which
// vehicles show one is decided here too. Positions are [lon, lat].

import {assertCondition} from "./assert.js"
import {pointsBetween} from "./math/polyline.js"
import {DrawnKind} from "./vehicle_prediction.js"
import {isAnimated} from "./vehicle_motion.js"

/** Whether a vehicle has a tie to draw. */
export const TieKind = Object.freeze({tie: "tie", none: "none"})

const NO_TIE = Object.freeze({kind: TieKind.none})

// A tie's line holds its ring and at least the two ends of its stretch of
// the path.
const LINE_POINT_COUNT_MIN = 3

// The points of `path` from `fromMeters` to `toMeters` along it, in that
// order, whichever is farther along.
function stretchOf({path, fromMeters, toMeters}) {
  if (toMeters >= fromMeters) {
    return pointsBetween({coordinates: path.coordinates, cumulative: path.cumulativeMeters, from: fromMeters, to: toMeters})
  }

  const backward = pointsBetween({coordinates: path.coordinates, cumulative: path.cumulativeMeters, from: toMeters, to: fromMeters})
  return backward.toReversed()
}

/**
 * The tie of `tracked`, a vehicle's state as it is drawn now: for a vehicle
 * predicted along its trip's path and drawn on it, a ring at its last
 * report and a line from the ring onto the path where the report projects,
 * then along the path to the marker, behind or ahead of the report. Any
 * other vehicle, a stale one or one gliding onto its path among them, has
 * none.
 */
export function reportTie(tracked) {
  const isAlongPath = isAnimated(tracked)
  const isDrawnAlong = isAlongPath && tracked.drawn.kind === DrawnKind.alongPath

  if (!isDrawnAlong) {
    return NO_TIE
  }

  const {anchor, drawn, path} = tracked
  const ring = anchor.position
  const along = stretchOf({path, fromMeters: anchor.distanceMeters, toMeters: drawn.distanceMeters})
  const line = [ring]

  for (const point of along) {
    line.push(point)
  }

  assertCondition(line.length >= LINE_POINT_COUNT_MIN, `a tie's line holds the ring and two points of its path, got: ${line.length}`)
  return Object.freeze({kind: TieKind.tie, ring, line})
}

/**
 * The identifiers of the vehicles whose ties are drawn: every one of
 * `inView` while `isBandShown`, the band of zoom inside which the vehicles
 * in view show them, and the selected one, `selectedId` or null, wherever
 * it is. Each is named once, in view order with the selected one last.
 */
export function tiedMarkerIds({inView, isBandShown, selectedId}) {
  const ids = []

  if (isBandShown) {
    for (const markerId of inView) {
      ids.push(markerId)
    }
  }

  const isSelected = selectedId !== null
  const isSelectedAdded = isSelected && !ids.includes(selectedId)

  if (isSelectedAdded) {
    ids.push(selectedId)
  }

  return ids
}
