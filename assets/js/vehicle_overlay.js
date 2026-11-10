// A 2D canvas over a map's own canvas that draws the vehicles it is handed,
// in the shapes, colors, opacities, badges, and chevrons of the map's vehicle
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
import {SpriteCache} from "./vehicle_sprites"
import {BADGE_FONT, glyphStyle, routeBadgeStyle} from "./vehicle_marker_shapes"
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
  vehiclesInBox
} from "./vehicle_overlay_layout"

const CANVAS_CLASS_NAME = "vehicle-overlay"
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

// Whether a glyph's route badge is drawn: one carries its route's number,
// or the mark of a status a recent report lacks.
function hasRouteBadge(properties) {
  const isRouted = typeof properties.route === "string"
  const isMarked = properties.status === "stale" || properties.status === "unknown"
  return isRouted || isMarked
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
    this.drawRouteBadges({drawn, ratio})

    this.drawn = drawn
    this.drawnKey = cameraKey(this.map)
  }

  // The marker of a vehicle: a dot below the glyph's zoom, and otherwise a
  // glyph whose chevron turns on the screen so its heading stays a compass
  // direction, or a glyph with no chevron for a vehicle with no heading.
  markerOf(properties) {
    if (this.map.getZoom() < this.glyphZoomMin) {
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

  // Copies `sprite` centered on `x`, `y`.
  stampCentered({sprite, x, y, ratio}) {
    const context = this.canvas.getContext("2d")
    const left = snapToPixel({value: x - sprite.width / HALVING_DIVISOR, ratio})
    const top = snapToPixel({value: y - sprite.height / HALVING_DIVISOR, ratio})
    context.drawImage(sprite.image, left, top, sprite.width, sprite.height)
  }

  // Each marker is copied from its bitmap: a dot, or a glyph with its
  // chevron turned to its heading beside it.
  drawMarkers({drawn, colors, ratio}) {
    const context = this.canvas.getContext("2d")

    for (const {x, y, marker, feature: {properties}} of drawn) {
      if (marker.kind === MarkerKind.round) {
        const opacity = this.opacityOf(properties)
        const sprite = this.sprites.dot({color: properties.color, opacity, strokeColor: colors.vehicleStroke})
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
  drawRouteBadges({drawn, ratio}) {
    const context = this.canvas.getContext("2d")
    context.font = BADGE_FONT
    const candidates = []
    const sprites = new Map()

    for (const vehicle of drawn) {
      if (vehicle.marker.kind === MarkerKind.glyph) {
        const {properties} = vehicle.feature
        let badgeWidth = null

        if (hasRouteBadge(properties)) {
          const badge = routeBadgeStyle({status: properties.status, route: properties.route, color: properties.color})
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
