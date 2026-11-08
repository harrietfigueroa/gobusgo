// The rules of the location button. Everything here is pure: the state, the
// event, the map's size, the sheet's insets, and the dot's place on screen
// are given as values, so what the button does next, what it shows, and
// whether the map moves are functions of them alone.

import {assertCondition, unreachable} from "./assert.js"

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
const DEGREES_PER_HALF_TURN = 180
const DIAMETER_PER_RADIUS = 2
const HALF = 2

/** Off holds no watch; Following keeps the map on the dot; Located draws the dot alone; blocked follows a denial. */
export const FollowKind = Object.freeze({off: "off", following: "following", located: "located", blocked: "blocked"})

/** Where the latest fix lies against the bounds of the whole archive. */
export const FixPlace = Object.freeze({none: "none", inside: "inside", outside: "outside"})

/** What reaches the button: a press, a load with the flag stored, an outcome of the watch, or a camera move it did not make. */
export const FollowEventKind = Object.freeze({
  click: "click",
  restore: "restore",
  fix: "fix",
  failed: "failed",
  denied: "denied",
  cameraMove: "cameraMove",
  detailOpen: "detailOpen"
})

/** What the button asks of the map and the notice after an event. */
export const EffectKind = Object.freeze({center: "center", follow: "follow", notice: "notice"})

/** The zoom a center move takes: the first fix's, or the zoom the rider left the map at. */
export const CenterZoom = Object.freeze({first: "first", kept: "kept"})

/** What a follow move decision says: leave the map, or move it by the keep point's offset. */
export const MoveKind = Object.freeze({stay: "stay", move: "move"})

/** The texts of the notice, which is a polite live region. */
export const NoticeText = Object.freeze({
  following: "Following your location",
  stopped: "Stopped following your location",
  denied: "Location permission was denied, so the map stays where it is.",
  unavailable: "Your location could not be found, so the map stays where it is.",
  outside: "Your location is outside the area this map covers."
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
  center: "Center on my location"
})

/**
 * The state of a page before any press. `place` is where the latest fix
 * lies, `isCentered` whether a follow has centered the map on a fix yet,
 * `isStale` whether the latest outcome was a failure, and `isNoticeOwed`
 * whether the rider pressed the button and has not yet been told the
 * outcome.
 */
export const OFF = Object.freeze({kind: FollowKind.off, place: FixPlace.none, isCentered: false, isStale: false, isNoticeOwed: false})

const BLOCKED = Object.freeze({...OFF, kind: FollowKind.blocked})
const STAY = Object.freeze({kind: MoveKind.stay})
const NO_EFFECTS = Object.freeze([])
const FOLLOW_EFFECT = Object.freeze({kind: EffectKind.follow})
const followKinds = Object.values(FollowKind)
const fixPlaces = Object.values(FixPlace)

function notice(text) {
  return {kind: EffectKind.notice, text}
}

function unchanged(state) {
  return {state, effects: NO_EFFECTS}
}

/** Whether the button holds the watch, draws the dot, and keeps the flag stored. */
export function isActive(state) {
  const isFollowing = state.kind === FollowKind.following
  const isOn = isFollowing || state.kind === FollowKind.located
  return isOn
}

function onClick(state) {
  switch (state.kind) {
    case FollowKind.off:
      return {state: {...OFF, kind: FollowKind.following, isNoticeOwed: true}, effects: [notice(NoticeText.following)]}
    case FollowKind.following:
      return {state: OFF, effects: [notice(NoticeText.stopped)]}
    case FollowKind.located:
      return onClickLocated(state)
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
    return {state: {...state, isNoticeOwed: false}, effects: [notice(NoticeText.outside)]}
  }

  const isWaiting = state.place === FixPlace.none
  const followed = {...state, kind: FollowKind.following, isCentered: !isWaiting, isNoticeOwed: true}

  if (isWaiting) {
    return {state: followed, effects: [notice(NoticeText.following)]}
  }

  return {state: followed, effects: [{kind: EffectKind.center, zoom: CenterZoom.kept}, notice(NoticeText.following)]}
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

  const fixed = {...state, place, isStale: false, isNoticeOwed: false}

  if (state.kind === FollowKind.located) {
    return {state: fixed, effects: NO_EFFECTS}
  }

  if (place === FixPlace.outside) {
    let text = NoticeText.stopped

    if (state.isNoticeOwed) {
      text = NoticeText.outside
    }

    return {state: {...fixed, kind: FollowKind.located, isCentered: false}, effects: [notice(text)]}
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

  const failed = {...state, isStale: true, isNoticeOwed: false}

  if (state.isNoticeOwed) {
    return {state: failed, effects: [notice(NoticeText.unavailable)]}
  }

  return {state: failed, effects: NO_EFFECTS}
}

function onDenied(state) {
  if (state.isNoticeOwed) {
    return {state: BLOCKED, effects: [notice(NoticeText.denied)]}
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
    return {state: {...state, kind: FollowKind.located, isCentered: false}, effects: [notice(NoticeText.stopped)]}
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
        return {state: {...OFF, kind: FollowKind.following}, effects: NO_EFFECTS}
      }

      return unchanged(state)
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
  const latitudeRadians = latitude * Math.PI / DEGREES_PER_HALF_TURN
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
