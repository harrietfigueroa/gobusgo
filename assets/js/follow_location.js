// The location button of a map page, and the dot and accuracy circle it
// draws. On each map the basemap announces it adds a button under the zoom
// buttons that cycles Off, Following, and Located over the page's shared
// position watch: Following keeps the map on the rider, and Located draws
// the dot and leaves the map where the rider moved it. This hook carries
// out the imported rules on the map and the notice.
//
// A position never leaves the browser: no event to the server carries one,
// and the browser stores only a flag that the button was left on. The
// element's data-bounds are the area the map covers.

import {READY_EVENT_NAME} from "./basemap"
import {CHANGE_EVENT_NAME as DETAIL_CHANGE_EVENT_NAME, DetailKind} from "./panel_detail"
import {sheetInsets} from "./panel_sheet"
import {LatestKind, OutcomeKind, PermissionKind} from "./position_watch"
import {FOLLOW_HOLDER, currentPermission, holdPosition, latestFix, releasePosition} from "./rider_position"
import {storedSettings} from "./stored_settings"
import {assertCondition, unreachable} from "./assert"
import {
  BUTTON_CLASS_NAMES,
  CenterZoom,
  EffectKind,
  FixPlace,
  FollowEventKind,
  MoveKind,
  OFF,
  accuracyDiameterPixels,
  buttonOf,
  endsFollowing,
  firstZoom,
  followMove,
  isActive,
  isInside,
  keepOffset,
  moveDurationMs,
  transition
} from "./follow_state"

const NOTICE_MS = 8_000
const BUTTON_CLASS = "maplibregl-ctrl-geolocate"
const GROUP_CLASSES = ["maplibregl-ctrl", "maplibregl-ctrl-group"]
const ICON_CLASS = "maplibregl-ctrl-icon"
const DOT_CLASS = "maplibregl-user-location-dot"
const DOT_STALE_CLASS = "maplibregl-user-location-dot-stale"
const CIRCLE_CLASS = "maplibregl-user-location-accuracy-circle"
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"
// MapLibre marks the camera events of a move with the event data of the call
// that made it, so the button's own moves carry this.
const OWN_MOVE = Object.freeze({followSource: true})

function isReducedMotion() {
  return window.matchMedia(REDUCED_MOTION_QUERY).matches
}

// MapLibre fires a resize's camera events with the ResizeObserver's entries
// as their event data, which leaves the first entry at the key 0.
function isResizeMove(event) {
  const hasResizeObserver = typeof ResizeObserverEntry === "function"
  const isResize = hasResizeObserver && event[0] instanceof ResizeObserverEntry
  return isResize
}

function createElement({tag, className}) {
  const element = document.createElement(tag)
  element.className = className
  return element
}

export const FollowLocation = {
  mounted() {
    this.map = null
    this.maplibre = null
    this.button = null
    this.dot = null
    this.circle = null
    this.state = OFF
    this.fix = null
    this.frame = null
    this.noticeTimer = null
    this.restoreOffered = false
    this.bounds = JSON.parse(this.el.dataset.bounds)

    this.onBasemapReady = (event) => { this.attach(event.detail) }
    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)

    this.onDetailChange = (event) => {
      if (event.detail.shown.kind !== DetailKind.none) {
        this.dispatch({kind: FollowEventKind.detailOpen})
      }
    }

    window.addEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
  },

  // A new map takes the button and the dot over from the one it replaces,
  // which the basemap removes with its controls and markers.
  attach({map, maplibre}) {
    this.removeMarkers()
    this.map = map
    this.maplibre = maplibre
    map.addControl({onAdd: () => this.createControl(), onRemove: () => { this.button = null }})

    map.on("movestart", (event) => { this.cameraMoved(event) })
    map.on("zoom", () => { this.scheduleDraw() })
    this.render()
    this.scheduleDraw()
    this.readPermission()
  },

  createControl() {
    const group = createElement({tag: "div", className: GROUP_CLASSES.join(" ")})
    const button = createElement({tag: "button", className: BUTTON_CLASS})
    const icon = createElement({tag: "span", className: ICON_CLASS})
    button.type = "button"
    icon.setAttribute("aria-hidden", "true")
    button.append(icon)
    group.append(button)
    button.addEventListener("click", () => { this.dispatch({kind: FollowEventKind.click}) })
    this.button = button
    return group
  },

  // A browser that has denied the permission gets the button disabled, and
  // the first map of a page whose browser stored the flag, and gives a
  // position with no prompt, starts following.
  async readPermission() {
    const permission = await currentPermission()

    if (permission === PermissionKind.denied) {
      this.dispatch({kind: FollowEventKind.denied})
      return
    }

    const isFirstMap = !this.restoreOffered
    this.restoreOffered = true
    const isGrantedOnFirstMap = isFirstMap && permission === PermissionKind.granted

    if (!isGrantedOnFirstMap) {
      return
    }

    if (storedSettings.readLocationFollow()) {
      this.dispatch({kind: FollowEventKind.restore})
    }
  },

  cameraMoved(event) {
    const ends = endsFollowing({
      isOwnMove: event.followSource === true,
      isResize: isResizeMove(event),
      isZooming: this.map.isZooming(),
      isFit: event.fitSource === true
    })

    if (ends) {
      this.dispatch({kind: FollowEventKind.cameraMove})
    }
  },

  // Moves the state on by `event` and carries out what changed. The new
  // state is set before the watch is taken, since a browser without
  // geolocation hands its outcome back from inside the call.
  dispatch(event) {
    const wasActive = isActive(this.state)
    const {state, effects} = transition({state: this.state, event})
    this.state = state
    const isOn = isActive(state)

    if (isOn !== wasActive) {
      this.switchWatch(isOn)
    }

    this.render()

    for (const effect of effects) {
      this.apply(effect)
    }
  },

  switchWatch(isOn) {
    storedSettings.writeLocationFollow(isOn)

    if (isOn) {
      holdPosition({holder: FOLLOW_HOLDER, onOutcome: (outcome) => { this.received(outcome) }})
      this.readLatest()
    } else {
      releasePosition({holder: FOLLOW_HOLDER})
      this.fix = null
      this.scheduleDraw()
    }
  },

  // A watch another holder already runs hands this one nothing until its
  // next fix, so the latest fix stands in for it while it is fresh.
  readLatest() {
    const latest = latestFix()

    if (latest.kind === LatestKind.fresh) {
      this.received({kind: OutcomeKind.fix, fix: latest.fix})
    }
  },

  received(outcome) {
    switch (outcome.kind) {
      case OutcomeKind.fix:
        this.fixed(outcome.fix)
        break
      case OutcomeKind.denied:
        this.dispatch({kind: FollowEventKind.denied})
        break
      case OutcomeKind.unavailable:
      case OutcomeKind.timedOut:
        this.dispatch({kind: FollowEventKind.failed})
        this.scheduleDraw()
        break
      default:
        unreachable(outcome.kind, "follow location: an outcome of unknown kind")
    }
  },

  fixed(fix) {
    let place = FixPlace.outside

    if (isInside({bounds: this.bounds, latitude: fix.latitude, longitude: fix.longitude})) {
      place = FixPlace.inside
    }

    this.fix = fix
    this.scheduleDraw()
    this.dispatch({kind: FollowEventKind.fix, place})
  },

  apply(effect) {
    switch (effect.kind) {
      case EffectKind.center:
        this.center(effect.zoom)
        break
      case EffectKind.follow:
        this.follow()
        break
      case EffectKind.notice:
        this.showNotice(effect.text)
        break
      default:
        unreachable(effect.kind, "follow location: an effect of unknown kind")
    }
  },

  viewOf() {
    const container = this.map.getContainer()
    return {viewWidth: container.clientWidth, viewHeight: container.clientHeight, insets: sheetInsets()}
  },

  center(centerZoom) {
    const isCenterable = this.map !== null && this.fix !== null

    if (!isCenterable) {
      return
    }

    const view = this.viewOf()
    let zoom = this.map.getZoom()

    if (centerZoom === CenterZoom.first) {
      const sidePixels = Math.min(view.viewWidth - view.insets.left, view.viewHeight - view.insets.bottom)
      zoom = firstZoom({latitude: this.fix.latitude, accuracyM: this.fix.accuracyM, sidePixels})
    }

    this.moveCamera({zoom, offset: keepOffset(view)})
  },

  // Moves the map only when the dot has strayed past the threshold from
  // where the map keeps it, at the zoom the rider left.
  follow() {
    const isFollowable = this.map !== null && this.fix !== null

    if (!isFollowable) {
      return
    }

    const dotPoint = this.map.project([this.fix.longitude, this.fix.latitude])
    const move = followMove({...this.viewOf(), dotPoint})

    if (move.kind === MoveKind.move) {
      this.moveCamera({zoom: this.map.getZoom(), offset: move.offset})
    } else {
      assertCondition(move.kind === MoveKind.stay, `follow location: a move of kind ${move.kind}`)
    }
  },

  // North stays up: a move names no bearing, so the map keeps its own.
  moveCamera({zoom, offset}) {
    const camera = {
      center: [this.fix.longitude, this.fix.latitude],
      zoom,
      offset,
      duration: moveDurationMs({reducedMotion: isReducedMotion()})
    }

    this.map.easeTo(camera, OWN_MOVE)
  },

  render() {
    if (this.button === null) {
      return
    }

    const button = buttonOf(this.state)
    this.button.setAttribute("aria-label", button.label)
    this.button.title = button.label
    this.button.setAttribute("aria-pressed", String(button.pressed))
    this.button.disabled = button.disabled
    for (const className of BUTTON_CLASS_NAMES) {
      this.button.classList.toggle(className, className === button.className)
    }
  },

  // The dot and the circle are drawn at most once per animation frame,
  // however many fixes and zoom events arrive within one.
  scheduleDraw() {
    if (this.frame === null) {
      this.frame = window.requestAnimationFrame(() => { this.draw() })
    }
  },

  draw() {
    this.frame = null
    const isDrawn = this.map !== null && this.fix !== null

    if (!isDrawn) {
      this.removeMarkers()
      return
    }

    this.ensureMarkers()
    const lngLat = [this.fix.longitude, this.fix.latitude]
    const diameter = accuracyDiameterPixels({latitude: this.fix.latitude, zoom: this.map.getZoom(), accuracyM: this.fix.accuracyM})
    this.dot.setLngLat(lngLat)
    this.circle.setLngLat(lngLat)
    this.circle.getElement().style.width = `${diameter}px`
    this.circle.getElement().style.height = `${diameter}px`
    this.dot.getElement().classList.toggle(DOT_STALE_CLASS, this.state.isStale)
  },

  // DOM markers stay drawn through a change of the theme, which sets the
  // map's style anew and drops every layer.
  ensureMarkers() {
    if (this.dot !== null) {
      return
    }

    const dotElement = createElement({tag: "div", className: DOT_CLASS})
    const circleElement = createElement({tag: "div", className: CIRCLE_CLASS})
    dotElement.setAttribute("aria-hidden", "true")
    circleElement.setAttribute("aria-hidden", "true")
    this.circle = new this.maplibre.Marker({element: circleElement, anchor: "center", pitchAlignment: "map"}).setLngLat([0, 0]).addTo(this.map)
    this.dot = new this.maplibre.Marker({element: dotElement, anchor: "center"}).setLngLat([0, 0]).addTo(this.map)
  },

  removeMarkers() {
    if (this.dot !== null) {
      this.dot.remove()
      this.circle.remove()
      this.dot = null
      this.circle = null
    }
  },

  // The notice is a polite live region that stays in the page, so a screen
  // reader hears each text written into it; it shows while it has one.
  showNotice(text) {
    this.hideNotice()
    this.el.textContent = text
    this.el.dataset.shown = "true"
    this.noticeTimer = window.setTimeout(() => { this.hideNotice() }, NOTICE_MS)
  },

  hideNotice() {
    if (this.noticeTimer !== null) {
      window.clearTimeout(this.noticeTimer)
      this.noticeTimer = null
    }

    this.el.dataset.shown = "false"
    this.el.textContent = ""
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
    releasePosition({holder: FOLLOW_HOLDER})

    if (this.frame !== null) {
      window.cancelAnimationFrame(this.frame)
    }

    this.hideNotice()
  }
}
