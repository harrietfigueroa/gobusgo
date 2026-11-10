// The shapes of a vehicle's marker, each drawn by one function onto any
// canvas it is handed, so the map's images and the canvas drawn over the map
// draw the same shape: a plain dot at regional zoom, and closer in a bus
// glyph with a route badge on its shoulder and a chevron for its heading.
// The rules of each status's look are pure functions. Nothing here reads
// the document.

import {assertCondition, unreachable} from "./assert.js"
import {chipTextColor} from "./route_chip_color.js"
import {StrokeOpacityKind} from "./theme.js"

/** The radius of a regional dot, in CSS pixels. */
export const MARKER_RADIUS_PIXELS = 6

/** The width of the line around a regional dot, in CSS pixels. */
export const MARKER_STROKE_WIDTH_PIXELS = 1.5

/** The radius of a bus glyph's disc, in CSS pixels. */
export const GLYPH_RADIUS_PIXELS = 11

/** The side of the square of a glyph's image, in CSS pixels. */
export const GLYPH_IMAGE_SIZE_PIXELS = 26

/** The side of the square of a chevron's image, in CSS pixels. */
export const CHEVRON_SIZE_PIXELS = 12

/** How far a chevron's center stands from its glyph's, toward the heading, in CSS pixels. */
export const CHEVRON_DISTANCE_PIXELS = 19

/** The height of a route badge, in CSS pixels. */
export const BADGE_HEIGHT_PIXELS = 15

/** How far right of and above a glyph's center a badge's lower left corner stands, in CSS pixels. */
export const BADGE_SHOULDER_PIXELS = 6

/** The font a route badge's text is drawn in. */
export const BADGE_FONT = "700 10px system-ui, sans-serif"

/** The prefix of the name of every image of a glyph. */
export const GLYPH_IMAGE_PREFIX = "vehicle-glyph"

const NAME_SEPARATOR = "|"
const HALVING_DIVISOR = 2
const FULL_TURN = Math.PI * HALVING_DIVISOR
const GLYPH_OUTLINE_WIDTH_PIXELS = 2
const GLYPH_BOX_UNITS = 24
const GLYPH_BUS_SIZE_PIXELS = 13
const GLYPH_BUS_STROKE_WIDTH = 2.4
const DASH_LENGTH_PIXELS = 3
const DOT_LENGTH_PIXELS = 1
const OUTLINE_GAP_PIXELS = 2
const DASH_PIXELS = [DASH_LENGTH_PIXELS, OUTLINE_GAP_PIXELS]
const DOT_PIXELS = [DOT_LENGTH_PIXELS, OUTLINE_GAP_PIXELS]
// Half a pixel: a clock's circle stands inside its square by half its
// line, and a badge's text a half pixel below its middle looks centered.
const HALF_PIXEL = 0.5
const CLOCK_LINE_WIDTH_PIXELS = 1.2
const PALE_SHARE = 0.75
const CHANNEL_MAX = 255
const HEX_RADIX = 16
const HEX_PAIR_LENGTH = 2
const BADGE_PADDING_PIXELS = 3
const BADGE_RADIUS_PIXELS = 4
const BADGE_BORDER_WIDTH_PIXELS = 1
const BADGE_MARK_SIZE_PIXELS = 8
const BADGE_MARK_GAP_PIXELS = 2
const CHEVRON_STROKE_WIDTH_PIXELS = 2.5
const CHEVRON_HALO_WIDTH_PIXELS = 5
const STALE_BADGE_FILL = "#0f172a"
const STALE_BADGE_INK = "#ffffff"
const SCHEDULED_FILL = "#ffffff"
const SCHEDULED_INK = "#475569"
const HEX_COLOR_PATTERN = /^#[0-9a-f]{6}$/i
const FULL_OPACITY = 1

// The bus of the glyph, in a box of 24 units: a body with a window line and
// two wheels.
const BUS_BODY = "M7 3h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"
const BUS_LINES = "M5 11h14M8 21v-4M16 21v-4"

/** The kinds of a glyph's outline: solid while live or stale, dotted with no report time, and dashed for schedule only. */
export const OutlineKind = Object.freeze({solid: "solid", dotted: "dotted", dashed: "dashed"})

/** The mark a route badge carries after its text. */
export const BadgeMark = Object.freeze({none: "none", clock: "clock", question: "question"})

/** `color`, written `#rrggbb`, three quarters of the way to white. */
export function paleColor(color) {
  assertCondition(HEX_COLOR_PATTERN.test(color), `a color is written #rrggbb, got: ${color}`)
  let pale = "#"

  for (let index = 1; index < color.length; index += HEX_PAIR_LENGTH) {
    const channel = Number.parseInt(color.slice(index, index + HEX_PAIR_LENGTH), HEX_RADIX)
    const paled = Math.round(channel + (CHANNEL_MAX - channel) * PALE_SHARE)
    pale += paled.toString(HEX_RADIX).padStart(HEX_PAIR_LENGTH, "0")
  }

  return pale
}

/**
 * The look of the bus glyph of a vehicle of `status` on a route of `color`,
 * in the map colors `colors`: a live bus is filled in its route's color
 * and outlined in the live outline color, a stale one pale in its route's
 * color and outlined dark, one with no report time the same with a dotted
 * outline, and a schedule-only one white with a dashed slate outline, so
 * each status differs by its outline and fill as well as its color.
 */
export function glyphStyle({status, color, colors}) {
  switch (status) {
    case "reported":
      return {fill: color, outline: colors.glyphLiveOutline, outlineKind: OutlineKind.solid, ink: chipTextColor(color)}
    case "stale":
      return {fill: paleColor(color), outline: colors.vehicleStroke, outlineKind: OutlineKind.solid, ink: colors.vehicleStroke}
    case "unknown":
      return {fill: paleColor(color), outline: colors.vehicleStroke, outlineKind: OutlineKind.dotted, ink: colors.vehicleStroke}
    case "scheduled":
      return {fill: SCHEDULED_FILL, outline: SCHEDULED_INK, outlineKind: OutlineKind.dashed, ink: SCHEDULED_INK}
    default:
      return unreachable(status, "a vehicle's status")
  }
}

/**
 * The route badge on the shoulder of a vehicle of `status` on the route
 * named `route`, or null for none, of `color`, in the map colors `colors`:
 * the route's number in its route's color while live, white and slate for
 * schedule only, and dark with a clock while stale or a question mark with
 * no report time, each but the schedule-only one bordered in the colors'
 * route badge border.
 */
export function routeBadgeStyle({status, route, color, colors}) {
  let text = ""

  if (typeof route === "string") {
    text = route
  }

  switch (status) {
    case "reported":
      return {text, mark: BadgeMark.none, fill: color, ink: chipTextColor(color), border: colors.routeBadgeBorder}
    case "stale":
      return {text, mark: BadgeMark.clock, fill: STALE_BADGE_FILL, ink: STALE_BADGE_INK, border: colors.routeBadgeBorder}
    case "unknown":
      return {text, mark: BadgeMark.question, fill: STALE_BADGE_FILL, ink: STALE_BADGE_INK, border: colors.routeBadgeBorder}
    case "scheduled":
      return {text, mark: BadgeMark.none, fill: SCHEDULED_FILL, ink: SCHEDULED_INK, border: SCHEDULED_INK}
    default:
      return unreachable(status, "a vehicle's status")
  }
}

/** Whether an image's name is a glyph's. */
export const GlyphImageKind = Object.freeze({glyph: "glyph", other: "other"})

const parts = Object.freeze(["glyph", "badge", "chevron"])
const themes = Object.freeze(["light", "dark"])

/** The name of the image of a glyph's `part` for a vehicle of `status` on a route of `color` named `route`, in `theme`. */
export function glyphImageName({part, status, color, theme, route}) {
  return [GLYPH_IMAGE_PREFIX, part, status, color, theme, route].join(NAME_SEPARATOR)
}

/** The part, status, color, theme, and route a glyph image's `name` holds, or other for any other image. */
export function parseGlyphImageName(name) {
  const fields = name.split(NAME_SEPARATOR)

  if (fields[0] !== GLYPH_IMAGE_PREFIX) {
    return {kind: GlyphImageKind.other}
  }

  const [, part, status, color, theme, ...routeFields] = fields
  assertCondition(parts.includes(part), `a glyph image names a part, got: ${part}`)
  assertCondition(themes.includes(theme), `a glyph image names a theme, got: ${theme}`)
  return {kind: GlyphImageKind.glyph, part, status, color, theme, route: routeFields.join(NAME_SEPARATOR)}
}

/**
 * The opacity of the stroke of a regional dot of `opacity` in the map colors
 * `colors`: whole where the colors keep the stroke whole, and the dot's own
 * otherwise. `opacity` is a number or a paint expression that gives one.
 */
export function dotStrokeOpacity({opacity, colors}) {
  switch (colors.vehicleStrokeOpacity) {
    case StrokeOpacityKind.full:
      return FULL_OPACITY
    case StrokeOpacityKind.marker:
      return opacity
    default:
      return unreachable(colors.vehicleStrokeOpacity, "a stroke's opacity kind")
  }
}

/**
 * Draws a regional dot onto `canvas`: a circle in `color` at `fillOpacity`
 * centered on `x`, `y`, outlined in `strokeColor` at `strokeOpacity`.
 */
export function drawRoundMarker(canvas, {x, y, color, fillOpacity, strokeColor, strokeOpacity}) {
  const context = canvas.getContext("2d")
  context.save()
  context.beginPath()
  context.arc(x, y, MARKER_RADIUS_PIXELS, 0, FULL_TURN)
  context.globalAlpha = fillOpacity
  context.fillStyle = color
  context.fill()
  context.lineJoin = "round"
  context.lineWidth = MARKER_STROKE_WIDTH_PIXELS
  context.globalAlpha = strokeOpacity
  context.strokeStyle = strokeColor
  context.stroke()
  context.restore()
}

function lineDash(outlineKind) {
  switch (outlineKind) {
    case OutlineKind.solid:
      return []
    case OutlineKind.dotted:
      return DOT_PIXELS
    case OutlineKind.dashed:
      return DASH_PIXELS
    default:
      return unreachable(outlineKind, "an outline kind")
  }
}

/** Draws a bus glyph of `style`, a `glyphStyle`, onto `canvas`, centered on `x`, `y`. */
export function drawBusGlyph(canvas, {x, y, style}) {
  const context = canvas.getContext("2d")
  context.save()
  context.beginPath()
  context.arc(x, y, GLYPH_RADIUS_PIXELS, 0, FULL_TURN)
  context.fillStyle = style.fill
  context.fill()
  context.lineWidth = GLYPH_OUTLINE_WIDTH_PIXELS
  context.strokeStyle = style.outline
  context.setLineDash(lineDash(style.outlineKind))
  context.stroke()
  context.setLineDash([])

  const scale = GLYPH_BUS_SIZE_PIXELS / GLYPH_BOX_UNITS
  const half = GLYPH_BUS_SIZE_PIXELS / HALVING_DIVISOR
  context.translate(x - half, y - half)
  context.scale(scale, scale)
  context.lineWidth = GLYPH_BUS_STROKE_WIDTH
  context.lineCap = "round"
  context.lineJoin = "round"
  context.strokeStyle = style.ink
  context.stroke(new Path2D(BUS_BODY))
  context.stroke(new Path2D(BUS_LINES))
  context.restore()
}

/**
 * Draws a chevron pointing up onto `canvas`, in a square of
 * `CHEVRON_SIZE_PIXELS` at its top left, in `color` over a `halo`.
 */
export function drawChevron(canvas, {color, halo}) {
  const context = canvas.getContext("2d")
  const middle = CHEVRON_SIZE_PIXELS / HALVING_DIVISOR
  const top = CHEVRON_SIZE_PIXELS / HALVING_DIVISOR - BADGE_MARK_GAP_PIXELS
  const bottom = CHEVRON_SIZE_PIXELS - BADGE_MARK_GAP_PIXELS
  const left = BADGE_MARK_GAP_PIXELS
  const right = CHEVRON_SIZE_PIXELS - BADGE_MARK_GAP_PIXELS
  context.save()
  context.lineCap = "round"
  context.lineJoin = "round"

  for (const [width, strokeColor] of [[CHEVRON_HALO_WIDTH_PIXELS, halo], [CHEVRON_STROKE_WIDTH_PIXELS, color]]) {
    context.beginPath()
    context.moveTo(left, bottom - BADGE_MARK_GAP_PIXELS)
    context.lineTo(middle, top - BADGE_MARK_GAP_PIXELS)
    context.lineTo(right, bottom - BADGE_MARK_GAP_PIXELS)
    context.lineWidth = width
    context.strokeStyle = strokeColor
    context.stroke()
  }

  context.restore()
}

function markWidth(mark) {
  if (mark === BadgeMark.none) {
    return 0
  }

  return BADGE_MARK_SIZE_PIXELS
}

/** The width of the badge of `badge`, a `routeBadgeStyle`, with `measure` giving a text's width in `BADGE_FONT`. */
export function badgeWidth({badge, measure}) {
  const textWidth = Math.ceil(measure(badge.text))
  const mark = markWidth(badge.mark)
  const isBoth = textWidth > 0 && mark > 0
  let gap = 0

  if (isBoth) {
    gap = BADGE_MARK_GAP_PIXELS
  }

  return textWidth + gap + mark + BADGE_PADDING_PIXELS * HALVING_DIVISOR
}

function drawClock(canvas, {x, y, ink}) {
  const context = canvas.getContext("2d")
  const radius = BADGE_MARK_SIZE_PIXELS / HALVING_DIVISOR - HALF_PIXEL
  context.beginPath()
  context.arc(x, y, radius, 0, FULL_TURN)
  context.moveTo(x, y - radius + BADGE_MARK_GAP_PIXELS)
  context.lineTo(x, y)
  context.lineTo(x + BADGE_MARK_GAP_PIXELS, y)
  context.lineWidth = CLOCK_LINE_WIDTH_PIXELS
  context.strokeStyle = ink
  context.stroke()
}

/** Draws `badge`, a `routeBadgeStyle`, onto `canvas` at its top left, `width` wide, its text in `BADGE_FONT`. */
export function drawRouteBadge(canvas, {badge, width}) {
  const context = canvas.getContext("2d")
  const inset = BADGE_BORDER_WIDTH_PIXELS / HALVING_DIVISOR
  context.beginPath()
  context.roundRect(inset, inset, width - BADGE_BORDER_WIDTH_PIXELS, BADGE_HEIGHT_PIXELS - BADGE_BORDER_WIDTH_PIXELS, BADGE_RADIUS_PIXELS)
  context.fillStyle = badge.fill
  context.fill()
  context.lineWidth = BADGE_BORDER_WIDTH_PIXELS
  context.strokeStyle = badge.border
  context.stroke()

  context.font = BADGE_FONT
  context.textBaseline = "middle"
  context.fillStyle = badge.ink
  const middleY = BADGE_HEIGHT_PIXELS / HALVING_DIVISOR + HALF_PIXEL
  context.fillText(badge.text, BADGE_PADDING_PIXELS, middleY)

  const markX = width - BADGE_PADDING_PIXELS - BADGE_MARK_SIZE_PIXELS / HALVING_DIVISOR

  if (badge.mark === BadgeMark.clock) {
    drawClock(canvas, {x: markX, y: middleY, ink: badge.ink})
  } else if (badge.mark === BadgeMark.question) {
    context.textAlign = "center"
    context.fillText("?", markX, middleY)
    context.textAlign = "start"
  }
}
