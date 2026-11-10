// The location button of a map page, and the dot and accuracy circle it
// draws. On each map the basemap announces it adds a button under the zoom
// buttons that cycles Off, Following, and Located over the page's shared
// position watch: Following keeps the map on the rider, and Located draws
// the dot and leaves the map where the rider moved it. While the dot is
// drawn and Show my direction is on, a cone on it points the way the rider
// travels or faces. This hook carries out the imported rules on the map and
// in the notices of the map's live region.
//
// A position and a heading never leave the browser: no event to the server
// carries either, and the browser stores only a flag that the button was
// left on. The element's data-bounds are the area the map covers.

import {READY_EVENT_NAME} from "./basemap"
import {clearRegion, showNotice} from "./map_live_region"
import {canRequestMotionPermission, isMotionPermissionDenied, requestMotionPermission} from "./motion_permission"
import {CHANGE_EVENT_NAME as DETAIL_CHANGE_EVENT_NAME, DetailKind} from "./panel_detail"
import {sheetInsets} from "./panel_sheet"
import {LatestKind, OutcomeKind, PermissionKind} from "./position_watch"
import {FOLLOW_HOLDER, currentPermission, holdPosition, latestFix, releasePosition} from "./rider_position"
import {
  CONE_WIDTH_DEGREES,
  CompassSource,
  NO_READING,
  ReadingKind,
  asksMotionPermission,
  compassReading,
  compassSourceOf,
  coneHeading,
  coneTurnMs,
  gpsReading,
  isRedrawn,
  listensOrientation,
  turnedRotation
} from "./rider_heading"
import {CHANGE_EVENT_NAME as DIRECTION_CHANGE_EVENT_NAME, isDirectionShown} from "./show_direction"
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

const BUTTON_CLASS = "maplibregl-ctrl-geolocate"
const GROUP_CLASSES = ["maplibregl-ctrl", "maplibregl-ctrl-group"]
const ICON_CLASS = "maplibregl-ctrl-icon"
const DOT_CLASS = "maplibregl-user-location-dot"
const DOT_STALE_CLASS = "maplibregl-user-location-dot-stale"
const CIRCLE_CLASS = "maplibregl-user-location-accuracy-circle"
const CONE_CLASS = "rider-heading-cone"
const CONE_SHAPE_CLASS = "rider-heading-cone-shape"
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"
// The heading's age bound is checked again just after the reading expires.
const CONE_EXPIRY_MARGIN_MS = 50
const ORIENTATION_EVENT_NAMES = Object.freeze({
  [CompassSource.absolute]: "deviceorientationabsolute",
  [CompassSource.webkit]: "deviceorientation"
})
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

// A browser without the Screen Orientation API shows the page in the
// screen's natural orientation.
function screenAngle() {
  const orientation = window.screen.orientation

  if (orientation === undefined) {
    return 0
  }

  return orientation.angle
}

function isPageVisible() {
  return document.visibilityState === "visible"
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
    this.cone = null
    this.state = OFF
    this.fix = null
    this.frame = null
    this.restoreOffered = false
    this.bounds = JSON.parse(this.el.dataset.bounds)
    this.isShown = isDirectionShown()
    this.compass = NO_READING
    this.drawnCone = NO_READING
    this.coneRotation = 0
    this.coneTimer = null
    this.compassSource = compassSourceOf({hasAbsoluteEvent: "ondeviceorientationabsolute" in window})
    this.isListening = false

    this.onBasemapReady = (event) => { this.attach(event.detail) }
    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)

    this.onOrientation = (event) => { this.oriented(event) }
    this.onVisibility = () => { this.syncOrientation() }
    document.addEventListener("visibilitychange", this.onVisibility)

    this.onDirectionChange = (event) => {
      this.isShown = event.detail.isShown
      this.syncOrientation()
      this.scheduleDraw()
    }

    window.addEventListener(DIRECTION_CHANGE_EVENT_NAME, this.onDirectionChange)

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
    button.addEventListener("click", () => { this.clicked() })
    this.button = button
    return group
  },

  // The click that starts following asks for the motion permission after
  // the watch has asked for the location, both inside the click's
  // activation, which Safari on iOS requires of the motion request.
  clicked() {
    const previousKind = this.state.kind
    this.dispatch({kind: FollowEventKind.click})

    const asks = asksMotionPermission({
      previousKind,
      nextKind: this.state.kind,
      isShown: this.isShown,
      isDenied: isMotionPermissionDenied(),
      canRequest: canRequestMotionPermission()
    })

    if (asks) {
      requestMotionPermission()
    }
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
        showNotice(effect.message)
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
      this.syncOrientation()
      return
    }

    this.ensureMarkers()
    const lngLat = [this.fix.longitude, this.fix.latitude]
    const diameter = accuracyDiameterPixels({latitude: this.fix.latitude, zoom: this.map.getZoom(), accuracyM: this.fix.accuracyM})
    this.dot.setLngLat(lngLat)
    this.circle.setLngLat(lngLat)
    this.cone.setLngLat(lngLat)
    this.circle.getElement().style.width = `${diameter}px`
    this.circle.getElement().style.height = `${diameter}px`
    this.dot.getElement().classList.toggle(DOT_STALE_CLASS, this.state.isStale)
    this.drawCone()
    this.syncOrientation()
  },

  // The cone turns only after a turn of the threshold, and is drawn again
  // once its reading grows too old, when no new reading comes.
  drawCone() {
    const heading = coneHeading({gps: gpsReading(this.fix), compass: this.compass, isShown: this.isShown, nowMs: Date.now()})
    this.scheduleConeExpiry(heading)

    if (!isRedrawn({drawn: this.drawnCone, heading})) {
      return
    }

    const wasHidden = this.drawnCone.kind === ReadingKind.none
    this.drawnCone = heading
    const shape = this.cone.getElement().firstElementChild

    if (heading.kind === ReadingKind.none) {
      shape.hidden = true
      return
    }

    // A cone that appears points at once, rather than turning from where
    // it pointed when it was last hidden.
    let rotation = heading.degrees
    let turnMs = 0

    if (!wasHidden) {
      rotation = turnedRotation({rotation: this.coneRotation, degrees: heading.degrees})
      turnMs = coneTurnMs({reducedMotion: isReducedMotion()})
    }

    this.coneRotation = rotation
    shape.style.transitionDuration = `${turnMs}ms`
    shape.style.transform = `rotate(${rotation}deg)`
    shape.hidden = false
  },

  scheduleConeExpiry(heading) {
    if (this.coneTimer !== null) {
      window.clearTimeout(this.coneTimer)
      this.coneTimer = null
    }

    if (heading.kind === ReadingKind.measured) {
      const delayMs = Math.max(0, heading.expiresAtMs - Date.now()) + CONE_EXPIRY_MARGIN_MS
      this.coneTimer = window.setTimeout(() => {
        this.coneTimer = null
        this.scheduleDraw()
      }, delayMs)
    }
  },

  // The orientation listener runs while the dot is drawn, the page is
  // visible, and the setting is on. Safari on iOS hands it no event until
  // the rider grants the motion permission in a click.
  syncOrientation() {
    const listens = listensOrientation({isDotDrawn: this.dot !== null, isVisible: isPageVisible(), isShown: this.isShown})

    if (listens === this.isListening) {
      return
    }

    const eventName = ORIENTATION_EVENT_NAMES[this.compassSource]
    this.isListening = listens

    if (listens) {
      window.addEventListener(eventName, this.onOrientation)
    } else {
      window.removeEventListener(eventName, this.onOrientation)
      this.compass = NO_READING
    }
  },

  // Orientation events arrive many times a second; each keeps its reading
  // and asks for a draw, which runs at most once per animation frame.
  oriented(event) {
    this.compass = compassReading({source: this.compassSource, event, screenAngle: screenAngle(), timeMs: Date.now()})
    this.scheduleDraw()
  },

  // DOM markers stay drawn through a change of the theme, which sets the
  // map's style anew and drops every layer. The cone stands between the
  // circle and the dot, and turns with the map's bearing.
  ensureMarkers() {
    if (this.dot !== null) {
      return
    }

    const dotElement = createElement({tag: "div", className: DOT_CLASS})
    const circleElement = createElement({tag: "div", className: CIRCLE_CLASS})
    const coneElement = createElement({tag: "div", className: CONE_CLASS})
    const coneShape = createElement({tag: "div", className: CONE_SHAPE_CLASS})
    dotElement.setAttribute("aria-hidden", "true")
    circleElement.setAttribute("aria-hidden", "true")
    coneElement.setAttribute("aria-hidden", "true")
    coneShape.hidden = true
    coneShape.style.setProperty("--rider-heading-width", `${CONE_WIDTH_DEGREES}deg`)
    coneElement.append(coneShape)
    this.circle = new this.maplibre.Marker({element: circleElement, anchor: "center", pitchAlignment: "map"}).setLngLat([0, 0]).addTo(this.map)
    this.cone = new this.maplibre.Marker({element: coneElement, anchor: "center", rotationAlignment: "map", pitchAlignment: "map"}).setLngLat([0, 0]).addTo(this.map)
    this.dot = new this.maplibre.Marker({element: dotElement, anchor: "center"}).setLngLat([0, 0]).addTo(this.map)
  },

  removeMarkers() {
    if (this.dot !== null) {
      this.dot.remove()
      this.circle.remove()
      this.cone.remove()
      this.dot = null
      this.circle = null
      this.cone = null
      this.drawnCone = NO_READING
      this.scheduleConeExpiry(NO_READING)
    }
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
    window.removeEventListener(DIRECTION_CHANGE_EVENT_NAME, this.onDirectionChange)
    window.removeEventListener(ORIENTATION_EVENT_NAMES[this.compassSource], this.onOrientation)
    document.removeEventListener("visibilitychange", this.onVisibility)
    releasePosition({holder: FOLLOW_HOLDER})

    if (this.frame !== null) {
      window.cancelAnimationFrame(this.frame)
    }

    this.scheduleConeExpiry(NO_READING)
    clearRegion()
  }
}
