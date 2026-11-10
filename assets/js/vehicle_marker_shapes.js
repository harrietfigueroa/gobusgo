// The two shapes of a vehicle's marker, each drawn by one function onto any
// canvas it is handed: the map's pointed image and the canvas drawn over
// the map draw the same shape. Nothing here reads the document.

import {assertCondition} from "./assert.js"

/** The radius of a marker's circle, in CSS pixels. */
export const MARKER_RADIUS_PIXELS = 6

/** The width of the line around a marker, in CSS pixels. */
export const MARKER_STROKE_WIDTH_PIXELS = 1.5

/** How far a pointed marker's tip stands from its center, in CSS pixels. */
export const POINTED_TIP_DISTANCE_PIXELS = 12

const HALVING_DIVISOR = 2
const FULL_TURN = Math.PI * HALVING_DIVISOR
const UP = -Math.PI / HALVING_DIVISOR
// The angle at the circle's center between the tip and each point where a
// line from the tip touches the circle.
const TANGENT_ANGLE = Math.acos(MARKER_RADIUS_PIXELS / POINTED_TIP_DISTANCE_PIXELS)

/** Draws a round marker onto `canvas`: a circle in `color` centered on `x`, `y`, outlined in `strokeColor`. */
export function drawRoundMarker(canvas, {x, y, color, strokeColor}) {
  const context = canvas.getContext("2d")
  context.beginPath()
  context.arc(x, y, MARKER_RADIUS_PIXELS, 0, FULL_TURN)
  context.fillStyle = color
  context.fill()
  context.lineJoin = "round"
  context.lineWidth = MARKER_STROKE_WIDTH_PIXELS
  context.strokeStyle = strokeColor
  context.stroke()
}

/**
 * Draws a pointed marker onto `canvas`: the round marker's circle centered
 * on `x`, `y`, drawn out to a tip turned `angleRadians` clockwise from the
 * top of the canvas, in `color` and outlined in `strokeColor`.
 */
export function drawPointedMarker(canvas, {x, y, angleRadians, color, strokeColor}) {
  assertCondition(Number.isFinite(angleRadians), `a marker's angle is a finite number, got: ${angleRadians}`)
  const context = canvas.getContext("2d")
  context.save()
  context.translate(x, y)
  context.rotate(angleRadians)
  context.beginPath()
  context.moveTo(0, -POINTED_TIP_DISTANCE_PIXELS)
  context.arc(0, 0, MARKER_RADIUS_PIXELS, UP + TANGENT_ANGLE, UP - TANGENT_ANGLE)
  context.closePath()
  context.fillStyle = color
  context.fill()
  context.lineJoin = "round"
  context.lineWidth = MARKER_STROKE_WIDTH_PIXELS
  context.strokeStyle = strokeColor
  context.stroke()
  context.restore()
}
