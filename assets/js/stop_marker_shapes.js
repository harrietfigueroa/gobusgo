// What a stop's marker draws: a bus-stop sign, an arrow for the stop's
// direction, and the chips of its routes beside it. The rules are pure
// functions of a stop's texts, and each drawing function draws onto the
// canvas it is handed. Nothing here reads the document.

import {assertCondition} from "./core/assert.js"
import {chipTextColor} from "./route_chip_color.js"

/** The side of the square of the sign's image, in CSS pixels. */
export const SIGN_SIZE_PIXELS = 22

/** The side of the square of the arrow's image, in CSS pixels. */
export const ARROW_SIZE_PIXELS = 12

/** The most chips beside a sign, before the chip that counts the rest. */
export const CHIP_COUNT_MAX = 4

/** The prefix of the name of a chips image. */
export const CHIPS_IMAGE_PREFIX = "stop-chips:"

const CHIP_HEIGHT_PIXELS = 16
const CHIP_PADDING_PIXELS = 4
const CHIP_GAP_PIXELS = 2
const CHIP_RADIUS_PIXELS = 3
const CHIP_FONT = "700 11px system-ui, sans-serif"
const SIGN_RADIUS_PIXELS = 5
const SIGN_BORDER_WIDTH_PIXELS = 1.5
const GLYPH_BOX_PIXELS = 24
const GLYPH_SIZE_PIXELS = 14
const GLYPH_STROKE_WIDTH = 2.4
const HALVING_DIVISOR = 2
const themes = Object.freeze(["light", "dark"])

// The bus of the sign, in a box of 24 units: a body with a window line and
// two wheels.
const GLYPH_BODY = "M7 3h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"
const GLYPH_LINES = "M5 11h14M8 21v-4M16 21v-4"

/** Whether a stop's direction has an angle. */
export const AngleKind = Object.freeze({found: "found", missing: "missing"})

const degreesByDirection = Object.freeze({N: 0, NE: 45, E: 90, SE: 135, S: 180, SW: 225, W: 270, NW: 315})

/** The angle of the arrow of a stop's `direction`, in degrees clockwise from north, or missing for none. */
export function directionAngle(direction) {
  const isCompass = typeof direction === "string" && Object.hasOwn(degreesByDirection, direction)

  if (isCompass) {
    return {kind: AngleKind.found, degrees: degreesByDirection[direction]}
  }

  return {kind: AngleKind.missing}
}

/** The compass directions an arrow is drawn for, and their angles, as the pairs of a match expression. */
export function directionAngleCases() {
  const cases = []

  for (const [direction, degrees] of Object.entries(degreesByDirection)) {
    cases.push(direction, degrees)
  }

  return cases
}

/** The sides of the sign the chips stand on. */
export const ChipsSide = Object.freeze({above: "above", below: "below"})

const southward = Object.freeze(["SE", "S", "SW"])

/**
 * The side of the sign a stop's chips stand on: above it for a stop whose
 * arrow points south of east and west, so the arrow below has the room, and
 * below it for any other.
 */
export function chipsSide(direction) {
  if (southward.includes(direction)) {
    return ChipsSide.above
  }

  return ChipsSide.below
}

/** The directions whose chips stand above the sign. */
export function southwardDirections() {
  return [...southward]
}

/**
 * The chips beside a sign, of `chips`, a stop's route chips: the first
 * four, each in its route's color with the text color that contrasts with
 * it, and a chip in `count`'s colors that counts the rest.
 */
export function shownChips({chips, count}) {
  const shown = []

  for (const chip of chips.slice(0, CHIP_COUNT_MAX)) {
    shown.push({text: chip.name, fill: chip.color, ink: chipTextColor(chip.color)})
  }

  if (chips.length > CHIP_COUNT_MAX) {
    shown.push({text: `+${chips.length - CHIP_COUNT_MAX}`, fill: count.fill, ink: count.ink})
  }

  return shown
}

/** The name of the image of a stop's chips in `theme`, from the `routeChips` text of its feature. */
export function chipsImageName({theme, routeChips}) {
  return `${CHIPS_IMAGE_PREFIX}${theme}:${routeChips}`
}

/** Whether an image's name is a chips image's. */
export const ChipsImageKind = Object.freeze({chips: "chips", other: "other"})

function chipOfPair([name, color]) {
  return {name, color}
}

/** The theme and the chips a chips image's `name` holds, or other for any other image. */
export function parseChipsImageName(name) {
  if (!name.startsWith(CHIPS_IMAGE_PREFIX)) {
    return {kind: ChipsImageKind.other}
  }

  const rest = name.slice(CHIPS_IMAGE_PREFIX.length)
  const separatorIndex = rest.indexOf(":")
  const theme = rest.slice(0, separatorIndex)
  assertCondition(themes.includes(theme), `a chips image names a theme, got: ${theme}`)
  const pairs = JSON.parse(rest.slice(separatorIndex + 1))
  assertCondition(Array.isArray(pairs), "a chips image holds a list of pairs")
  return {kind: ChipsImageKind.chips, theme, chips: Array.from(pairs, chipOfPair)}
}

/**
 * Draws a stop's sign onto `canvas`, in a square of `SIGN_SIZE_PIXELS` at
 * its top left: a rounded square in `fill`, outlined in `ink`, with a bus
 * in `ink`.
 */
export function drawStopSign(canvas, {fill, ink}) {
  const context = canvas.getContext("2d")
  const inset = SIGN_BORDER_WIDTH_PIXELS / HALVING_DIVISOR
  const side = SIGN_SIZE_PIXELS - SIGN_BORDER_WIDTH_PIXELS
  context.beginPath()
  context.roundRect(inset, inset, side, side, SIGN_RADIUS_PIXELS)
  context.fillStyle = fill
  context.fill()
  context.lineWidth = SIGN_BORDER_WIDTH_PIXELS
  context.strokeStyle = ink
  context.stroke()

  const scale = GLYPH_SIZE_PIXELS / GLYPH_BOX_PIXELS
  const offset = (SIGN_SIZE_PIXELS - GLYPH_SIZE_PIXELS) / HALVING_DIVISOR
  context.save()
  context.translate(offset, offset)
  context.scale(scale, scale)
  context.lineWidth = GLYPH_STROKE_WIDTH
  context.lineCap = "round"
  context.lineJoin = "round"
  context.strokeStyle = ink
  context.stroke(new Path2D(GLYPH_BODY))
  context.stroke(new Path2D(GLYPH_LINES))
  context.restore()
}

/**
 * Draws an arrow pointing up onto `canvas`, in a square of
 * `ARROW_SIZE_PIXELS` at its top left, in `fill` outlined in `halo`.
 */
export function drawStopArrow(canvas, {fill, halo}) {
  const context = canvas.getContext("2d")
  const middle = ARROW_SIZE_PIXELS / HALVING_DIVISOR
  const edge = ARROW_SIZE_PIXELS - 1
  context.beginPath()
  context.moveTo(middle, 1)
  context.lineTo(edge, edge)
  context.lineTo(middle, edge - middle / HALVING_DIVISOR)
  context.lineTo(1, edge)
  context.closePath()
  context.fillStyle = fill
  context.fill()
  context.lineWidth = 1
  context.lineJoin = "round"
  context.strokeStyle = halo
  context.stroke()
}

/** The size of the image of `shown`, the chips of `shownChips`, with `measure` giving a text's width. */
export function chipsImageSize({shown, measure}) {
  let width = 0

  for (const chip of shown) {
    width += Math.ceil(measure(chip.text)) + CHIP_PADDING_PIXELS * HALVING_DIVISOR
  }

  width += CHIP_GAP_PIXELS * Math.max(shown.length - 1, 0)
  return {width, height: CHIP_HEIGHT_PIXELS}
}

/** The font a chip's text is drawn in. */
export function chipFont() {
  return CHIP_FONT
}

/** Draws `shown`, the chips of `shownChips`, onto `canvas` in a row from its top left. */
export function drawChips(canvas, {shown}) {
  const context = canvas.getContext("2d")
  context.font = CHIP_FONT
  context.textBaseline = "middle"
  let x = 0

  for (const chip of shown) {
    const width = Math.ceil(context.measureText(chip.text).width) + CHIP_PADDING_PIXELS * HALVING_DIVISOR
    context.beginPath()
    context.roundRect(x, 0, width, CHIP_HEIGHT_PIXELS, CHIP_RADIUS_PIXELS)
    context.fillStyle = chip.fill
    context.fill()
    context.fillStyle = chip.ink
    context.fillText(chip.text, x + CHIP_PADDING_PIXELS, CHIP_HEIGHT_PIXELS / HALVING_DIVISOR + 1)
    x += width + CHIP_GAP_PIXELS
  }
}
