// The rules of the location button, and the launch decision the button and
// the trip panel share. Everything here is pure: the state, the event, the
// map's size, the sheet's insets, the dot's place on screen, the rider's
// stated intent, and the permission are given as values, so what the button
// does next, what it shows, whether the map moves, and what a page load does
// with the rider's location are functions of them alone.

import {assertCondition, unreachable} from "./core/assert.js"
import {radians} from "./core/math/angles.js"
import {EndKind} from "./core/trip_plan.js"
import {PermissionKind} from "./position_watch.js"

/**
 * How long a restore at launch waits for the browser's first answer, a fix
 * or why there is none, before the button falls back to resume. A browser
 * that shows no prompt outside a press answers nothing, and the rider then
 * presses the button to be asked.
 */
export const LAUNCH_WAIT_MS_MAX = 15 * 1000

/** A fix moves the map only when the dot stands farther than this from where the map keeps it. */
export const FOLLOW_DISTANCE_PIXELS_MAX = 24

/** The zoom the first fix of a follow centers the map at, at most. */
export const FOLLOW_ZOOM_MAX = 15

/** How long a follow move eases, where the browser does not ask for reduced motion. */
export const FOLLOW_EASE_MS = 500

// MapLibre draws the world as one 512 px tile at zoom 0, and a meter on the
// ground spans fewer pixels away from the equator by the cosine of the
// latitude.
const TILE_SIZE_PIXELS = 512
const EARTH_CIRCUMFERENCE_METERS = 40_075_016.686
const DIAMETER_PER_RADIUS = 2
const HALF = 2

/**
 * Off holds no watch; Following keeps the map on the dot; Located draws the
 * dot alone; resume holds no watch and keeps the flag after a restore the
 * browser did not answer in time; blocked follows a denial.
 */
export const FollowKind = Object.freeze({off: "off", following: "following", located: "located", resume: "resume", blocked: "blocked"})

/** Where the latest fix lies against the bounds of the whole archive. */
export const FixPlace = Object.freeze({none: "none", inside: "inside", outside: "outside"})

/** What reaches the button: a press, a load with the flag stored, an outcome of the watch, or a camera move it did not make. */
export const FollowEventKind = Object.freeze({
  click: "click",
  restore: "restore",
  launchTimeout: "launchTimeout",
  fix: "fix",
  failed: "failed",
  denied: "denied",
  cameraMove: "cameraMove",
  detailOpen: "detailOpen",
  vehicleFollow: "vehicleFollow"
})

/** What the button asks of the map and the notice after an event. */
export const EffectKind = Object.freeze({center: "center", follow: "follow", notice: "notice"})

/** The zoom a center move takes: the first fix's, or the zoom the rider left the map at. */
export const CenterZoom = Object.freeze({first: "first", kept: "kept"})

/** What a follow move decision says: leave the map, or move it by the keep point's offset. */
export const MoveKind = Object.freeze({stay: "stay", move: "move"})

/** The messages of the notice, which is a polite live region. */
export const NoticeMessage = Object.freeze({
  following: Object.freeze({headline: "Following your location", caption: "Move the map to stop."}),
  stopped: Object.freeze({headline: "Stopped following your location", caption: "Press the location button to follow again."}),
  denied: Object.freeze({headline: "Location is off", caption: "Allow location in your browser's settings. The map stays where it is."}),
  unavailable: Object.freeze({headline: "Can't find your location", caption: "The map stays where it is."}),
  outside: Object.freeze({headline: "You're outside this map", caption: "The map stays where it is."}),
  resume: Object.freeze({headline: "Your location is paused", caption: "Press the location button to follow it again."})
})

/** MapLibre's classes of its geolocate button, whose icons the button shows. */
export const ButtonClass = Object.freeze({
  none: "",
  waiting: "maplibregl-ctrl-geolocate-waiting",
  active: "maplibregl-ctrl-geolocate-active",
  activeError: "maplibregl-ctrl-geolocate-active-error",
  background: "maplibregl-ctrl-geolocate-background",
  backgroundError: "maplibregl-ctrl-geolocate-background-error"
})

/** Every class of `ButtonClass` that names one, which a button in another state drops. */
export const BUTTON_CLASS_NAMES = Object.freeze([
  ButtonClass.waiting,
  ButtonClass.active,
  ButtonClass.activeError,
  ButtonClass.background,
  ButtonClass.backgroundError
])

const Label = Object.freeze({
  follow: "Follow my location",
  stop: "Stop following my location",
  center: "Center on my location",
  resume: "Resume following my location"
})

/**
 * The state of a page before any press. `place` is where the latest fix
 * lies, `isCentered` whether a follow has centered the map on a fix yet,
 * `isStale` whether the latest outcome was a failure, `isNoticeOwed`
 * whether the rider pressed the button and has not yet been told the
 * outcome, and `isLaunchWaiting` whether a restore at launch still waits
 * for the browser's first answer.
 */
export const OFF = Object.freeze({
  kind: FollowKind.off,
  place: FixPlace.none,
  isCentered: false,
  isStale: false,
  isNoticeOwed: false,
  isLaunchWaiting: false
})

/** What a page load does: start from the rider's location, block the button, or leave it off. */
export const LaunchKind = Object.freeze({restore: "restore", blocked: "blocked", off: "off"})

/**
 * What the rider stored about using their location: on, off, or nothing
 * either way, which defers to a permission the browser reports as granted.
 */
export const LaunchIntent = Object.freeze({on: "on", off: "off", unstated: "unstated"})

const BLOCKED = Object.freeze({...OFF, kind: FollowKind.blocked})
const RESUME = Object.freeze({...OFF, kind: FollowKind.resume})
const STAY = Object.freeze({kind: MoveKind.stay})
const NO_EFFECTS = Object.freeze([])
const FOLLOW_EFFECT = Object.freeze({kind: EffectKind.follow})
const followKinds = Object.values(FollowKind)
const fixPlaces = Object.values(FixPlace)
const launchIntents = Object.values(LaunchIntent)
const permissionKinds = Object.values(PermissionKind)
const RESTORE_LAUNCH = Object.freeze({kind: LaunchKind.restore})
const BLOCKED_LAUNCH = Object.freeze({kind: LaunchKind.blocked})
const OFF_LAUNCH = Object.freeze({kind: LaunchKind.off})

function notice(message) {
  return {kind: EffectKind.notice, message}
}

function unchanged(state) {
  return {state, effects: NO_EFFECTS}
}

/** Whether the button holds the watch and draws the dot. */
export function isActive(state) {
  const isFollowing = state.kind === FollowKind.following
  const isOn = isFollowing || state.kind === FollowKind.located
  return isOn
}

/** Whether the flag that the rider left the button on stays stored: while the button is on, and in resume. */
export function keepsFlag(state) {
  const isResume = state.kind === FollowKind.resume
  const isKept = isActive(state) || isResume
  return isKept
}

/**
 * What a page load does with the rider's location, from the rider's stored
 * `intent`, the `permission` as the Permissions API reports it at load, and
 * whether this page already offered the restore. A denial blocks whenever
 * it is read. A stated intent restores unless the permission reads denied,
 * since WebKit reports a permission granted at a prompt as a prompt until
 * the page asks; an unstated one restores only on a granted permission, so
 * it never raises a prompt. A restore is offered once a page.
 */
export function launchDecision({intent, permission, isRestoreOffered}) {
  assertCondition(launchIntents.includes(intent), `follow state: a launch intent of ${String(intent)}`)
  assertCondition(permissionKinds.includes(permission), `follow state: a launch permission of ${String(permission)}`)
  assertCondition(typeof isRestoreOffered === "boolean", `follow state: a restore offered of ${String(isRestoreOffered)}`)

  if (permission === PermissionKind.denied) {
    return BLOCKED_LAUNCH
  }

  if (isRestoreOffered) {
    return OFF_LAUNCH
  }

  if (intent === LaunchIntent.on) {
    return RESTORE_LAUNCH
  }

  const isGrantedDefault = intent === LaunchIntent.unstated && permission === PermissionKind.granted

  if (isGrantedDefault) {
    return RESTORE_LAUNCH
  }

  return OFF_LAUNCH
}

/**
 * The trip panel's intent from the rider's recent trips, the most recent
 * first: a last trip that started from My location states it, and anything
 * else leaves it unstated.
 */
export function tripLaunchIntent({recentTrips}) {
  assertCondition(Array.isArray(recentTrips), `follow state: recent trips of ${String(recentTrips)}`)

  if (recentTrips.length === 0) {
    return LaunchIntent.unstated
  }

  const [latest] = recentTrips

  if (latest.from.kind === EndKind.location) {
    return LaunchIntent.on
  }

  return LaunchIntent.unstated
}

function onClick(state) {
  switch (state.kind) {
    case FollowKind.off:
      return {state: {...OFF, kind: FollowKind.following, isNoticeOwed: true}, effects: [notice(NoticeMessage.following)]}
    case FollowKind.following:
      return {state: OFF, effects: [notice(NoticeMessage.stopped)]}
    case FollowKind.located:
      return onClickLocated(state)
    case FollowKind.resume:
      return {state: {...OFF, kind: FollowKind.following, isNoticeOwed: true}, effects: [notice(NoticeMessage.following)]}
    case FollowKind.blocked:
      return unchanged(state)
    default:
      return unreachable(state.kind, "follow state: a click in a state of unknown kind")
  }
}

// A press in Located centers on the latest fix; one outside the archive
// leaves the map where it is and says why, and one with no fix waits for
// the next.
function onClickLocated(state) {
  if (state.place === FixPlace.outside) {
    return {state: {...state, isNoticeOwed: false}, effects: [notice(NoticeMessage.outside)]}
  }

  const isWaiting = state.place === FixPlace.none
  const followed = {...state, kind: FollowKind.following, isCentered: !isWaiting, isNoticeOwed: true}

  if (isWaiting) {
    return {state: followed, effects: [notice(NoticeMessage.following)]}
  }

  return {state: followed, effects: [{kind: EffectKind.center, zoom: CenterZoom.kept}, notice(NoticeMessage.following)]}
}

// The first fix of a follow centers the map; a later one asks the hook to
// move the map if the dot has strayed. A fix outside the archive leaves the
// map and stops following, said as the outcome a press is owed or else as
// the change of state.
function onFix({state, place}) {
  assertCondition(fixPlaces.includes(place), `follow state: a fix placed ${String(place)}`)
  const isStray = !isActive(state)

  if (isStray) {
    return unchanged(state)
  }

  const fixed = {...state, place, isStale: false, isNoticeOwed: false, isLaunchWaiting: false}

  if (state.kind === FollowKind.located) {
    return {state: fixed, effects: NO_EFFECTS}
  }

  if (place === FixPlace.outside) {
    let message = NoticeMessage.stopped

    if (state.isNoticeOwed) {
      message = NoticeMessage.outside
    }

    return {state: {...fixed, kind: FollowKind.located, isCentered: false}, effects: [notice(message)]}
  }

  if (state.isCentered) {
    return {state: fixed, effects: [FOLLOW_EFFECT]}
  }

  return {state: {...fixed, isCentered: true}, effects: [{kind: EffectKind.center, zoom: CenterZoom.first}]}
}

function onFailed(state) {
  const isStray = !isActive(state)

  if (isStray) {
    return unchanged(state)
  }

  const failed = {...state, isStale: true, isNoticeOwed: false, isLaunchWaiting: false}

  if (state.isNoticeOwed) {
    return {state: failed, effects: [notice(NoticeMessage.unavailable)]}
  }

  return {state: failed, effects: NO_EFFECTS}
}

function onDenied(state) {
  if (state.isNoticeOwed) {
    return {state: BLOCKED, effects: [notice(NoticeMessage.denied)]}
  }

  return {state: BLOCKED, effects: NO_EFFECTS}
}

// A camera move the button did not make, or an opened details view, ends a
// follow that has centered the map. Before the first fix the follow still
// waits, and the first fix centers the map whatever moved it meanwhile, as
// MapLibre's own control does in its waiting state.
function onFollowEnd(state) {
  const isFollowing = state.kind === FollowKind.following
  const isCenteredFollow = isFollowing && state.isCentered

  if (isCenteredFollow) {
    return {state: {...state, kind: FollowKind.located, isCentered: false}, effects: [notice(NoticeMessage.stopped)]}
  }

  return unchanged(state)
}

// A bus followed takes the map from the location follow, centered or still
// waiting for its first fix, and leaves the dot drawn. The bus follow's own
// notice says what the map follows, so this one writes none.
function onVehicleFollow(state) {
  const isFollowing = state.kind === FollowKind.following

  if (isFollowing) {
    return {state: {...state, kind: FollowKind.located, isCentered: false, isNoticeOwed: false, isLaunchWaiting: false}, effects: NO_EFFECTS}
  }

  return unchanged(state)
}

// A restore the browser has not answered by the launch wait falls back to
// resume, which keeps the flag and asks on the next press. A follow the
// rider pressed, and one already answered, wait on.
function onLaunchTimeout(state) {
  const isFollowing = state.kind === FollowKind.following
  const isUnanswered = isFollowing && state.isLaunchWaiting

  if (isUnanswered) {
    return {state: RESUME, effects: [notice(NoticeMessage.resume)]}
  }

  return unchanged(state)
}

/**
 * The state after `event` and what the hook does for it, in order: center
 * the map on the latest fix, move it if the dot has strayed, or write the
 * notice.
 */
export function transition({state, event}) {
  assertCondition(followKinds.includes(state.kind), `follow state: a state of kind ${String(state.kind)}`)

  switch (event.kind) {
    case FollowEventKind.click:
      return onClick(state)
    case FollowEventKind.restore:
      if (state.kind === FollowKind.off) {
        return {state: {...OFF, kind: FollowKind.following, isLaunchWaiting: true}, effects: NO_EFFECTS}
      }

      return unchanged(state)
    case FollowEventKind.launchTimeout:
      return onLaunchTimeout(state)
    case FollowEventKind.fix:
      return onFix({state, place: event.place})
    case FollowEventKind.failed:
      return onFailed(state)
    case FollowEventKind.denied:
      return onDenied(state)
    case FollowEventKind.cameraMove:
      return onFollowEnd(state)
    case FollowEventKind.detailOpen:
      return onFollowEnd(state)
    case FollowEventKind.vehicleFollow:
      return onVehicleFollow(state)
    default:
      return unreachable(event.kind, "follow state: an event of unknown kind")
  }
}

/** What the button says, whether it reads as pressed, whether it is disabled, and MapLibre's class for its icon. */
export function buttonOf(state) {
  switch (state.kind) {
    case FollowKind.off:
      return {label: Label.follow, pressed: false, disabled: false, className: ButtonClass.none}
    case FollowKind.following:
      return {label: Label.stop, pressed: true, disabled: false, className: followingClass(state)}
    case FollowKind.located:
      if (state.isStale) {
        return {label: Label.center, pressed: false, disabled: false, className: ButtonClass.backgroundError}
      }

      return {label: Label.center, pressed: false, disabled: false, className: ButtonClass.background}
    case FollowKind.blocked:
      return {label: Label.follow, pressed: false, disabled: true, className: ButtonClass.none}
    case FollowKind.resume:
      return {label: Label.resume, pressed: false, disabled: false, className: ButtonClass.none}
    default:
      return unreachable(state.kind, "follow state: a button for a state of unknown kind")
  }
}

function followingClass(state) {
  if (state.isStale) {
    return ButtonClass.activeError
  } else if (state.isCentered) {
    return ButtonClass.active
  } else {
    return ButtonClass.waiting
  }
}

/**
 * Whether a camera move ends following. The button's own moves and a resize
 * of the map never do, and a zoom keeps following too, as in MapLibre's own
 * control. A fit, such as a filter's or a journey's, zooms as well, so it is
 * marked as a fit and ends following, as every other move does.
 */
export function endsFollowing({isOwnMove, isResize, isZooming, isFit}) {
  const isExempt = isOwnMove || isResize
  const isRiderZoom = isZooming && !isFit
  const isKept = isExempt || isRiderZoom
  return !isKept
}

/**
 * The offset in pixels, from the middle of a map `viewWidth` by
 * `viewHeight`, of the point the map keeps the dot at: the middle of the
 * part of the map the sheet's `insets` leave.
 */
export function keepOffset({viewWidth, viewHeight, insets}) {
  assertCondition(insets.left < viewWidth, `follow state: a sheet ${insets.left} px wide over a map ${viewWidth} px wide`)
  assertCondition(insets.bottom < viewHeight, `follow state: a sheet ${insets.bottom} px high over a map ${viewHeight} px high`)
  // Subtracting from 0 keeps a sheet of no height at an offset of 0 rather
  // than -0, which the map reads the same and a strict comparison does not.
  return [insets.left / HALF, (0 - insets.bottom) / HALF]
}

/**
 * Whether a fix whose dot stands at `dotPoint` on screen moves the map, and
 * by what offset the map then centers the fix.
 */
export function followMove({dotPoint, viewWidth, viewHeight, insets}) {
  const offset = keepOffset({viewWidth, viewHeight, insets})
  const [offsetX, offsetY] = offset
  const keepX = viewWidth / HALF + offsetX
  const keepY = viewHeight / HALF + offsetY
  const distance = Math.hypot(dotPoint.x - keepX, dotPoint.y - keepY)

  if (distance > FOLLOW_DISTANCE_PIXELS_MAX) {
    return {kind: MoveKind.move, offset}
  }

  return STAY
}

/** Whether a fix lies within the archive's `bounds`, edges included. */
export function isInside({bounds: {south, west, north, east}, latitude, longitude}) {
  const isWithinLatitude = latitude >= south && latitude <= north
  const isWithinLongitude = longitude >= west && longitude <= east
  const isWithin = isWithinLatitude && isWithinLongitude
  return isWithin
}

function metersPerPixel({latitude, zoom}) {
  const worldSizePixels = TILE_SIZE_PIXELS * Math.pow(HALF, zoom)
  const latitudeRadians = radians(latitude)
  return EARTH_CIRCUMFERENCE_METERS * Math.cos(latitudeRadians) / worldSizePixels
}

/**
 * The zoom the first fix centers at: the zoom at which the accuracy circle
 * fits `sidePixels`, the shorter side of the map the sheet leaves, and no
 * closer than the first zoom's bound.
 */
export function firstZoom({latitude, accuracyM, sidePixels}) {
  assertCondition(sidePixels > 0, `follow state: a map side of ${sidePixels} px`)

  if (accuracyM <= 0) {
    return FOLLOW_ZOOM_MAX
  }

  const fitMetersPerPixel = accuracyM * DIAMETER_PER_RADIUS / sidePixels
  const zoomZeroMetersPerPixel = metersPerPixel({latitude, zoom: 0})
  const fitZoom = Math.log2(zoomZeroMetersPerPixel / fitMetersPerPixel)
  return Math.min(FOLLOW_ZOOM_MAX, fitZoom)
}

/** The diameter in pixels of the accuracy circle of a fix at `latitude` on a map at `zoom`, rounded up. */
export function accuracyDiameterPixels({latitude, zoom, accuracyM}) {
  return Math.ceil(accuracyM * DIAMETER_PER_RADIUS / metersPerPixel({latitude, zoom}))
}

/** How long a follow move lasts: it jumps where the browser asks for reduced motion. */
export function moveDurationMs({reducedMotion}) {
  if (reducedMotion) {
    return 0
  }

  return FOLLOW_EASE_MS
}
