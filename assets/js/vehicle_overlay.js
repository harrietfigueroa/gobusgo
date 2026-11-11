// A 2D canvas over a map's own canvas that draws the vehicles it is handed,
// in the shapes, colors, opacities, badges, and chevrons of the map's vehicle
// layers, and a second canvas under it that draws the ties between
// vehicles' last reports and their markers. The map never draws a frame
// for either: they redraw on the map's `render` event when the camera has
// changed since their last draw, so they stand where the frame MapLibre
// just drew stands, and from a timer of their own while the camera is
// still. They never ask the map for a frame and change no source, so the
// map's `idle` event keeps meaning that the map has come to rest.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#project — checked 2026-11-09

import {assertCondition} from "./assert.js"
import {RESTYLED_EVENT_NAME} from "./basemap"
import {CHANGE_EVENT_NAME as THEME_CHANGE_EVENT_NAME, currentTheme} from "./color_theme"
import {mapColors} from "./theme"
import {YourBusLabelKind} from "./journey_labels"
import {SpriteCache} from "./vehicle_sprites"
import {BADGE_FONT, GLYPH_RADIUS_PIXELS, MARKER_RADIUS_PIXELS, dotStrokeOpacity, glyphStyle, routeBadgeStyle} from "./vehicle_marker_shapes"
import {selectionColor, selectionHaloOpacity, selectionHaloRadius, selectionRingRadius, selectionRingWidth} from "./selection_mark"
import {
  LINE_CASING_WIDTH_PIXELS,
  LINE_DASH_PIXELS,
  LINE_WIDTH_PIXELS,
  RING_CASING_WIDTH_PIXELS,
  RING_RADIUS_PIXELS,
  RING_WIDTH_PIXELS,
  isTieRedrawDue,
  markerCoverPixels,
  screenTie,
  tieStrokes
} from "./report_tie_layout"
import {
  badgeCorner,
  chevronCenter,
  drawnVehicles,
  HitKind,
  MarkerKind,
  nearestVehicle,
  placedBadges,
  RATE_HZ_MAX,
  routeBadgeCorner,
  screenAngleRadians,
  vehiclesInBox,
  YourBusSide,
  yourBusPlacement
} from "./vehicle_overlay_layout"

const CANVAS_CLASS_NAME = "vehicle-overlay"
const TIE_CANVAS_CLASS_NAME = "vehicle-overlay vehicle-ties"
const MS_PER_SECOND = 1000
const OPACITY_FALLBACK = 1
const HALVING_DIVISOR = 2
const FULL_TURN = HALVING_DIVISOR * Math.PI
const NO_DASH = Object.freeze([])
const YOUR_BUS_FONT = "500 12px system-ui, sans-serif"
const YOUR_BUS_HALO_WIDTH_PIXELS = 3

// The overlay of each map, which the map's other readers ask through the
// functions below.
const overlays = new WeakMap()

function statusOpacityEntry({status, opacity}) {
  return [status, opacity]
}

function statusBadgeEntry({status, badge}) {
  return [status, badge]
}

function hasBadge(definition) {
  return typeof definition.badge === "string"
}

function hasHeading(properties) {
  return typeof properties.heading === "number"
}

// Whether a glyph's route badge is drawn: one carries its route's number,
// or the mark of a status a recent report lacks.
function hasRouteBadge(properties) {
  const isRouted = typeof properties.route === "string"
  const isMarked = properties.status === "stale" || properties.status === "unknown"
  return isRouted || isMarked
}

// `value`, a length in CSS pixels, at the nearest whole device pixel, so a
// bitmap is copied pixel for pixel with no resampling between pixels.
// Whether a vehicle's feature `properties` are those of the trip and
// service day `label` names.
function isYourBus({properties, label}) {
  const isTrip = properties.tripId === label.tripId
  return isTrip && properties.serviceDateMs === label.serviceDateMs
}

function snapToPixel({value, ratio}) {
  return Math.round(value * ratio) / ratio
}

// The camera a frame is drawn from, and the size it is drawn at: two draws
// of the same key project every position to the same point.
function cameraKey(map) {
  const center = map.getCenter()
  const container = map.getContainer()
  const parts = [
    center.lng,
    center.lat,
    map.getZoom(),
    map.getBearing(),
    map.getPitch(),
    container.clientWidth,
    container.clientHeight,
    window.devicePixelRatio
  ]
  return parts.join(" ")
}

function clearCanvas(canvas) {
  const context = canvas.getContext("2d")
  context.setTransform(1, 0, 0, 1, 0, 0)
  context.clearRect(0, 0, canvas.width, canvas.height)
}

// Adds each line of `lines`, screen points, to the context's path.
function traceLines({context, lines}) {
  context.beginPath()

  for (const line of lines) {
    context.moveTo(line[0].x, line[0].y)

    for (let index = 1; index < line.length; index++) {
      context.lineTo(line[index].x, line[index].y)
    }
  }
}

// Adds a circle of the ring's radius around each point of `rings` to the
// context's path.
function traceRings({context, rings}) {
  context.beginPath()

  for (const {x, y} of rings) {
    context.moveTo(x + RING_RADIUS_PIXELS, y)
    context.arc(x, y, RING_RADIUS_PIXELS, 0, FULL_TURN)
  }
}

class VehicleOverlay {
  constructor({map, statuses, glyphZoomMin}) {
    this.map = map
    this.glyphZoomMin = glyphZoomMin
    const opacityEntries = Array.from(statuses, statusOpacityEntry)
    this.opacities = new Map(opacityEntries)
    // The badge of each status that has one.
    const badged = statuses.filter(hasBadge)
    const badgeEntries = Array.from(badged, statusBadgeEntry)
    this.badges = new Map(badgeEntries)
    this.canvas = document.createElement("canvas")
    this.canvas.className = CANVAS_CLASS_NAME
    // The map's description and its list of what is in view name the
    // vehicles drawn here.
    this.canvas.setAttribute("aria-hidden", "true")
    // Right after the map's canvas, so MapLibre's popups and markers, which
    // come after it in the same container, stand above it.
    map.getCanvas().after(this.canvas)
    // The ties stand under the vehicles, between the two canvases.
    this.tieCanvas = document.createElement("canvas")
    this.tieCanvas.className = TIE_CANVAS_CLASS_NAME
    this.tieCanvas.setAttribute("aria-hidden", "true")
    map.getCanvas().after(this.tieCanvas)
    this.vehiclesAt = null
    this.tiesAt = null
    this.tieIntervalMs = 0
    this.tiesDrawnAtMs = null
    this.timer = null
    this.drawn = []
    this.drawnKey = ""
    this.sprites = new SpriteCache()
    // The marker of the vehicle the details view shows, which the canvas
    // rings while it draws that vehicle, or null.
    this.selectedId = null
    // The label of the first bus of the chosen journey, a `yourBusLabel`
    // answer, which the canvas writes beside that vehicle while it draws it.
    this.yourBus = {kind: YourBusLabelKind.none}

    this.onRender = () => {
      const isShowing = this.vehiclesAt !== null || this.tiesAt !== null
      const isCameraChanged = isShowing && cameraKey(map) !== this.drawnKey

      if (isCameraChanged) {
        this.draw({isTieForced: true})
      }
    }

    // A theme's colors are in each sprite's key; the other theme's sprites
    // are dropped at once.
    this.onRestyle = () => {
      this.sprites.clear()
      this.drawIfRunning()
      this.drawTiesIfShown()
    }
    this.onRestyled = (event) => {
      if (event.detail.map === map) {
        this.drawIfRunning()
        this.drawTiesIfShown()
      }
    }

    map.on("render", this.onRender)
    map.on("remove", () => { this.detach() })
    window.addEventListener(THEME_CHANGE_EVENT_NAME, this.onRestyle)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
  }

  // Draws the vehicles `vehiclesAt` gives at each tick of a timer of
  // `rateHz` while the camera is still and the page is shown, and at each
  // frame the map draws from another camera. `vehiclesAt` is called with
  // the page's monotonic time in milliseconds and gives at most `VEHICLE_COUNT_MAX`
  // features, each with the properties of a vehicle layer's feature and its
  // point's coordinates. A second start replaces the first.
  start({rateHz, vehiclesAt}) {
    assertCondition(rateHz > 0, `a rate is above zero, got: ${rateHz}`)
    assertCondition(rateHz <= RATE_HZ_MAX, `a rate is at most ${RATE_HZ_MAX} Hz, got: ${rateHz}`)
    window.clearInterval(this.timer)
    this.vehiclesAt = vehiclesAt
    this.timer = window.setInterval(() => { this.tick() }, MS_PER_SECOND / rateHz)
    this.draw({isTieForced: false})
  }

  // Stops the timer, clears the vehicles' canvas, and leaves no vehicle
  // drawn; the ties stay as they are shown.
  stop() {
    window.clearInterval(this.timer)
    this.timer = null
    this.vehiclesAt = null
    this.drawn = []
    this.drawnKey = ""
    clearCanvas(this.canvas)
  }

  // Draws the ties `tiesAt` gives on the canvas under the vehicles, now, at
  // each frame the map draws from another camera, and at each tick of the
  // vehicles' timer once `intervalMs` has passed since they were last
  // drawn. `tiesAt` is called with the page's monotonic time in
  // milliseconds and gives ties, each with its route's `color`, its `ring`
  // as [lon, lat], and its `line` from the ring to its marker as a list of
  // [lon, lat]. A second call replaces the first.
  showTies({tiesAt, intervalMs}) {
    assertCondition(intervalMs >= 0, `an interval is not negative, got: ${intervalMs}`)
    this.tiesAt = tiesAt
    this.tieIntervalMs = intervalMs
    this.drawTies()
  }

  // Rings the vehicle of `markerId` while the canvas draws it, as the map's
  // layers ring it while it stands in the source; null rings none.
  markSelected(markerId) {
    this.selectedId = markerId
    this.drawIfRunning()
  }

  // Writes `label` beside the vehicle of its trip and service date while
  // the canvas draws that vehicle, as the map's layer labels it while it
  // stands in the source; a none label labels none. The label is drawn with the
  // vehicles, at their rate, so it stays beside its marker.
  markYourBus(label) {
    this.yourBus = label
    this.drawIfRunning()
  }

  // Clears the ties' canvas and draws no tie until they are shown again.
  hideTies() {
    this.tiesAt = null
    this.tiesDrawnAtMs = null
    clearCanvas(this.tieCanvas)
  }

  // A draw from the timer while the camera moves would stand where the
  // last frame stood, a frame behind the map; the map's `render` draws then.
  tick() {
    const isStill = !this.map.isMoving()
    const isDue = isStill && document.visibilityState === "visible"

    if (isDue) {
      this.draw({isTieForced: false})
    }
  }

  drawIfRunning() {
    if (this.vehiclesAt !== null) {
      this.drawVehicles()
    }
  }

  drawTiesIfShown() {
    if (this.tiesAt !== null) {
      this.drawTies()
    }
  }

  // Draws the vehicles, then the ties where `isTieForced` or their interval
  // has passed, so a tie ends where its vehicle was drawn.
  draw({isTieForced}) {
    if (this.vehiclesAt !== null) {
      this.drawVehicles()
    }

    const isTieShown = this.tiesAt !== null
    const isTieDue = isTieForced || isTieRedrawDue({drawnAtMs: this.tiesDrawnAtMs, nowMs: performance.now(), intervalMs: this.tieIntervalMs})
    const isTieDrawn = isTieShown && isTieDue

    if (isTieDrawn) {
      this.drawTies()
    }

    this.drawnKey = cameraKey(this.map)
  }

  // Both canvases follow the container's size at the device's pixel ratio.
  fitCanvases() {
    const container = this.map.getContainer()
    const ratio = window.devicePixelRatio
    const width = Math.round(container.clientWidth * ratio)
    const height = Math.round(container.clientHeight * ratio)

    for (const canvas of [this.canvas, this.tieCanvas]) {
      const isResized = canvas.width !== width || canvas.height !== height

      if (isResized) {
        canvas.width = width
        canvas.height = height
        canvas.style.width = `${container.clientWidth}px`
        canvas.style.height = `${container.clientHeight}px`
      }
    }

    return {width: container.clientWidth, height: container.clientHeight, ratio}
  }

  drawVehicles() {
    const {width, height, ratio} = this.fitCanvases()
    const features = this.vehiclesAt(performance.now())
    const vehicles = []

    for (const feature of features) {
      const point = this.map.project(feature.geometry.coordinates)
      const marker = this.markerOf(feature.properties)
      vehicles.push({id: feature.properties.markerId, x: point.x, y: point.y, marker, feature})
    }

    const drawn = drawnVehicles({vehicles, width, height})
    const context = this.canvas.getContext("2d")
    context.setTransform(ratio, 0, 0, ratio, 0, 0)
    context.clearRect(0, 0, width, height)

    const colors = mapColors(currentTheme())
    this.sprites.prepare(ratio)
    this.drawSelection(drawn)
    this.drawMarkers({drawn, colors, ratio})
    this.drawBadges({drawn, colors, ratio})
    this.drawRouteBadges({drawn, colors, ratio})
    this.drawYourBus({drawn, colors, width})

    this.drawn = drawn
  }

  // The ties of `tiesAt` on the screen, each cut where its marker covers it:
  // every casing first, then each route color's dashed lines, then the
  // rings, a casing filled with the theme's paper and a stroke in the
  // route's color.
  drawTies() {
    const {ratio} = this.fitCanvases()
    const nowMs = performance.now()
    const reachPixels = markerCoverPixels(this.markerKind())
    const screenTies = []

    for (const tie of this.tiesAt(nowMs)) {
      const ring = this.map.project(tie.ring)
      const line = []

      for (const position of tie.line) {
        line.push(this.map.project(position))
      }

      screenTies.push(screenTie({color: tie.color, ring, line, reachPixels}))
    }

    const strokes = tieStrokes(screenTies)
    const colors = mapColors(currentTheme())
    const casingColor = colors.routeCasing.color
    const context = this.tieCanvas.getContext("2d")
    clearCanvas(this.tieCanvas)
    context.setTransform(ratio, 0, 0, ratio, 0, 0)
    context.lineCap = "round"
    context.lineJoin = "round"

    context.setLineDash(NO_DASH)
    context.lineWidth = LINE_CASING_WIDTH_PIXELS
    context.strokeStyle = casingColor
    traceLines({context, lines: strokes.lines})
    context.stroke()

    context.lineCap = "butt"
    context.setLineDash(LINE_DASH_PIXELS)
    context.lineWidth = LINE_WIDTH_PIXELS

    for (const batch of strokes.colors) {
      context.strokeStyle = batch.color
      traceLines({context, lines: batch.lines})
      context.stroke()
    }

    context.setLineDash(NO_DASH)
    traceRings({context, rings: strokes.rings})
    context.fillStyle = colors.badgePaper
    context.fill()
    context.lineWidth = RING_CASING_WIDTH_PIXELS
    context.strokeStyle = casingColor
    context.stroke()
    context.lineWidth = RING_WIDTH_PIXELS

    for (const batch of strokes.colors) {
      context.strokeStyle = batch.color
      traceRings({context, rings: batch.rings})
      context.stroke()
    }

    this.tiesDrawnAtMs = nowMs
  }

  // The kind of every marker at the map's zoom: a dot below the glyph's
  // zoom, and a glyph from it.
  markerKind() {
    if (this.map.getZoom() < this.glyphZoomMin) {
      return MarkerKind.round
    }

    return MarkerKind.glyph
  }

  // The marker of a vehicle: a dot below the glyph's zoom, and otherwise a
  // glyph whose chevron turns on the screen so its heading stays a compass
  // direction, or a glyph with no chevron for a vehicle with no heading.
  markerOf(properties) {
    if (this.markerKind() === MarkerKind.round) {
      const round = {kind: MarkerKind.round}
      return round
    }

    if (!hasHeading(properties)) {
      const still = {kind: MarkerKind.glyph, hasChevron: false, angleRadians: 0}
      return still
    }

    const bearingDegrees = this.map.getBearing()
    const angleRadians = screenAngleRadians({headingDegrees: properties.heading, bearingDegrees})
    const heading = {kind: MarkerKind.glyph, hasChevron: true, angleRadians}
    return heading
  }

  opacityOf(properties) {
    const opacity = this.opacities.get(properties.status)

    if (opacity === undefined) {
      return OPACITY_FALLBACK
    }

    return opacity
  }

  // The first bus's label beside its marker, in the halo and ink of the
  // map's own labels so it reads over any ground.
  drawYourBus({drawn, colors, width}) {
    const {yourBus} = this

    if (yourBus.kind === YourBusLabelKind.none) {
      return
    }

    const bus = drawn.find((vehicle) => isYourBus({properties: vehicle.feature.properties, label: yourBus}))

    if (bus === undefined) {
      return
    }

    const context = this.canvas.getContext("2d")
    context.font = YOUR_BUS_FONT
    const textWidth = context.measureText(yourBus.text).width
    const placement = yourBusPlacement({x: bus.x, y: bus.y, kind: bus.marker.kind, textWidth, width})
    context.textAlign = "left"

    if (placement.side === YourBusSide.left) {
      context.textAlign = "right"
    }

    context.textBaseline = "middle"
    context.lineJoin = "round"
    context.lineWidth = YOUR_BUS_HALO_WIDTH_PIXELS * HALVING_DIVISOR
    context.strokeStyle = colors.badgePaper
    context.strokeText(yourBus.text, placement.textX, placement.textY)
    context.fillStyle = colors.badgeInk
    context.fillText(yourBus.text, placement.textX, placement.textY)
  }

  // Copies `sprite` centered on `x`, `y`.
  stampCentered({sprite, x, y, ratio}) {
    const context = this.canvas.getContext("2d")
    const left = snapToPixel({value: x - sprite.width / HALVING_DIVISOR, ratio})
    const top = snapToPixel({value: y - sprite.height / HALVING_DIVISOR, ratio})
    context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
  }

  // The ring of the selected vehicle, under its marker, round a dot or a
  // glyph as the map's layers draw it.
  drawSelection(drawn) {
    const selected = drawn.find((vehicle) => vehicle.id === this.selectedId)

    if (selected === undefined) {
      return
    }

    let markerRadius = GLYPH_RADIUS_PIXELS

    if (selected.marker.kind === MarkerKind.round) {
      markerRadius = MARKER_RADIUS_PIXELS
    }

    const context = this.canvas.getContext("2d")
    context.fillStyle = selectionColor()
    context.strokeStyle = selectionColor()
    context.globalAlpha = selectionHaloOpacity()
    context.beginPath()
    context.arc(selected.x, selected.y, selectionHaloRadius(markerRadius), 0, FULL_TURN)
    context.fill()
    context.globalAlpha = 1
    context.beginPath()
    context.arc(selected.x, selected.y, selectionRingRadius(markerRadius), 0, FULL_TURN)
    context.lineWidth = selectionRingWidth()
    context.setLineDash(NO_DASH)
    context.stroke()
  }

  // Each marker is copied from its bitmap: a dot, or a glyph with its
  // chevron turned to its heading beside it.
  drawMarkers({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")

    for (const {x, y, marker, feature: {properties}} of drawn) {
      if (marker.kind === MarkerKind.round) {
        const opacity = this.opacityOf(properties)
        const strokeOpacity = dotStrokeOpacity({opacity, colors})
        const sprite = this.sprites.dot({color: properties.color, opacity, strokeColor: colors.vehicleStroke, strokeOpacity})
        this.stampCentered({sprite, x, y, ratio})
      } else {
        const style = glyphStyle({status: properties.status, color: properties.color, colors})
        this.stampCentered({sprite: this.sprites.glyph({style}), x, y, ratio})

        if (marker.hasChevron) {
          const center = chevronCenter({x, y, angleRadians: marker.angleRadians})
          const sprite = this.sprites.chevron({color: properties.color, halo: colors.glyphLiveOutline})
          context.translate(snapToPixel({value: center.x, ratio}), snapToPixel({value: center.y, ratio}))
          context.rotate(marker.angleRadians)
          context.drawImage(sprite.image, -sprite.width / HALVING_DIVISOR, -sprite.height / HALVING_DIVISOR, sprite.width, sprite.height)
          context.setTransform(ratio, 0, 0, ratio, 0, 0)
        }
      }
    }
  }

  // A dot's status badge is drawn at full opacity whatever its dot's, and
  // every one is drawn, so no status is told by color alone.
  drawBadges({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")

    for (const vehicle of drawn) {
      const badge = this.badges.get(vehicle.feature.properties.status)
      const isDot = vehicle.marker.kind === MarkerKind.round
      const isBadgedDot = isDot && badge !== undefined

      if (isBadgedDot) {
        const corner = badgeCorner(vehicle)
        const sprite = this.sprites.badge({badge, ink: colors.badgeInk, paper: colors.badgePaper})
        const left = snapToPixel({value: corner.x, ratio})
        const top = snapToPixel({value: corner.y, ratio})
        context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
      }
    }
  }

  // A glyph's route badge is measured once, when its bitmap is made, and is
  // left out where it would cover another glyph or badge.
  drawRouteBadges({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")
    context.font = BADGE_FONT
    const candidates = []
    const sprites = new Map()

    for (const vehicle of drawn) {
      if (vehicle.marker.kind === MarkerKind.glyph) {
        const {properties} = vehicle.feature
        let badgeWidth = null

        if (hasRouteBadge(properties)) {
          const badge = routeBadgeStyle({status: properties.status, route: properties.route, color: properties.color, colors})
          const sprite = this.sprites.routeBadge({badge, measure: context})
          sprites.set(vehicle.id, sprite)
          badgeWidth = sprite.width
        }

        candidates.push({id: vehicle.id, x: vehicle.x, y: vehicle.y, badgeWidth})
      }
    }

    const placed = placedBadges(candidates)

    for (const vehicle of drawn) {
      if (placed.has(vehicle.id)) {
        const sprite = sprites.get(vehicle.id)
        const corner = routeBadgeCorner(vehicle)
        const left = snapToPixel({value: corner.x, ratio})
        const top = snapToPixel({value: corner.y, ratio})
        context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
      }
    }
  }

  detach() {
    window.clearInterval(this.timer)
    window.removeEventListener(THEME_CHANGE_EVENT_NAME, this.onRestyle)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    this.canvas.remove()
    this.tieCanvas.remove()
    overlays.delete(this.map)
  }
}

/**
 * Adds a vehicle canvas over `map`, which draws nothing until it is
 * started, and gives it. `statuses` are the status definitions, each with
 * its `status`, `opacity`, and `badge` or none, and `glyphZoomMin` the zoom
 * from which a vehicle is a bus glyph.
 */
export function attachVehicleOverlay({map, statuses, glyphZoomMin}) {
  assertCondition(!overlays.has(map), "a map has at most one vehicle canvas")
  const overlay = new VehicleOverlay({map, statuses, glyphZoomMin})
  overlays.set(map, overlay)
  return overlay
}

/**
 * The feature of the vehicle the canvas over `map` draws nearest `point`,
 * a point on the map's screen, within the reach of a click, or missing
 * where none is within reach or the map has no canvas.
 */
export function overlayHitAt({map, point}) {
  const overlay = overlays.get(map)

  if (overlay === undefined) {
    const missing = {kind: HitKind.missing}
    return missing
  }

  const hit = nearestVehicle({drawn: overlay.drawn, point})

  if (hit.kind === HitKind.missing) {
    return hit
  }

  const found = {kind: HitKind.found, feature: hit.vehicle.feature}
  return found
}

/**
 * The features of the vehicles the canvas over `map` drew last whose
 * points stand inside `box`, `[[left, top], [right, bottom]]` on the map's
 * screen, each with the coordinates it was drawn at.
 */
export function overlayFeaturesIn({map, box}) {
  const overlay = overlays.get(map)
  const features = []

  if (overlay === undefined) {
    return features
  }

  for (const vehicle of vehiclesInBox({drawn: overlay.drawn, box})) {
    features.push(vehicle.feature)
  }

  return features
}

export {HitKind}
