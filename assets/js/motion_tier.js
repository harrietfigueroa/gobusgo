// When the vehicle page moves its markers continuously, and how often it
// updates them while it does, as pure functions of the map's zoom, the
// count of vehicles in view, the reduced-motion preference, whether the
// page is shown, the tier decided before, and the settings the server hands
// the page. The settings carry every value of the band, so nothing here
// names a zoom, a rate, or a count of its own.

import {assertCondition, unreachable} from "./core/assert.js"
import {RATE_HZ_MAX, VEHICLE_COUNT_MAX} from "./vehicle_overlay_layout.js"

/** Whether the markers move continuously, and at what rate, or stand still between fetches. */
export const MotionTierKind = Object.freeze({animating: "animating", still: "still"})

/** The tier of a page whose markers stand still between fetches. */
export const STILL_TIER = Object.freeze({kind: MotionTierKind.still})

const HALF = 2

function assertRates({rates, zoomMin, zoomMax}) {
  assertCondition(Array.isArray(rates), "the rates are a list")
  assertCondition(rates.length > 0, "the rates hold at least one step")
  let zoomBefore = -Infinity

  for (const {zoom, rateHz} of rates) {
    assertCondition(zoom >= zoomMin, `a rate's zoom ${zoom} is at or above the band's ${zoomMin}`)
    assertCondition(zoom < zoomMax, `a rate's zoom ${zoom} is below the band's ${zoomMax}`)
    assertCondition(zoom > zoomBefore, `a rate's zoom ${zoom} is above the step's before it, ${zoomBefore}`)
    assertCondition(Number.isSafeInteger(rateHz), `a rate ${rateHz} is a whole number of hertz`)
    assertCondition(rateHz >= 1, `a rate ${rateHz} is at least 1 Hz`)
    assertCondition(rateHz <= RATE_HZ_MAX, `a rate ${rateHz} is at most ${RATE_HZ_MAX} Hz`)
    zoomBefore = zoom
  }
}

function rateOf({zoom, rate_hz: rateHz}) {
  return Object.freeze({zoom, rateHz})
}

/**
 * The settings of the server's `data-motion` attribute, decoded: the band
 * `zoomMin` to below `zoomMax`, the `hysteresis` past each edge, the
 * `vehicleCountMax` in view, and the `rates`, each step's `zoom` and
 * `rateHz`, in ascending zoom. Settings the server would refuse are a
 * programmer error.
 */
export function motionSettingsOf({zoom_min: zoomMin, zoom_max: zoomMax, hysteresis, vehicle_count_max: vehicleCountMax, rates}) {
  assertCondition(Number.isFinite(zoomMin), `the band's minimum ${zoomMin} is a number`)
  assertCondition(Number.isFinite(zoomMax), `the band's maximum ${zoomMax} is a number`)
  assertCondition(zoomMin < zoomMax, `the band's minimum ${zoomMin} is below its maximum ${zoomMax}`)
  assertCondition(hysteresis >= 0, `the hysteresis ${hysteresis} is at least 0`)
  assertCondition(hysteresis * HALF < zoomMax - zoomMin, `the hysteresis ${hysteresis} is under half the band`)
  assertCondition(Number.isSafeInteger(vehicleCountMax), `the cap ${vehicleCountMax} is a whole number`)
  assertCondition(vehicleCountMax >= 1, `the cap ${vehicleCountMax} is at least 1`)
  assertCondition(vehicleCountMax <= VEHICLE_COUNT_MAX, `the cap ${vehicleCountMax} is at most the canvas's ${VEHICLE_COUNT_MAX}`)
  assertCondition(Array.isArray(rates), "the rates are a list")
  const steps = Array.from(rates, rateOf)
  assertRates({rates: steps, zoomMin, zoomMax})
  return Object.freeze({zoomMin, zoomMax, hysteresis, vehicleCountMax, rates: Object.freeze(steps)})
}

// The rate of the last step whose zoom `zoom` has reached, or the first
// step's below every step, as inside the lower hysteresis.
function rateHzAt({rates, zoom}) {
  let rateHz = rates[0].rateHz

  for (const step of rates) {
    if (step.zoom <= zoom) {
      rateHz = step.rateHz
    }
  }

  return rateHz
}

// Whether `zoom` keeps motion going: inside the band for a still map, and
// up to the hysteresis past either edge for a running one.
function isZoomInBand({settings, zoom, isRunning}) {
  let margin = 0

  if (isRunning) {
    margin = settings.hysteresis
  }

  const isAboveFloor = zoom >= settings.zoomMin - margin
  const isBelowCeiling = zoom < settings.zoomMax + margin
  const isInBand = isAboveFloor && isBelowCeiling
  return isInBand
}

/**
 * The tier of a page at `zoom` with `vehicleCountInView` vehicles in view:
 * animating at the rate the settings give that zoom, or still. A still
 * page starts inside the band, and a running one, `previous`, keeps going
 * to the hysteresis past each edge. More vehicles in view than the cap,
 * reduced motion, and a hidden page are still.
 */
export function motionTier({settings, zoom, vehicleCountInView, isReducedMotion, isVisible, previous}) {
  assertCondition(Number.isFinite(zoom), `a zoom ${zoom} is a number`)
  assertCondition(Number.isSafeInteger(vehicleCountInView), `a count ${vehicleCountInView} is a whole number`)
  assertCondition(vehicleCountInView >= 0, `a count ${vehicleCountInView} is at least 0`)
  let isRunning = false

  switch (previous.kind) {
    case MotionTierKind.animating:
      isRunning = true
      break
    case MotionTierKind.still:
      break
    default:
      unreachable(previous.kind, "a tier of no kind")
  }

  const isAllowed = isVisible && !isReducedMotion
  const isCounted = vehicleCountInView <= settings.vehicleCountMax
  const isPermitted = isAllowed && isCounted
  const isInBand = isZoomInBand({settings, zoom, isRunning})
  const isAnimating = isPermitted && isInBand

  if (isAnimating) {
    const rateHz = rateHzAt({rates: settings.rates, zoom})
    return Object.freeze({kind: MotionTierKind.animating, rateHz})
  }

  return STILL_TIER
}

function assertBounds({west, south, east, north}) {
  assertCondition(west <= east, `the bounds' west ${west} is at or west of their east ${east}`)
  assertCondition(south <= north, `the bounds' south ${south} is at or south of their north ${north}`)
}

function isInside({position: [lon, lat], bounds: {west, south, east, north}}) {
  const isWithinLon = lon >= west && lon <= east
  const isWithinLat = lat >= south && lat <= north
  const isWithin = isWithinLon && isWithinLat
  return isWithin
}

/** Whether `position`, [lon, lat], stands inside `bounds`, `{west, south, east, north}`, its edges included. */
export function isPositionInBounds({position, bounds}) {
  assertBounds(bounds)
  return isInside({position, bounds})
}

/**
 * The identifiers of `positions`, a map of marker identifiers to [lon, lat],
 * whose positions stand inside `bounds`, `{west, south, east, north}`, its
 * edges included, in the map's order.
 */
export function markerIdsInBounds({positions, bounds}) {
  assertBounds(bounds)
  const inside = []

  for (const [markerId, position] of positions) {
    if (isInside({position, bounds})) {
      inside.push(markerId)
    }
  }

  return inside
}
