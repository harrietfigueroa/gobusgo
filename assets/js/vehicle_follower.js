// The map's follow of one bus: a button under the map's controls that stops
// it while it runs, and a loop that keeps the map on the bus's marker. The
// imported rules decide which marker is followed, when following ends,
// whether a camera move ends it, and when the marker has strayed far enough
// to move the map.
// A position the follower reads is the position the page draws the marker at,
// and none of it leaves the browser.

import {showNotice} from "./map_live_region"
import {isReducedMotion, isResizeMove} from "./map_move"
import {sheetInsets} from "./panel_sheet"
import {MoveKind, endsFollowing, followMove, keepOffset, moveDurationMs} from "./follow_state"
import {assertCondition, unreachable} from "./core/assert"
import {
  EffectKind,
  NoticeMessage,
  OFF,
  VEHICLE_FOLLOW_START_EVENT_NAME,
  VehicleFollowEventKind,
  LOCATION_FOLLOW_START_EVENT_NAME,
  isFollowing,
  startZoom,
  stopButtonOf,
  transition
} from "./vehicle_follow"

const GROUP_CLASSES = ["maplibregl-ctrl", "maplibregl-ctrl-group", "vehicle-follow-control"]
const BUTTON_CLASS = "vehicle-follow-stop"
const BUTTON_TEXT = "Stop following"

/** Whether a marker's drawn position is known. */
export const PositionKind = Object.freeze({found: "found", missing: "missing"})

// MapLibre marks the camera events of a move with the event data of the call
// that made it, so the follow's own moves carry this.
const OWN_MOVE = Object.freeze({vehicleFollowSource: true})

function createElement({tag, className}) {
  const element = document.createElement(tag)
  element.className = className
  return element
}

/**
 * The follower of one map page. `positionOf(markerId)` answers where the page
 * draws that marker, as a `PositionKind` member with its `position` as
 * [longitude, latitude], and `isHeld(markerId)` whether the page holds that
 * marker at all.
 */
export function createVehicleFollower({positionOf, isHeld}) {
  let state = OFF
  let map = null
  let group = null
  let button = null
  let frame = null

  function render() {
    if (button === null) {
      return
    }

    const {label, isHidden} = stopButtonOf(state)
    button.setAttribute("aria-label", label)
    group.hidden = isHidden
  }

  function view() {
    const container = map.getContainer()
    return {viewWidth: container.clientWidth, viewHeight: container.clientHeight, insets: sheetInsets()}
  }

  function moveTo({position, zoom, offset}) {
    const camera = {center: position, zoom, offset, duration: moveDurationMs({reducedMotion: isReducedMotion()})}
    map.easeTo(camera, OWN_MOVE)
  }

  function center() {
    if (map === null) {
      return
    }

    const found = positionOf(state.markerId)

    if (found.kind === PositionKind.missing) {
      return
    }

    moveTo({position: found.position, zoom: startZoom(map.getZoom()), offset: keepOffset(view())})
  }

  // Moves the map only when the marker has strayed past the threshold from
  // where the map keeps it, and not while an earlier move still eases, which
  // a new move would restart from its slow start.
  function track() {
    frame = null

    const isIdle = !isFollowing(state) || map === null

    if (isIdle) {
      return
    }

    const found = positionOf(state.markerId)
    const isTrackable = found.kind === PositionKind.found && !map.isEasing()

    if (isTrackable) {
      const move = followMove({...view(), dotPoint: map.project(found.position)})

      if (move.kind === MoveKind.move) {
        moveTo({position: found.position, zoom: map.getZoom(), offset: move.offset})
      } else {
        assertCondition(move.kind === MoveKind.stay, `vehicle follower: a move of kind ${move.kind}`)
      }
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

  function apply(effect) {
    switch (effect.kind) {
      case EffectKind.center:
        center()
        break
      case EffectKind.notice:
        showNotice(effect.message)
        break
      case EffectKind.focusMap:
        if (map !== null) {
          map.getCanvas().focus()
        }

        break
      default:
        unreachable(effect.kind, "vehicle follower: an effect of unknown kind")
    }
  }

  // Moves the state on by `event` and carries out what changed. The start is
  // announced before the map moves, so the location follow has let go of it.
  function dispatch(event) {
    const wasFollowing = isFollowing(state)
    const result = transition({state, event})
    state = result.state
    const isNowFollowing = isFollowing(state)
    render()

    const isStarted = isNowFollowing && !wasFollowing
    const isEnded = wasFollowing && !isNowFollowing

    if (isStarted) {
      window.dispatchEvent(new CustomEvent(VEHICLE_FOLLOW_START_EVENT_NAME))
      requestTrack()
    }

    if (isEnded) {
      cancelTrack()
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

  function createControl() {
    group = createElement({tag: "div", className: GROUP_CLASSES.join(" ")})
    button = createElement({tag: "button", className: BUTTON_CLASS})
    button.type = "button"
    button.textContent = BUTTON_TEXT
    button.addEventListener("click", () => { dispatch({kind: VehicleFollowEventKind.stop}) })
    group.append(button)
    render()
    return group
  }

  function releaseControl() {
    button = null
    group = null
  }

  function onLocationFollowStart() {
    dispatch({kind: VehicleFollowEventKind.locationFollow})
  }

  window.addEventListener(LOCATION_FOLLOW_START_EVENT_NAME, onLocationFollowStart)

  return {
    // A new map takes the button over from the one it replaces, which the
    // basemap removes with its controls. A follow of the old map ends.
    attach(nextMap) {
      cancelTrack()
      state = OFF
      map = nextMap
      map.addControl({onAdd: createControl, onRemove: releaseControl})
      map.on("movestart", cameraMoved)
    },

    // Follows the marker of `markerId`, named `label` in the notices.
    start({markerId, label}) {
      dispatch({kind: VehicleFollowEventKind.start, markerId, label})
    },

    // Tells the rider the bus asked for is not on the map.
    refuse() {
      showNotice(NoticeMessage.unavailable())
    },

    // Looks again at the markers the page holds, after any of them changed.
    markersChanged() {
      if (isFollowing(state)) {
        dispatch({kind: VehicleFollowEventKind.markersHeld, isHeld: isHeld(state.markerId)})
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
