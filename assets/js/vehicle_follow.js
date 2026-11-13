// The rules of following a bus on the map. Everything here is pure: the
// state, the event, the markers held, and an arrival are given as values, so
// which vehicle the map follows, when following ends, what the notice says,
// and which arrival can be followed are functions of them alone.

import {assertCondition, unreachable} from "./core/assert.js"

/** A follow centers the map at this zoom or closer, where a vehicle is a bus glyph with its route badge. */
export const VEHICLE_FOLLOW_ZOOM_MIN = 14

/** The window event of a rider's request to follow the vehicle of an arrival, with `vehicleId` in its detail. */
export const FOLLOW_REQUEST_EVENT_NAME = "gobusgo:vehicle-follow-request"

/** The window event that says a vehicle follow began, so the location follow ends. */
export const VEHICLE_FOLLOW_START_EVENT_NAME = "gobusgo:vehicle-follow-start"

/** The window event that says a location follow began, so the vehicle follow ends. */
export const LOCATION_FOLLOW_START_EVENT_NAME = "gobusgo:location-follow-start"

const NAMELESS_LABEL = "the bus"

/** Off follows nothing; following keeps the map on the marker of `markerId`, named `label` in the notices. */
export const VehicleFollowKind = Object.freeze({off: "off", following: "following"})

/**
 * What reaches the follow: a start on a marker, the stop button, a camera
 * move the follow did not make, the other follow starting, a look at the
 * markers held, and the saved schedule's markers replacing the live ones.
 */
export const VehicleFollowEventKind = Object.freeze({
  start: "start",
  stop: "stop",
  cameraMove: "cameraMove",
  locationFollow: "locationFollow",
  markersHeld: "markersHeld",
  scheduleShown: "scheduleShown"
})

/** What the follow asks of the map: center on the vehicle, write a notice, or give the map the focus. */
export const EffectKind = Object.freeze({center: "center", notice: "notice", focusMap: "focusMap"})

/** Whether an arrival can be followed: it names a vehicle that is live. */
export const ArrivalFollowKind = Object.freeze({followable: "followable", unfollowable: "unfollowable"})

/** Whether the markers held include the vehicle asked for. */
export const MarkerLookupKind = Object.freeze({found: "found", missing: "missing"})

/** The state before any follow. */
export const OFF = Object.freeze({kind: VehicleFollowKind.off, markerId: null, label: NAMELESS_LABEL})

const NO_EFFECTS = Object.freeze([])
const followKinds = Object.values(VehicleFollowKind)
const eventKinds = Object.values(VehicleFollowEventKind)

/** The notices, a headline that states the state and a caption with the next step, as the map's live region reads them. */
export const NoticeMessage = Object.freeze({
  following: (label) => ({headline: `Following ${label}`, caption: "Move the map or press Stop following to stop."}),
  stopped: (label) => ({headline: `Stopped following ${label}`, caption: "Tap a bus to follow it again."}),
  gone: (label) => ({headline: `Stopped following ${label}`, caption: "It is no longer on the map."}),
  offline: (label) => ({headline: `Stopped following ${label}`, caption: "You're offline, so the buses are not live."}),
  unavailable: () => ({headline: "Can't follow that bus", caption: "It is not on the map right now."})
})

function notice(message) {
  return {kind: EffectKind.notice, message}
}

function unchanged(state) {
  return {state, effects: NO_EFFECTS}
}

function ended({state, message}) {
  assertCondition(state.kind === VehicleFollowKind.following, `vehicle follow: ending a state of kind ${state.kind}`)
  return {state: OFF, effects: [notice(message)]}
}

/** The words that name a vehicle in a notice or a button: its route's name, or the bus alone. */
export function labelOf({route}) {
  const hasRoute = typeof route === "string" && route !== ""

  if (hasRoute) {
    return `the ${route} bus`
  }

  return NAMELESS_LABEL
}

/** Whether the follow keeps the map on a vehicle. */
export function isFollowing(state) {
  return state.kind === VehicleFollowKind.following
}

function onStart({state, markerId, label}) {
  assertCondition(typeof markerId === "string", "vehicle follow: a start names its marker by a string")
  assertCondition(markerId !== "", "vehicle follow: a start names a marker")
  const isSame = isFollowing(state) && state.markerId === markerId

  if (isSame) {
    return unchanged(state)
  }

  const followed = {kind: VehicleFollowKind.following, markerId, label}
  return {state: followed, effects: [{kind: EffectKind.center}, notice(NoticeMessage.following(label))]}
}

function onStop({state, withFocus}) {
  if (!isFollowing(state)) {
    return unchanged(state)
  }

  const result = ended({state, message: NoticeMessage.stopped(state.label)})

  if (withFocus) {
    return {state: result.state, effects: [...result.effects, {kind: EffectKind.focusMap}]}
  }

  return result
}

function onMarkersHeld({state, isHeld}) {
  if (!isFollowing(state)) {
    return unchanged(state)
  }

  if (isHeld) {
    return unchanged(state)
  }

  return ended({state, message: NoticeMessage.gone(state.label)})
}

function onScheduleShown(state) {
  if (!isFollowing(state)) {
    return unchanged(state)
  }

  return ended({state, message: NoticeMessage.offline(state.label)})
}

/**
 * The state after `event` and what the hook does for it, in order: center the
 * map on the vehicle, write the notice, or give the map the focus. A
 * location follow starting ends this one with no notice, since its own says
 * what the map follows.
 */
export function transition({state, event}) {
  assertCondition(followKinds.includes(state.kind), `vehicle follow: a state of kind ${String(state.kind)}`)
  assertCondition(eventKinds.includes(event.kind), `vehicle follow: an event of kind ${String(event.kind)}`)

  switch (event.kind) {
    case VehicleFollowEventKind.start:
      return onStart({state, markerId: event.markerId, label: event.label})
    case VehicleFollowEventKind.stop:
      return onStop({state, withFocus: true})
    case VehicleFollowEventKind.cameraMove:
      return onStop({state, withFocus: false})
    case VehicleFollowEventKind.locationFollow:
      return unchangedOrOff(state)
    case VehicleFollowEventKind.markersHeld:
      return onMarkersHeld({state, isHeld: event.isHeld})
    case VehicleFollowEventKind.scheduleShown:
      return onScheduleShown(state)
    default:
      return unreachable(event.kind, "vehicle follow: an event of unknown kind")
  }
}

function unchangedOrOff(state) {
  if (isFollowing(state)) {
    return {state: OFF, effects: NO_EFFECTS}
  }

  return unchanged(state)
}

/** What the stop button says and whether it is shown: only while a vehicle is followed. */
export function stopButtonOf(state) {
  if (isFollowing(state)) {
    return {label: `Stop following ${state.label}`, isHidden: false}
  }

  return {label: "Stop following the bus", isHidden: true}
}

/** The zoom a follow centers at: the map's own, or `VEHICLE_FOLLOW_ZOOM_MIN` where it stands farther out. */
export function startZoom(zoom) {
  return Math.max(zoom, VEHICLE_FOLLOW_ZOOM_MIN)
}

/**
 * Whether an arrival, a line of the server's arrivals or of the saved
 * schedules, can be followed: it names a vehicle and holds a live
 * prediction, so a scheduled arrival, whatever vehicle its feed names, is not
 * followable.
 */
export function arrivalFollow(arrival) {
  const hasVehicle = typeof arrival.vehicle_id === "string" && arrival.vehicle_id !== ""
  const isLive = arrival.predicted === true

  const isFollowable = hasVehicle && isLive

  if (isFollowable) {
    return {kind: ArrivalFollowKind.followable, vehicleId: arrival.vehicle_id}
  }

  return {kind: ArrivalFollowKind.unfollowable}
}

/** The accessible name of an arrival's follow button, which names its route and where it goes. */
export function arrivalFollowLabel({route, headsign}) {
  const hasRoute = typeof route === "string" && route !== ""
  const hasHeadsign = typeof headsign === "string" && headsign !== ""

  const hasBoth = hasRoute && hasHeadsign

  if (hasBoth) {
    return `Follow the ${route} bus to ${headsign}`
  }

  if (hasRoute) {
    return `Follow the ${route} bus`
  }

  if (hasHeadsign) {
    return `Follow the bus to ${headsign}`
  }

  return "Follow this bus"
}

/**
 * The marker whose vehicle is `vehicleId` among `markerLists`, each agency's
 * markers as the page holds them, or missing where none holds it.
 */
export function markerForVehicle({markerLists, vehicleId}) {
  for (const markers of markerLists) {
    for (const marker of markers) {
      if (marker.vehicle_id === vehicleId) {
        return {kind: MarkerLookupKind.found, marker}
      }
    }
  }

  return {kind: MarkerLookupKind.missing}
}

/** Whether `markerLists` hold the marker of `markerId`. */
export function isMarkerHeld({markerLists, markerId}) {
  for (const markers of markerLists) {
    for (const marker of markers) {
      if (marker.id === markerId) {
        return true
      }
    }
  }

  return false
}
