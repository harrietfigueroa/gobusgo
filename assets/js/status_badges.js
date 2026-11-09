// The marks the map draws beside a vehicle and in place of a shared
// vehicle's dot, so a status or a kind is told by a shape and a letter as
// well as a color. Each mark is drawn by one function onto any canvas it is
// handed, at a corner it is given: a MapLibre image and a canvas drawn over
// the map draw the same mark. Nothing here reads the document.

import {assertCondition} from "./assert.js"

/** The badge of a status a recent report lacks, as the server names it. */
export const BadgeKind = Object.freeze({clock: "clock", question: "question", timetable: "timetable"})

/** The kinds of image a name read by `parseImageName` names. */
export const ImageNameKind = Object.freeze({badge: "badge", sharedVehicle: "sharedVehicle", other: "other"})

/** The side of a badge's and a shared vehicle's square, in CSS pixels. */
export const MARK_SIZE_PIXELS = 14

const HALVING_DIVISOR = 2
const CENTER = MARK_SIZE_PIXELS / HALVING_DIVISOR
const BADGE_RADIUS = 6.5
const SHARED_VEHICLE_RADIUS = 6
const HALF_TURN = Math.PI
const FULL_TURN = HALF_TURN + HALF_TURN
const GLYPH_LINE_WIDTH = 1.4
const CLOCK_FACE_RADIUS = 3.6
const CLOCK_HOUR_HAND_TOP = 4.6
const CLOCK_MINUTE_HAND_X = 8.8
const CLOCK_MINUTE_HAND_Y = 7.8
const QUESTION_FONT = "bold 10px system-ui, sans-serif"
const QUESTION_BASELINE_OFFSET = 0.5
const TIMETABLE_LEFT = 3.8
const TIMETABLE_TOP = 4.4
const TIMETABLE_WIDTH = 6.4
const TIMETABLE_HEIGHT = 5.6
const TIMETABLE_HEADER = 6.4
const TIMETABLE_RING_LEFT = 5.6
const TIMETABLE_RING_RIGHT = 8.4
const TIMETABLE_RINGS = [TIMETABLE_RING_LEFT, TIMETABLE_RING_RIGHT]
const TIMETABLE_RING_TOP = 3.4
const TIMETABLE_RING_BOTTOM = 5
const VEHICLE_STROKE_WIDTH = 1.2
const LETTER_FONT = "bold 8px system-ui, sans-serif"
const LETTER_HALO_WIDTH = 2.2
const LETTER_BASELINE_OFFSET = 0.5
const LOW_RANGE_FILL = "#ffffff"
const LETTER_COLOR = "#ffffff"
const LOW_RANGE_LETTER_COLOR = "#0f172a"
const BADGE_IMAGE_PREFIX = "vehicle-status-badge"
const SHARED_VEHICLE_IMAGE_PREFIX = "shared-vehicle"
const NAME_SEPARATOR = "|"
const LOW_RANGE_TEXT = "low"
const IN_RANGE_TEXT = "full"
const badges = Object.values(BadgeKind)

function drawClock(canvas, {x, y}) {
  const context = canvas.getContext("2d")
  context.beginPath()
  context.arc(x + CENTER, y + CENTER, CLOCK_FACE_RADIUS, 0, FULL_TURN)
  context.stroke()
  context.beginPath()
  context.moveTo(x + CENTER, y + CENTER)
  context.lineTo(x + CENTER, y + CLOCK_HOUR_HAND_TOP)
  context.moveTo(x + CENTER, y + CENTER)
  context.lineTo(x + CLOCK_MINUTE_HAND_X, y + CLOCK_MINUTE_HAND_Y)
  context.stroke()
}

function drawQuestion(canvas, {x, y}) {
  const context = canvas.getContext("2d")
  context.font = QUESTION_FONT
  context.textAlign = "center"
  context.textBaseline = "middle"
  context.fillText("?", x + CENTER, y + CENTER + QUESTION_BASELINE_OFFSET)
}

function drawTimetable(canvas, {x, y}) {
  const context = canvas.getContext("2d")
  context.strokeRect(x + TIMETABLE_LEFT, y + TIMETABLE_TOP, TIMETABLE_WIDTH, TIMETABLE_HEIGHT)
  context.beginPath()
  context.moveTo(x + TIMETABLE_LEFT, y + TIMETABLE_HEADER)
  context.lineTo(x + TIMETABLE_LEFT + TIMETABLE_WIDTH, y + TIMETABLE_HEADER)

  for (const ring of TIMETABLE_RINGS) {
    context.moveTo(x + ring, y + TIMETABLE_RING_TOP)
    context.lineTo(x + ring, y + TIMETABLE_RING_BOTTOM)
  }

  context.stroke()
}

/**
 * Draws the badge `badge`, a `BadgeKind`, onto `canvas` in the square
 * whose top left corner is `x`, `y`: a disc in `ink` with the badge's glyph
 * in `paper`.
 */
export function drawStatusBadge(canvas, {badge, ink, paper, x, y}) {
  assertCondition(badges.includes(badge), `a badge is one of ${badges.join(", ")}, got: ${badge}`)
  const context = canvas.getContext("2d")
  context.fillStyle = ink
  context.beginPath()
  context.arc(x + CENTER, y + CENTER, BADGE_RADIUS, 0, FULL_TURN)
  context.fill()
  context.fillStyle = paper
  context.strokeStyle = paper
  context.lineWidth = GLYPH_LINE_WIDTH
  context.lineCap = "round"

  switch (badge) {
    case BadgeKind.clock:
      drawClock(canvas, {x, y})
      break
    case BadgeKind.question:
      drawQuestion(canvas, {x, y})
      break
    case BadgeKind.timetable:
      drawTimetable(canvas, {x, y})
      break
  }
}

/**
 * Draws a shared vehicle onto `canvas` in the square whose top left corner
 * is `x`, `y`: a disc in its kind's `color`, edged in `stroke`, with the
 * kind's `letter`; a low-range vehicle has the upper half of its disc white
 * and its letter dark.
 */
export function drawSharedVehicle(canvas, {color, letter, isLowRange, stroke, x, y}) {
  assertCondition(letter.length === 1, `a kind's letter is one character, got: ${letter}`)
  const context = canvas.getContext("2d")
  context.fillStyle = color
  context.beginPath()
  context.arc(x + CENTER, y + CENTER, SHARED_VEHICLE_RADIUS, 0, FULL_TURN)
  context.fill()
  let letterColor = LETTER_COLOR
  let haloColor = color

  if (isLowRange) {
    context.fillStyle = LOW_RANGE_FILL
    context.beginPath()
    context.arc(x + CENTER, y + CENTER, SHARED_VEHICLE_RADIUS, HALF_TURN, 0)
    context.fill()
    letterColor = LOW_RANGE_LETTER_COLOR
    haloColor = LOW_RANGE_FILL
  }

  context.strokeStyle = stroke
  context.lineWidth = VEHICLE_STROKE_WIDTH
  context.beginPath()
  context.arc(x + CENTER, y + CENTER, SHARED_VEHICLE_RADIUS, 0, FULL_TURN)
  context.stroke()
  context.font = LETTER_FONT
  context.textAlign = "center"
  context.textBaseline = "middle"
  context.lineWidth = LETTER_HALO_WIDTH
  context.strokeStyle = haloColor
  context.strokeText(letter, x + CENTER, y + CENTER + LETTER_BASELINE_OFFSET)
  context.fillStyle = letterColor
  context.fillText(letter, x + CENTER, y + CENTER + LETTER_BASELINE_OFFSET)
}

/** The name of the map image of `badge` drawn in `theme`. */
export function badgeImageName({badge, theme}) {
  return [BADGE_IMAGE_PREFIX, badge, theme].join(NAME_SEPARATOR)
}

function rangeText(isLowRange) {
  if (isLowRange) {
    return LOW_RANGE_TEXT
  }

  return IN_RANGE_TEXT
}

/** The name of the map image of a shared vehicle of `formFactor` drawn in `theme`. */
export function sharedVehicleImageName({formFactor, isLowRange, theme}) {
  return [SHARED_VEHICLE_IMAGE_PREFIX, formFactor, rangeText(isLowRange), theme].join(NAME_SEPARATOR)
}

/** What the map image named `name` shows: a badge, a shared vehicle, or another image. */
export function parseImageName(name) {
  const parts = name.split(NAME_SEPARATOR)
  const isBadge = parts[0] === BADGE_IMAGE_PREFIX
  const isSharedVehicle = parts[0] === SHARED_VEHICLE_IMAGE_PREFIX

  if (isBadge) {
    const [, badge, theme] = parts
    return {kind: ImageNameKind.badge, badge, theme}
  } else if (isSharedVehicle) {
    const [, formFactor, range, theme] = parts
    return {kind: ImageNameKind.sharedVehicle, formFactor, isLowRange: range === LOW_RANGE_TEXT, theme}
  } else {
    return {kind: ImageNameKind.other}
  }
}
