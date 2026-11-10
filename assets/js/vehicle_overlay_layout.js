// Where the canvas over the map draws the vehicles it is handed, as pure
// functions of their points on the screen: which vehicles are drawn, which
// one a click is on, which stand inside a box, where a dot's status badge
// and a glyph's route badge and chevron stand, which way a chevron turns,
// and which route badges are drawn. Every length is in CSS pixels, and
// nothing here reads the document or the map, which lets it be run apart
// from both.

import {assertCondition, unreachable} from "./assert.js"
import {
  BADGE_HEIGHT_PIXELS,
  BADGE_SHOULDER_PIXELS,
  CHEVRON_DISTANCE_PIXELS,
  GLYPH_IMAGE_SIZE_PIXELS,
  GLYPH_RADIUS_PIXELS,
  MARKER_RADIUS_PIXELS,
  MARKER_STROKE_WIDTH_PIXELS
} from "./vehicle_marker_shapes.js"
import {MARK_SIZE_PIXELS} from "./status_badges.js"

/** How far from a drawn marker's center a click still opens it. */
export const HIT_RADIUS_PIXELS = 12

/** The most vehicles the canvas is handed at once. */
export const VEHICLE_COUNT_MAX = 100

/** The fastest rate the canvas redraws at while the camera is still. */
export const RATE_HZ_MAX = 60

/** The kinds of the vehicle a click is on: one, or none within reach. */
export const HitKind = Object.freeze({found: "found", missing: "missing"})

/** The kinds of a vehicle's marker: a regional dot, or a bus glyph. */
export const MarkerKind = Object.freeze({round: "round", glyph: "glyph"})

// A marker's center may stand this far outside the canvas while some of its
// marker, its badge, or its chevron is still inside it.
const DRAWN_MARGIN_PIXELS = 48
// The badge's lower left corner stands this far inside the marker's edge,
// right of and above its center, so the badge sits on its upper right edge.
const BADGE_INSET_PIXELS = 2
const BADGE_OFFSET_PIXELS = MARKER_RADIUS_PIXELS - BADGE_INSET_PIXELS
const HALVING_DIVISOR = 2
const ROUND_REACH_PIXELS = MARKER_RADIUS_PIXELS + MARKER_STROKE_WIDTH_PIXELS
const GLYPH_IMAGE_HALF_PIXELS = GLYPH_IMAGE_SIZE_PIXELS / HALVING_DIVISOR
// The room MapLibre keeps around an icon, its `icon-padding`, which the
// glyph's layers leave at its default.
// https://maplibre.org/maplibre-style-spec/layers/#icon-padding — checked 2026-11-09
const ICON_PADDING_PIXELS = 2
const DEGREES_PER_HALF_TURN = 180

function isPoint({x, y}) {
  const isFiniteX = Number.isFinite(x)
  return isFiniteX && Number.isFinite(y)
}

function assertVehicles(vehicles) {
  assertCondition(vehicles.length <= VEHICLE_COUNT_MAX, `at most ${VEHICLE_COUNT_MAX} vehicles, got: ${vehicles.length}`)

  for (const vehicle of vehicles) {
    assertCondition(isPoint(vehicle), `a vehicle stands at a finite point, got: ${vehicle.x}, ${vehicle.y}`)
  }
}

/**
 * The vehicles of `vehicles`, each with its point `x`, `y`, that a canvas of
 * `width` by `height` shows some part of, in the order they are given.
 */
export function drawnVehicles({vehicles, width, height}) {
  assertCondition(width >= 0, `a canvas's width is not negative, got: ${width}`)
  assertCondition(height >= 0, `a canvas's height is not negative, got: ${height}`)
  assertVehicles(vehicles)
  const drawn = []

  for (const vehicle of vehicles) {
    const isWithinX = vehicle.x >= -DRAWN_MARGIN_PIXELS && vehicle.x <= width + DRAWN_MARGIN_PIXELS
    const isWithinY = vehicle.y >= -DRAWN_MARGIN_PIXELS && vehicle.y <= height + DRAWN_MARGIN_PIXELS
    const isWithin = isWithinX && isWithinY

    if (isWithin) {
      drawn.push(vehicle)
    }
  }

  return drawn
}

/**
 * The vehicle of `drawn` nearest `point` within `HIT_RADIUS_PIXELS`, the
 * first of those as near, or missing where none is within reach.
 */
export function nearestVehicle({drawn, point}) {
  assertCondition(isPoint(point), `a click stands at a finite point, got: ${point.x}, ${point.y}`)
  assertVehicles(drawn)
  let nearest = null
  let nearestDistance = HIT_RADIUS_PIXELS

  for (const vehicle of drawn) {
    const distance = Math.hypot(vehicle.x - point.x, vehicle.y - point.y)
    const isNearer = nearest === null || distance < nearestDistance
    const isHit = distance <= HIT_RADIUS_PIXELS && isNearer

    if (isHit) {
      nearest = vehicle
      nearestDistance = distance
    }
  }

  if (nearest === null) {
    const missing = {kind: HitKind.missing}
    return missing
  }

  const found = {kind: HitKind.found, vehicle: nearest}
  return found
}

// How far from its center a vehicle counts as inside a box, as the map's
// layers count it: a dot by its circle and outline, and a glyph by its
// image with the icon's padding.
function reachPixels(marker) {
  switch (marker.kind) {
    case MarkerKind.round:
      return ROUND_REACH_PIXELS
    case MarkerKind.glyph:
      return GLYPH_IMAGE_HALF_PIXELS + ICON_PADDING_PIXELS
    default:
      return unreachable(marker.kind, "a marker is a dot or a glyph")
  }
}

/**
 * The vehicles of `drawn` that the map's layers would count inside `box`,
 * a box on the screen as `[[left, top], [right, bottom]]`: those whose
 * marker reaches into it. A vehicle has its point `x`, `y` and its
 * `marker`, of a `MarkerKind`.
 */
export function vehiclesInBox({drawn, box}) {
  const [[left, top], [right, bottom]] = box
  assertCondition(left <= right, `a box's left is not past its right, got: ${left}, ${right}`)
  assertCondition(top <= bottom, `a box's top is not below its bottom, got: ${top}, ${bottom}`)
  const inside = []

  for (const vehicle of drawn) {
    const reach = reachPixels(vehicle.marker)
    const isInsideX = vehicle.x >= left - reach && vehicle.x <= right + reach
    const isInsideY = vehicle.y >= top - reach && vehicle.y <= bottom + reach
    const isInside = isInsideX && isInsideY

    if (isInside) {
      inside.push(vehicle)
    }
  }

  return inside
}

/**
 * The angle, clockwise from the top of the screen, that a chevron of
 * `headingDegrees`, clockwise from north, turns to on a map whose bearing is
 * `bearingDegrees`: the heading stays a compass direction on a turned map.
 */
export function screenAngleRadians({headingDegrees, bearingDegrees}) {
  assertCondition(Number.isFinite(headingDegrees), `a heading is a finite number, got: ${headingDegrees}`)
  assertCondition(Number.isFinite(bearingDegrees), `a bearing is a finite number, got: ${bearingDegrees}`)
  return ((headingDegrees - bearingDegrees) * Math.PI) / DEGREES_PER_HALF_TURN
}

/** The top left corner of the status badge of a dot centered on `x`, `y`: its lower left corner on the dot's upper right edge. */
export function badgeCorner({x, y}) {
  return {x: x + BADGE_OFFSET_PIXELS, y: y - BADGE_OFFSET_PIXELS - MARK_SIZE_PIXELS}
}

/** The top left corner of the route badge of a glyph centered on `x`, `y`: its lower left corner on the glyph's shoulder. */
export function routeBadgeCorner({x, y}) {
  return {x: x + BADGE_SHOULDER_PIXELS, y: y - BADGE_SHOULDER_PIXELS - BADGE_HEIGHT_PIXELS}
}

/** The center of the chevron of a glyph centered on `x`, `y`, turned `angleRadians` clockwise from the top of the screen. */
export function chevronCenter({x, y, angleRadians}) {
  return {
    x: x + CHEVRON_DISTANCE_PIXELS * Math.sin(angleRadians),
    y: y - CHEVRON_DISTANCE_PIXELS * Math.cos(angleRadians)
  }
}

function glyphBox({x, y}) {
  return {
    left: x - GLYPH_RADIUS_PIXELS,
    top: y - GLYPH_RADIUS_PIXELS,
    right: x + GLYPH_RADIUS_PIXELS,
    bottom: y + GLYPH_RADIUS_PIXELS
  }
}

function routeBadgeBox({x, y, badgeWidth}) {
  const corner = routeBadgeCorner({x, y})

  return {
    left: corner.x - ICON_PADDING_PIXELS,
    top: corner.y - ICON_PADDING_PIXELS,
    right: corner.x + badgeWidth + ICON_PADDING_PIXELS,
    bottom: corner.y + BADGE_HEIGHT_PIXELS + ICON_PADDING_PIXELS
  }
}

function overlaps(first, second) {
  const isApartX = first.right <= second.left || second.right <= first.left
  const isApartY = first.bottom <= second.top || second.bottom <= first.top
  const isApart = isApartX || isApartY
  return !isApart
}

// Whether `box` overlaps a box of `obstacles` that belongs to another
// vehicle than `id`: a badge stands on its own glyph by design.
function overlapsOther({box, id, obstacles}) {
  for (const obstacle of obstacles) {
    const isOther = obstacle.id !== id
    const isCovered = isOther && overlaps(box, obstacle.box)

    if (isCovered) {
      return true
    }
  }

  return false
}

function hasRouteBadge(vehicle) {
  return vehicle.badgeWidth !== null
}

/**
 * The identifiers of the vehicles of `vehicles` whose route badges are
 * drawn. Each vehicle has an `id`, its point `x`, `y`, and its badge's
 * `badgeWidth` or null for a vehicle with no badge. A badge stands on its
 * glyph's shoulder and is left out where it would cover another vehicle's
 * glyph or a badge placed before it, so of two crowded vehicles the one
 * given first keeps its badge; the glyph stays and tells the status.
 */
export function placedBadges(vehicles) {
  assertVehicles(vehicles)
  const obstacles = []

  for (const vehicle of vehicles) {
    obstacles.push({id: vehicle.id, box: glyphBox(vehicle)})
  }

  const placed = new Set()

  for (const vehicle of vehicles) {
    if (hasRouteBadge(vehicle)) {
      assertCondition(vehicle.badgeWidth >= 0, `a badge's width is not negative, got: ${vehicle.badgeWidth}`)
      const box = routeBadgeBox(vehicle)

      if (!overlapsOther({box, id: vehicle.id, obstacles})) {
        obstacles.push({id: vehicle.id, box})
        placed.add(vehicle.id)
      }
    }
  }

  return placed
}
