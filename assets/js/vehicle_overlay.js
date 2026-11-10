// A 2D canvas over a map's own canvas that draws the vehicles it is handed,
// in the shapes, colors, opacities, badges, and labels of the map's vehicle
// layers. The map never draws a frame for it: it redraws on the map's
// `render` event when the camera has changed since its last draw, so it
// stands where the frame MapLibre just drew stands, and from a timer of its
// own while the camera is still. It never asks the map for a frame and
// changes no source, so the map's `idle` event keeps meaning that the map
// has come to rest.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#project — checked 2026-11-09

import {assertCondition} from "./assert.js"
import {RESTYLED_EVENT_NAME} from "./basemap"
import {CHANGE_EVENT_NAME as THEME_CHANGE_EVENT_NAME, currentTheme} from "./color_theme"
import {mapColors} from "./theme"
import {SpriteCache, SpriteShape} from "./vehicle_sprites"
import {
  badgeCorner,
  drawnVehicles,
  HitKind,
  LABEL_OFFSET_PIXELS,
  LABEL_TEXT_SIZE_PIXELS,
  MarkerKind,
  nearestVehicle,
  placedLabels,
  screenAngleRadians,
  vehiclesInBox
} from "./vehicle_overlay_layout"

const CANVAS_CLASS_NAME = "vehicle-overlay"
const LABEL_FONT = `500 ${LABEL_TEXT_SIZE_PIXELS}px system-ui, sans-serif`
const RATE_HZ_MAX = 60
const MS_PER_SECOND = 1000
const OPACITY_FALLBACK = 1
const HALVING_DIVISOR = 2

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

function hasRoute(properties) {
  return typeof properties.route === "string"
}

// `value`, a length in CSS pixels, at the nearest whole device pixel, so a
// bitmap is copied pixel for pixel with no resampling between pixels.
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

class VehicleOverlay {
  constructor({map, statuses}) {
    this.map = map
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
    this.vehiclesAt = null
    this.timer = null
    this.drawn = []
    this.drawnKey = ""
    this.sprites = new SpriteCache()

    this.onRender = () => {
      const isCameraChanged = this.vehiclesAt !== null && cameraKey(map) !== this.drawnKey

      if (isCameraChanged) {
        this.draw()
      }
    }

    // A theme's colors are in each sprite's key; the other theme's sprites
    // are dropped at once.
    this.onRestyle = () => {
      this.sprites.clear()
      this.drawIfRunning()
    }
    this.onRestyled = (event) => {
      if (event.detail.map === map) {
        this.drawIfRunning()
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
    this.draw()
  }

  // Stops the timer, clears the canvas, and leaves nothing drawn.
  stop() {
    window.clearInterval(this.timer)
    this.timer = null
    this.vehiclesAt = null
    this.drawn = []
    this.drawnKey = ""
    const context = this.canvas.getContext("2d")
    context.setTransform(1, 0, 0, 1, 0, 0)
    context.clearRect(0, 0, this.canvas.width, this.canvas.height)
  }

  // A draw from the timer while the camera moves would stand where the
  // last frame stood, a frame behind the map; the map's `render` draws then.
  tick() {
    const isStill = !this.map.isMoving()
    const isDue = isStill && document.visibilityState === "visible"

    if (isDue) {
      this.draw()
    }
  }

  drawIfRunning() {
    if (this.vehiclesAt !== null) {
      this.draw()
    }
  }

  // The canvas follows the container's size at the device's pixel ratio.
  fitCanvas() {
    const container = this.map.getContainer()
    const ratio = window.devicePixelRatio
    const width = Math.round(container.clientWidth * ratio)
    const height = Math.round(container.clientHeight * ratio)
    const isResized = this.canvas.width !== width || this.canvas.height !== height

    if (isResized) {
      this.canvas.width = width
      this.canvas.height = height
      this.canvas.style.width = `${container.clientWidth}px`
      this.canvas.style.height = `${container.clientHeight}px`
    }

    return {width: container.clientWidth, height: container.clientHeight, ratio}
  }

  draw() {
    const {width, height, ratio} = this.fitCanvas()
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
    this.drawMarkers({drawn, colors, ratio})
    this.drawBadges({drawn, colors, ratio})
    this.drawLabels({drawn, colors, ratio})

    this.drawn = drawn
    this.drawnKey = cameraKey(this.map)
  }

  // The marker of a vehicle: round for one with no heading, and otherwise
  // pointed, turned on the screen so its heading stays a compass direction.
  markerOf(properties) {
    if (!hasHeading(properties)) {
      const round = {kind: MarkerKind.round}
      return round
    }

    const bearingDegrees = this.map.getBearing()
    const angleRadians = screenAngleRadians({headingDegrees: properties.heading, bearingDegrees})
    const pointed = {kind: MarkerKind.pointed, angleRadians}
    return pointed
  }

  opacityOf(properties) {
    const opacity = this.opacities.get(properties.status)

    if (opacity === undefined) {
      return OPACITY_FALLBACK
    }

    return opacity
  }

  // Each marker is copied from its bitmap. The round markers stand under the
  // pointed ones, as the map's round layer stands under its pointed layer,
  // and a pointed marker's bitmap is turned to its heading.
  drawMarkers({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")
    const round = []
    const pointed = []

    for (const vehicle of drawn) {
      if (vehicle.marker.kind === MarkerKind.round) {
        round.push(vehicle)
      } else {
        pointed.push(vehicle)
      }
    }

    for (const {x, y, feature: {properties}} of round) {
      const opacity = this.opacityOf(properties)
      const sprite = this.sprites.marker({shape: SpriteShape.round, color: properties.color, opacity, strokeColor: colors.vehicleStroke})
      const left = snapToPixel({value: x - sprite.width / HALVING_DIVISOR, ratio})
      const top = snapToPixel({value: y - sprite.height / HALVING_DIVISOR, ratio})
      context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
    }

    for (const {x, y, marker: {angleRadians}, feature: {properties}} of pointed) {
      const opacity = this.opacityOf(properties)
      const sprite = this.sprites.marker({shape: SpriteShape.pointed, color: properties.color, opacity, strokeColor: colors.vehicleStroke})
      const centerX = snapToPixel({value: x, ratio})
      const centerY = snapToPixel({value: y, ratio})
      context.translate(centerX, centerY)
      context.rotate(angleRadians)
      context.drawImage(sprite.image, -sprite.width / HALVING_DIVISOR, -sprite.height / HALVING_DIVISOR, sprite.width, sprite.height)
      context.setTransform(ratio, 0, 0, ratio, 0, 0)
    }
  }

  // A badge is drawn at full opacity whatever its marker's, and every badge
  // is drawn, so no status is told by color alone.
  drawBadges({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")

    for (const vehicle of drawn) {
      const badge = this.badges.get(vehicle.feature.properties.status)

      if (badge !== undefined) {
        const corner = badgeCorner(vehicle)
        const sprite = this.sprites.badge({badge, ink: colors.badgeInk, paper: colors.badgePaper})
        const left = snapToPixel({value: corner.x, ratio})
        const top = snapToPixel({value: corner.y, ratio})
        context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
      }
    }
  }

  // A label is measured once, when its bitmap is made.
  drawLabels({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")
    context.font = LABEL_FONT
    const candidates = []
    const labels = new Map()

    for (const vehicle of drawn) {
      const {properties} = vehicle.feature
      let labelWidth = null

      if (hasRoute(properties)) {
        const sprite = this.sprites.label({
          text: properties.route,
          font: LABEL_FONT,
          textSizePixels: LABEL_TEXT_SIZE_PIXELS,
          color: colors.vehicleLabel,
          haloColor: colors.vehicleHalo,
          measure: context
        })
        labels.set(vehicle.id, sprite)
        labelWidth = sprite.textWidth
      }

      const hasBadge = this.badges.has(properties.status)
      candidates.push({id: vehicle.id, x: vehicle.x, y: vehicle.y, labelWidth, hasBadge})
    }

    const placed = placedLabels(candidates)

    for (const {id, x, y} of drawn) {
      if (placed.has(id)) {
        const sprite = labels.get(id)
        const left = snapToPixel({value: x - sprite.width / HALVING_DIVISOR, ratio})
        const top = snapToPixel({value: y + LABEL_OFFSET_PIXELS - sprite.padding, ratio})
        context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
      }
    }
  }

  detach() {
    window.clearInterval(this.timer)
    window.removeEventListener(THEME_CHANGE_EVENT_NAME, this.onRestyle)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    this.canvas.remove()
    overlays.delete(this.map)
  }
}

/**
 * Adds a vehicle canvas over `map`, which draws nothing until it is
 * started, and gives it. `statuses` are the status definitions, each with
 * its `status`, `opacity`, and `badge` or none.
 */
export function attachVehicleOverlay({map, statuses}) {
  assertCondition(!overlays.has(map), "a map has at most one vehicle canvas")
  const overlay = new VehicleOverlay({map, statuses})
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
