// The rules of the rider's position watch. Everything here is pure: the
// holders, the visibility, the permission, the browser's position, and the
// time are given as values, so whether the watch runs and what a holder is
// handed are functions of them alone.

import {assertCondition} from "./core/assert.js"

// High accuracy is what makes the browser use GPS, and GPS is what gives a
// heading while moving. A fix the browser holds that is at most
// `maximumAge` old is handed over at once.
const HIGH_ACCURACY = true
const WATCH_FIX_AGE_MS_MAX = 5 * 1000
const WATCH_TIMEOUT_MS = 10 * 1000

/** The options the page's one `watchPosition` call asks with. */
export const WATCH_OPTIONS = Object.freeze({enableHighAccuracy: HIGH_ACCURACY, maximumAge: WATCH_FIX_AGE_MS_MAX, timeout: WATCH_TIMEOUT_MS})

/** The age up to which the latest fix is readable on demand. */
export const FIX_AGE_MS_MAX = 30 * 1000

// GeolocationPositionError names code 1 PERMISSION_DENIED, 2
// POSITION_UNAVAILABLE, and 3 TIMEOUT.
// https://developer.mozilla.org/en-US/docs/Web/API/GeolocationPositionError/code — checked 2026-11-08
const PERMISSION_DENIED_CODE = 1
const TIMEOUT_CODE = 3

/** Whether the browser gives a position with no prompt, refuses one, or asks. */
export const PermissionKind = Object.freeze({granted: "granted", prompt: "prompt", denied: "denied"})

/** What the watch hands its holders: a fix, or why there is none. */
export const OutcomeKind = Object.freeze({fix: "fix", denied: "denied", unavailable: "unavailable", timedOut: "timedOut"})

/** Whether a heading or a speed came with a fix. */
export const MeasureKind = Object.freeze({measured: "measured", none: "none"})

/** Whether an on-demand read finds a fix young enough to use. */
export const LatestKind = Object.freeze({fresh: "fresh", none: "none"})

/** What the watch does after a change of its holders, visibility, or permission. */
export const WatchAction = Object.freeze({start: "start", stop: "stop", keep: "keep"})

/** The latest fix before the watch has handed over any. */
export const NO_FIX = Object.freeze({kind: LatestKind.none})

const NO_MEASURE = Object.freeze({kind: MeasureKind.none})
const permissionKinds = Object.values(PermissionKind)

/** `holders` with `holder`, a name such as "trip", added once. */
export function withHolder({holders, holder}) {
  assertCondition(typeof holder === "string", `position watch: a holder named ${String(holder)}`)
  assertCondition(holder.length > 0, "position watch: a holder with an empty name")
  const held = new Set(holders)
  held.add(holder)
  return held
}

/** `holders` without `holder`; a name that holds nothing leaves them as they are. */
export function withoutHolder({holders, holder}) {
  const held = new Set(holders)
  held.delete(holder)
  return held
}

/**
 * Whether the watch starts, stops, or stays as it is. It runs while some
 * holder holds it, the page is visible, and the permission is not denied.
 */
export function watchAction({isWatching, holderCount, isVisible, permission}) {
  assertCondition(Number.isSafeInteger(holderCount), `position watch: a holder count of ${holderCount}`)
  assertCondition(holderCount >= 0, `position watch: a holder count of ${holderCount}`)
  assertCondition(permissionKinds.includes(permission), `position watch: a permission of ${String(permission)}`)

  const isHeld = holderCount > 0
  const isAllowed = permission !== PermissionKind.denied
  const isHeldVisible = isHeld && isVisible
  const runs = isHeldVisible && isAllowed

  if (runs === isWatching) {
    return WatchAction.keep
  } else if (runs) {
    return WatchAction.start
  } else {
    return WatchAction.stop
  }
}

/**
 * The outcome of a GeolocationPositionError's `code`. A code the
 * specification does not name reads as a position that is unavailable.
 */
export function errorOutcome(code) {
  if (code === PERMISSION_DENIED_CODE) {
    return {kind: OutcomeKind.denied}
  } else if (code === TIMEOUT_CODE) {
    return {kind: OutcomeKind.timedOut}
  } else {
    return {kind: OutcomeKind.unavailable}
  }
}

/**
 * The permission a Permissions API `state` reads as. A browser without the
 * API, and a state it does not name, read as one that prompts.
 */
export function permissionOf(state) {
  if (state === PermissionKind.granted) {
    return PermissionKind.granted
  } else if (state === PermissionKind.denied) {
    return PermissionKind.denied
  } else {
    return PermissionKind.prompt
  }
}

function measureOf(value) {
  const isNumber = typeof value === "number"
  const isMeasured = isNumber && Number.isFinite(value)

  if (isMeasured) {
    return Object.freeze({kind: MeasureKind.measured, value})
  }

  return NO_MEASURE
}

/**
 * The fix outcome of a GeolocationPosition, copied to a frozen plain value:
 * latitude and longitude in degrees, accuracy in meters, heading in degrees
 * clockwise from true north and speed in meters per second where the
 * browser gives them, and the fix's time in milliseconds since the epoch.
 * GeolocationCoordinates.heading is null when speed is 0 or the device
 * gives no heading, and some browsers give NaN there instead.
 * https://developer.mozilla.org/en-US/docs/Web/API/GeolocationCoordinates/heading — checked 2026-11-08
 */
export function fixOf(position) {
  const {latitude, longitude, accuracy, heading, speed} = position.coords
  assertCondition(Number.isFinite(latitude), `position watch: a latitude of ${latitude}`)
  assertCondition(Number.isFinite(longitude), `position watch: a longitude of ${longitude}`)
  assertCondition(Number.isFinite(position.timestamp), `position watch: a fix time of ${position.timestamp}`)

  const fix = Object.freeze({
    latitude,
    longitude,
    accuracyM: accuracy,
    heading: measureOf(heading),
    speed: measureOf(speed),
    timeMs: position.timestamp
  })

  return Object.freeze({kind: OutcomeKind.fix, fix})
}

/** The fix of `latest` while it is younger than the age bound at `nowMs`. */
export function freshFix({latest, nowMs}) {
  if (latest.kind === LatestKind.none) {
    return NO_FIX
  }

  assertCondition(latest.kind === OutcomeKind.fix, `position watch: a latest fix of kind ${latest.kind}`)
  const ageMs = nowMs - latest.fix.timeMs

  if (ageMs < FIX_AGE_MS_MAX) {
    return {kind: LatestKind.fresh, fix: latest.fix}
  }

  return NO_FIX
}
