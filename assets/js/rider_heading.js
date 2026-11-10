// The rules of the cone on the rider's dot. Everything here is pure: the
// fix, the orientation event's fields, the screen's angle, the setting, and
// the time are given as values, so where the cone points, whether it is
// drawn again, and whether the motion permission is asked for are functions
// of them alone. Every heading here is in degrees clockwise from true
// north, the map's north.

import {assertCondition, unreachable} from "./assert.js"
import {FollowKind} from "./follow_state.js"
import {DEGREES_PER_HALF_TURN, DEGREES_PER_TURN, normalizedDegrees, turnDegrees} from "./math/angles.js"
import {MeasureKind} from "./position_watch.js"

/** The width of the cone, centered on the heading. */
export const CONE_WIDTH_DEGREES = 60

/** The speed from which a fix's GPS heading is the direction of travel. */
export const MOVING_SPEED_MPS_MIN = 1

/** The age past which a reading draws no cone. */
export const HEADING_AGE_MS_MAX = 10 * 1000

/** The turn since the cone was last drawn that draws it again. */
export const TURN_DEGREES_MIN = 2

/** How long a turn of the cone eases, where the browser does not ask for reduced motion. */
export const CONE_TURN_MS = 200

/**
 * Magnetic declination at Seattle, 47.6062° N 122.3321° W, east of true
 * north: 14.86° ± 0.39° on 2026-11-08 by the World Magnetic Model of 2025,
 * from NOAA's declination calculator. The map covers Puget Sound alone, across which
 * the declination varies by well under the cone's width.
 * https://www.ngdc.noaa.gov/geomag/calculators/magcalc.shtml — checked 2026-11-08
 */
export const SEATTLE_DECLINATION_DEGREES = 14.86

/** Whether a source gave a heading. */
export const ReadingKind = Object.freeze({measured: "measured", none: "none"})

/** The source a drawn cone follows. */
export const HeadingSource = Object.freeze({gps: "gps", compass: "compass"})

/**
 * Which orientation event gives the compass: Chrome's absolute event, or
 * Safari's `deviceorientation` with its compass heading.
 */
export const CompassSource = Object.freeze({absolute: "absolute", webkit: "webkit"})

/** No heading. */
export const NO_READING = Object.freeze({kind: ReadingKind.none})

const compassSources = Object.values(CompassSource)
const followKinds = Object.values(FollowKind)

function isFiniteNumber(value) {
  const isNumber = typeof value === "number"
  const isFiniteValue = isNumber && Number.isFinite(value)
  return isFiniteValue
}

// Both compasses of the browsers read magnetic north, which lies east of
// true north by the declination.
function trueOfMagnetic(magneticDegrees) {
  return normalizedDegrees(magneticDegrees + SEATTLE_DECLINATION_DEGREES)
}

function measured({degrees, timeMs}) {
  assertCondition(Number.isFinite(degrees), `rider heading: a heading of ${degrees}`)
  assertCondition(Number.isFinite(timeMs), `rider heading: a reading time of ${timeMs}`)
  return Object.freeze({kind: ReadingKind.measured, degrees: normalizedDegrees(degrees), timeMs})
}

/**
 * The GPS reading of a fix of the position watch: its heading, the
 * direction of travel, while its speed is at least the moving bound, and
 * none otherwise.
 */
export function gpsReading(fix) {
  const hasHeading = fix.heading.kind === MeasureKind.measured
  const hasSpeed = fix.speed.kind === MeasureKind.measured
  const hasBoth = hasHeading && hasSpeed

  if (!hasBoth) {
    return NO_READING
  }

  if (fix.speed.value < MOVING_SPEED_MPS_MIN) {
    return NO_READING
  }

  return measured({degrees: fix.heading.value, timeMs: fix.timeMs})
}

/** Which orientation event gives the compass in a browser that has, or lacks, the absolute event. */
export function compassSourceOf({hasAbsoluteEvent}) {
  if (hasAbsoluteEvent) {
    return CompassSource.absolute
  }

  return CompassSource.webkit
}

// WebKit's compass heading is CLHeading's magneticHeading, in degrees
// clockwise from magnetic north, and it sends an accuracy of -1 with a
// heading of 0 while no heading is available.
// https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/ios/WebCoreMotionManager.mm — checked 2026-11-08
function webkitReading({event, timeMs}) {
  const hasHeading = isFiniteNumber(event.webkitCompassHeading)
  const hasAccuracy = isFiniteNumber(event.webkitCompassAccuracy)
  const hasBoth = hasHeading && hasAccuracy

  if (!hasBoth) {
    return NO_READING
  }

  if (event.webkitCompassAccuracy < 0) {
    return NO_READING
  }

  return measured({degrees: trueOfMagnetic(event.webkitCompassHeading), timeMs})
}

// Alpha turns counterclockwise about the screen's normal, so the device's
// top points 360 - alpha clockwise from north, and the screen's angle, how
// far the screen is turned counterclockwise from its natural orientation,
// turns the top of what the rider sees that much clockwise from the
// device's top. Chrome on Android backs the absolute event with
// TYPE_ROTATION_VECTOR, whose Y axis points to magnetic north, or with the
// accelerometer and the magnetometer.
// https://w3c.github.io/screen-orientation/#dfn-current-orientation-angle — checked 2026-11-08
// https://developer.android.com/reference/android/hardware/SensorEvent#values — checked 2026-11-08
// https://github.com/chromium/chromium/blob/main/services/device/generic_sensor/platform_sensor_provider_android.cc — checked 2026-11-08
function absoluteReading({event, screenAngle, timeMs}) {
  const hasAlpha = isFiniteNumber(event.alpha)
  const isAbsoluteAlpha = hasAlpha && event.absolute === true

  if (!isAbsoluteAlpha) {
    return NO_READING
  }

  assertCondition(Number.isFinite(screenAngle), `rider heading: a screen angle of ${screenAngle}`)
  const magneticDegrees = DEGREES_PER_TURN - event.alpha + screenAngle
  return measured({degrees: trueOfMagnetic(magneticDegrees), timeMs})
}

/**
 * The compass reading of an orientation event's fields from `source`, with
 * the screen's orientation angle and the time it arrived, corrected to true
 * north; none where the event holds no heading.
 */
export function compassReading({source, event, screenAngle, timeMs}) {
  assertCondition(compassSources.includes(source), `rider heading: a compass source of ${String(source)}`)

  switch (source) {
    case CompassSource.webkit:
      return webkitReading({event, timeMs})
    case CompassSource.absolute:
      return absoluteReading({event, screenAngle, timeMs})
    default:
      return unreachable(source, "rider heading: a compass source of unknown kind")
  }
}

function isFresh({reading, nowMs}) {
  if (reading.kind === ReadingKind.none) {
    return false
  }

  return nowMs - reading.timeMs <= HEADING_AGE_MS_MAX
}

function coneOf({reading, source}) {
  return Object.freeze({
    kind: ReadingKind.measured,
    degrees: reading.degrees,
    source,
    expiresAtMs: reading.timeMs + HEADING_AGE_MS_MAX
  })
}

/**
 * Where the cone points at `nowMs`: along the GPS heading while it is
 * fresh, else along the compass while it is fresh, else nowhere, and
 * nowhere while the setting is off. A cone names the time its reading
 * grows too old.
 */
export function coneHeading({gps, compass, isShown, nowMs}) {
  if (!isShown) {
    return NO_READING
  }

  if (isFresh({reading: gps, nowMs})) {
    return coneOf({reading: gps, source: HeadingSource.gps})
  }

  if (isFresh({reading: compass, nowMs})) {
    return coneOf({reading: compass, source: HeadingSource.compass})
  }

  return NO_READING
}

/**
 * Whether the cone is drawn again: when it appears or goes, and when its
 * heading has turned at least the threshold either way since `drawn`.
 */
export function isRedrawn({drawn, heading}) {
  const isSameKind = drawn.kind === heading.kind

  if (!isSameKind) {
    return true
  }

  if (heading.kind === ReadingKind.none) {
    return false
  }

  return turnDegrees({from: drawn.degrees, to: heading.degrees}) >= TURN_DEGREES_MIN
}

/**
 * The rotation that points the cone at `degrees` from its present
 * `rotation`, by the shorter way round, so that an eased turn across north
 * takes a few degrees rather than nearly a whole turn. A half turn goes
 * clockwise.
 */
export function turnedRotation({rotation, degrees}) {
  assertCondition(Number.isFinite(rotation), `rider heading: a rotation of ${rotation}`)
  const clockwise = normalizedDegrees(degrees - rotation)
  let turn = clockwise

  if (clockwise > DEGREES_PER_HALF_TURN) {
    turn = clockwise - DEGREES_PER_TURN
  }

  return rotation + turn
}

/** How long a turn of the cone lasts: none where the browser asks for reduced motion. */
export function coneTurnMs({reducedMotion}) {
  if (reducedMotion) {
    return 0
  }

  return CONE_TURN_MS
}

/** Whether the orientation listener runs: while the dot is drawn, the page is visible, and the setting is on. */
export function listensOrientation({isDotDrawn, isVisible, isShown}) {
  const isDrawnVisible = isDotDrawn && isVisible
  const listens = isDrawnVisible && isShown
  return listens
}

/**
 * Whether a click on the location button asks for the motion permission:
 * a click that moves Off to Following, with the setting on, no denial
 * stored, and a browser that asks.
 */
export function asksMotionPermission({previousKind, nextKind, isShown, isDenied, canRequest}) {
  assertCondition(followKinds.includes(previousKind), `rider heading: a state of kind ${String(previousKind)}`)
  assertCondition(followKinds.includes(nextKind), `rider heading: a state of kind ${String(nextKind)}`)
  const isStart = previousKind === FollowKind.off
  const isStartFollowing = isStart && nextKind === FollowKind.following
  const isAskable = canRequest && !isDenied
  const isShownAskable = isShown && isAskable
  const asks = isStartFollowing && isShownAskable
  return asks
}
