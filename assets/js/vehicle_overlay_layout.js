// Where the canvas over the map draws the vehicles it is handed, as pure
// functions of their points on the screen: which vehicles are drawn, which
// one a click is on, which stand inside a box, where a marker's badge
// stands, which way a pointed marker turns, and which route labels are
// drawn. Every length is in CSS pixels, and nothing here reads the document
// or the map, which lets it be run apart from both.

import {assertCondition} from "./assert.js"
import {MARKER_RADIUS_PIXELS, POINTED_TIP_DISTANCE_PIXELS} from "./vehicle_marker_shapes.js"
import {MARK_SIZE_PIXELS} from "./status_badges.js"

/** How far from a drawn marker's center a click still opens it. */
export const HIT_RADIUS_PIXELS = 12

/** The most vehicles the canvas is handed at once. */
export const VEHICLE_COUNT_MAX = 100

/** The size of a route label's text. */
export const LABEL_TEXT_SIZE_PIXELS = 11

/** How far below a marker's center its label's top stands: one line of the label's text. */
export const LABEL_OFFSET_PIXELS = LABEL_TEXT_SIZE_PIXELS

/** The kinds of the vehicle a click is on: one, or none within reach. */
export const HitKind = Object.freeze({found: "found", missing: "missing"})

// A marker's center may stand this far outside the canvas while some of its
// marker, its badge, or its label is still inside it.
const DRAWN_MARGIN_PIXELS = 48
// The badge's lower left corner stands this far inside the marker's edge,
// right of and above its center, so the badge sits on its upper right edge.
const BADGE_INSET_PIXELS = 2
const BADGE_OFFSET_PIXELS = MARKER_RADIUS_PIXELS - BADGE_INSET_PIXELS
const LABEL_HEIGHT_PIXELS = 14
// The room a label keeps clear around itself, MapLibre's `text-padding`.
const LABEL_PADDING_PIXELS = 2
const HALVING_DIVISOR = 2
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

/**
 * The vehicles of `drawn` whose points stand inside `box`, a box on the
 * screen as `[[left, top], [right, bottom]]`, edges included.
 */
export function vehiclesInBox({drawn, box}) {
  const [[left, top], [right, bottom]] = box
  assertCondition(left <= right, `a box's left is not past its right, got: ${left}, ${right}`)
  assertCondition(top <= bottom, `a box's top is not below its bottom, got: ${top}, ${bottom}`)
  const inside = []

  for (const vehicle of drawn) {
    const isInsideX = vehicle.x >= left && vehicle.x <= right
    const isInsideY = vehicle.y >= top && vehicle.y <= bottom
    const isInside = isInsideX && isInsideY

    if (isInside) {
      inside.push(vehicle)
    }
  }

  return inside
}

/**
 * The angle, clockwise from the top of the screen, that a pointed marker of
 * `headingDegrees`, clockwise from north, turns to on a map whose bearing is
 * `bearingDegrees`: the heading stays a compass direction on a turned map.
 */
export function screenAngleRadians({headingDegrees, bearingDegrees}) {
  assertCondition(Number.isFinite(headingDegrees), `a heading is a finite number, got: ${headingDegrees}`)
  assertCondition(Number.isFinite(bearingDegrees), `a bearing is a finite number, got: ${bearingDegrees}`)
  return ((headingDegrees - bearingDegrees) * Math.PI) / DEGREES_PER_HALF_TURN
}

/** The top left corner of the badge of a marker centered on `x`, `y`: its lower left corner on the marker's upper right edge. */
export function badgeCorner({x, y}) {
  return {x: x + BADGE_OFFSET_PIXELS, y: y - BADGE_OFFSET_PIXELS - MARK_SIZE_PIXELS}
}

// The box a marker can reach: a pointed marker's tip turns to any side.
function markerBox({x, y}) {
  return {
    left: x - POINTED_TIP_DISTANCE_PIXELS,
    top: y - POINTED_TIP_DISTANCE_PIXELS,
    right: x + POINTED_TIP_DISTANCE_PIXELS,
    bottom: y + POINTED_TIP_DISTANCE_PIXELS
  }
}

function badgeBox(vehicle) {
  const corner = badgeCorner(vehicle)
  return {left: corner.x, top: corner.y, right: corner.x + MARK_SIZE_PIXELS, bottom: corner.y + MARK_SIZE_PIXELS}
}

function labelBox({x, y, labelWidth}) {
  const halfWidth = labelWidth / HALVING_DIVISOR
  const top = y + LABEL_OFFSET_PIXELS

  return {
    left: x - halfWidth - LABEL_PADDING_PIXELS,
    top: top - LABEL_PADDING_PIXELS,
    right: x + halfWidth + LABEL_PADDING_PIXELS,
    bottom: top + LABEL_HEIGHT_PIXELS + LABEL_PADDING_PIXELS
  }
}

function overlaps(first, second) {
  const isApartX = first.right <= second.left || second.right <= first.left
  const isApartY = first.bottom <= second.top || second.bottom <= first.top
  const isApart = isApartX || isApartY
  return !isApart
}

// Whether `box` overlaps a box of `obstacles` that belongs to another
// vehicle than `id`: a label stands under its own marker by design.
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

function hasLabel(vehicle) {
  return vehicle.labelWidth !== null
}

/**
 * The identifiers of the vehicles of `vehicles` whose route labels are
 * drawn. Each vehicle has an `id`, its point `x`, `y`, its label's
 * `labelWidth` or null for a vehicle with no label, and `hasBadge`. A label
 * stands centered under its marker, `LABEL_OFFSET_PIXELS` below its center,
 * and is left out where it would cover another vehicle's marker or badge,
 * or a label placed before it, so of two crowded vehicles the one given
 * first keeps its label.
 */
export function placedLabels(vehicles) {
  assertVehicles(vehicles)
  const obstacles = []

  for (const vehicle of vehicles) {
    obstacles.push({id: vehicle.id, box: markerBox(vehicle)})

    if (vehicle.hasBadge) {
      obstacles.push({id: vehicle.id, box: badgeBox(vehicle)})
    }
  }

  const placed = new Set()

  for (const vehicle of vehicles) {
    if (hasLabel(vehicle)) {
      assertCondition(vehicle.labelWidth >= 0, `a label's width is not negative, got: ${vehicle.labelWidth}`)
      const box = labelBox(vehicle)

      if (!overlapsOther({box, id: vehicle.id, obstacles})) {
        obstacles.push({id: vehicle.id, box})
        placed.add(vehicle.id)
      }
    }
  }

  return placed
}
