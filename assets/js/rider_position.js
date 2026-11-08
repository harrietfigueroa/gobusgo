// The page's one watch of the rider's position. A part of the page takes the
// watch under a holder's name and lets it go; the watch runs while some
// holder holds it and the page is visible, and stops for every holder when
// the permission is denied, until a holder takes it again. Each holder is
// handed every outcome as a frozen plain value, a fix or why there is none,
// never the browser's own position object. A holder that joins a running
// watch reads the latest fix on demand.
//
// The position never leaves the browser: this module sends the server no
// event, makes no request, and stores nothing. The latest fix lives in this
// module's memory alone, for as long as the page.

import {assertCondition, unreachable} from "./assert"
import {
  NO_FIX,
  OutcomeKind,
  PermissionKind,
  WATCH_OPTIONS,
  WatchAction,
  errorOutcome,
  fixOf,
  freshFix,
  permissionOf,
  watchAction,
  withHolder,
  withoutHolder
} from "./position_watch"

/** The holder name of the trip panel's My location start. */
export const TRIP_HOLDER = "trip"

const WatchKind = Object.freeze({idle: "idle", watching: "watching"})
const IDLE = Object.freeze({kind: WatchKind.idle})
const UNAVAILABLE = Object.freeze({kind: OutcomeKind.unavailable})

// The listener of each holder, by holder name.
const listeners = new Map()
let watch = IDLE
let permission = PermissionKind.prompt
let latest = NO_FIX
// Counts the watches started, so a callback of a watch already cleared
// hands nothing over.
let watchNumber = 0

function isVisible() {
  return document.visibilityState === "visible"
}

// Hands `outcome` to every holder. The listeners are copied first because a
// listener can let go of the watch while it is called.
function handOut(outcome) {
  const called = Array.from(listeners.values())

  for (const listener of called) {
    listener(outcome)
  }
}

function startWatch() {
  if (navigator.geolocation === undefined) {
    handOut(UNAVAILABLE)
    return
  }

  watchNumber += 1
  const number = watchNumber

  function located(position) {
    if (number !== watchNumber) {
      return
    }

    latest = fixOf(position)
    handOut(latest)
  }

  function failed(error) {
    if (number !== watchNumber) {
      return
    }

    const outcome = errorOutcome(error.code)

    if (outcome.kind === OutcomeKind.denied) {
      permission = PermissionKind.denied
      apply()
    }

    handOut(outcome)
  }

  const id = navigator.geolocation.watchPosition(located, failed, WATCH_OPTIONS)
  watch = {kind: WatchKind.watching, id}
}

function stopWatch() {
  assertCondition(watch.kind === WatchKind.watching, `rider position: a stop of a watch that is ${watch.kind}`)
  navigator.geolocation.clearWatch(watch.id)
  watchNumber += 1
  watch = IDLE
}

// Starts or stops the watch as its holders, the visibility, and the
// permission now ask.
function apply() {
  const action = watchAction({
    isWatching: watch.kind === WatchKind.watching,
    holderCount: listeners.size,
    isVisible: isVisible(),
    permission
  })

  switch (action) {
    case WatchAction.start:
      startWatch()
      break
    case WatchAction.stop:
      stopWatch()
      break
    case WatchAction.keep:
      break
    default:
      unreachable(action, "rider position: a watch action of unknown kind")
  }
}

/**
 * Takes the watch for `holder` and hands `onOutcome` every outcome from now
 * on, in place of any listener the holder had. Taking it again after a
 * denial asks the browser again.
 */
export function holdPosition({holder, onOutcome}) {
  assertCondition(typeof onOutcome === "function", `rider position: a listener of ${String(onOutcome)} for ${holder}`)
  const held = withHolder({holders: listeners.keys(), holder})
  const isFirst = listeners.size === 0
  listeners.set(holder, onOutcome)
  assertCondition(held.size === listeners.size, `rider position: ${listeners.size} listeners for ${held.size} holders`)

  if (isFirst) {
    document.addEventListener("visibilitychange", apply)
  }

  permission = PermissionKind.prompt
  apply()
}

/** Lets go of the watch for `holder`; a holder that holds nothing changes nothing. */
export function releasePosition({holder}) {
  const held = withoutHolder({holders: listeners.keys(), holder})
  const wasHeld = listeners.delete(holder)
  assertCondition(held.size === listeners.size, `rider position: ${listeners.size} listeners for ${held.size} holders`)

  if (!wasHeld) {
    return
  }

  apply()

  if (listeners.size === 0) {
    document.removeEventListener("visibilitychange", apply)
  }
}

/** The latest fix while it is younger than the age bound, or none. */
export function latestFix() {
  return freshFix({latest, nowMs: Date.now()})
}

/**
 * Whether the browser gives a position with no prompt, which is what lets a
 * page load start the watch. A browser without the Permissions API, and one
 * that refuses the query, reads as one that prompts.
 */
export async function permissionGranted() {
  if (navigator.permissions === undefined) {
    return false
  }

  try {
    const status = await navigator.permissions.query({name: "geolocation"})
    return permissionOf(status.state) === PermissionKind.granted
  } catch (error) {
    console.warn("Location permission not readable", error)
    return false
  }
}
