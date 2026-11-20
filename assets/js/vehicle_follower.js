// The map's follow of one bus: a loop that keeps the map on the bus's marker,
// and the stop control that ends it. The imported rules decide which marker is
// followed, when following ends, whether a camera move ends it, and what each
// frame does. A position the follower reads is the position the page draws
// the marker at, and none of it leaves the browser.

import {showNotice} from "./map_live_region"
import {isReducedMotion, isResizeMove} from "./map_move"
import {sheetInsets} from "./panel_sheet"
import {endsFollowing, keepOffset, moveDurationMs} from "./follow_state"
import {unreachable} from "./core/assert"
import {createStopControl} from "./vehicle_follow_control"
import {
  LOCATION_FOLLOW_START_EVENT_NAME,
  OFF,
  PlacementKind,
  StepKind,
  VEHICLE_FOLLOW_START_EVENT_NAME,
  VehicleEffectKind,
  VehicleFollowEventKind,
  VehicleNotice,
  followStep,
  isFollowing,
  startZoom,
  stopButtonOf,
  transition
} from "./vehicle_follow"

/** Whether a marker's drawn position is known. */
export const PositionKind = Object.freeze({found: "found", missing: "missing"})

// MapLibre marks the camera events of a move with the event data of the call
// that made it, so the follow's own moves carry this.
const OWN_MOVE = Object.freeze({vehicleFollowSource: true})

/**
 * The follower of one map page. `positionOf(markerId)` answers where the page
 * draws that marker, as a `PositionKind` member with its `position` as
 * [longitude, latitude], and `isHeld(markerId)` whether the page holds that
 * marker at all.
 */
export function createVehicleFollower({positionOf, isHeld}) {
  let state = OFF
  let map = null
  let frame = null
  const control = createStopControl({onStop: () => { dispatch({kind: VehicleFollowEventKind.stop}) }})

  function view() {
    const container = map.getContainer()
    return {viewWidth: container.clientWidth, viewHeight: container.clientHeight, insets: sheetInsets()}
  }

  function moveTo({position, zoom, offset}) {
    const camera = {center: position, zoom, offset, duration: moveDurationMs({reducedMotion: isReducedMotion()})}
    map.easeTo(camera, OWN_MOVE)
  }

  function center() {
    const found = positionOf(state.markerId)

    if (found.kind === PositionKind.missing) {
      return
    }

    moveTo({position: found.position, zoom: startZoom(map.getZoom()), offset: keepOffset(view())})
  }

  function placementOf(found) {
    if (found.kind === PositionKind.found) {
      return {kind: PlacementKind.placed, dotPoint: map.project(found.position)}
    }

    return {kind: PlacementKind.unplaced}
  }

  function track() {
    frame = null
    const isIdle = !isFollowing(state) || map === null

    if (isIdle) {
      return
    }

    const found = positionOf(state.markerId)
    const step = followStep({isMoving: map.isMoving(), placement: placementOf(found), ...view()})

    if (step.kind === StepKind.move) {
      moveTo({position: found.position, zoom: map.getZoom(), offset: step.offset})
    }

    requestTrack()
  }

  function requestTrack() {
    if (frame === null) {
      frame = window.requestAnimationFrame(track)
    }
  }

  function cancelTrack() {
    if (frame !== null) {
      window.cancelAnimationFrame(frame)
      frame = null
    }
  }

  function focusMap() {
    if (map !== null) {
      map.getCanvas().focus()
    }
  }

  function apply(effect) {
    switch (effect.kind) {
      case VehicleEffectKind.center:
        center()
        break
      case VehicleEffectKind.notice:
        showNotice(effect.message)
        break
      case VehicleEffectKind.focusMap:
        focusMap()
        break
      default:
        unreachable(effect.kind, "vehicle follower: an effect of unknown kind")
    }
  }

  // Moves the state on by `event` and carries out what changed. The start is
  // announced before the map moves.
  function dispatch(event) {
    const wasFollowing = isFollowing(state)
    const hadFocus = control.hasFocus()
    const result = transition({state, event})
    state = result.state
    const isNowFollowing = isFollowing(state)
    const isStarted = isNowFollowing && !wasFollowing
    const isEnded = wasFollowing && !isNowFollowing
    control.render(stopButtonOf(state))

    if (isStarted) {
      window.dispatchEvent(new CustomEvent(VEHICLE_FOLLOW_START_EVENT_NAME))
      requestTrack()
    }

    if (isEnded) {
      cancelTrack()
    }

    // The button hides as the follow ends, so focus on it moves to the map.
    const isFocusLost = isEnded && hadFocus

    if (isFocusLost) {
      focusMap()
    }

    for (const effect of result.effects) {
      apply(effect)
    }
  }

  function cameraMoved(event) {
    const ends = endsFollowing({
      isOwnMove: event.vehicleFollowSource === true,
      isResize: isResizeMove(event),
      isZooming: map.isZooming(),
      isFit: event.fitSource === true
    })

    if (ends) {
      dispatch({kind: VehicleFollowEventKind.cameraMove})
    }
  }

  function onLocationFollowStart() {
    dispatch({kind: VehicleFollowEventKind.locationFollow})
  }

  window.addEventListener(LOCATION_FOLLOW_START_EVENT_NAME, onLocationFollowStart)

  return {
    // A new map takes the control over from the one it replaces, which the
    // basemap removes with its controls. A follow of the old map ends.
    attach(nextMap) {
      cancelTrack()
      state = OFF
      map = nextMap
      map.addControl({onAdd: control.onAdd, onRemove: control.onRemove})
      control.render(stopButtonOf(state))
      map.on("movestart", cameraMoved)
    },

    // Follows the marker of `markerId`, named `label` in the notices, and
    // refuses where no map is attached.
    start({markerId, label}) {
      if (map === null) {
        showNotice(VehicleNotice.unavailable())
        return
      }

      dispatch({kind: VehicleFollowEventKind.start, markerId, label})
    },

    // Tells the rider the bus asked for is not on the map.
    refuse() {
      showNotice(VehicleNotice.unavailable())
    },

    // Looks again at the markers the page holds, after any of them changed.
    markersChanged() {
      if (isFollowing(state)) {
        dispatch({kind: VehicleFollowEventKind.markersHeld, isHeld: isHeld(state.markerId), nowMs: performance.now()})
      }
    },

    // The saved schedule's markers replace the live ones.
    scheduleShown() {
      dispatch({kind: VehicleFollowEventKind.scheduleShown})
    },

    destroy() {
      cancelTrack()
      window.removeEventListener(LOCATION_FOLLOW_START_EVENT_NAME, onLocationFollowStart)
    }
  }
}
