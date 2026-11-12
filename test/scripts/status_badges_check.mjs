// Checks the status badge and shared vehicle drawing against a canvas whose
// context records what it is told: each badge's disc is in the ink and its glyph in the paper, the
// three glyphs differ, an unknown badge is refused, a low-range vehicle has
// its upper half white and a dark letter, and every image name reads back
// as the badge or vehicle it names. Run it with
// `node test/scripts/status_badges_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, notDeepStrictEqual, ok, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {
  BadgeKind,
  ImageNameKind,
  badgeImageName,
  drawSharedVehicle,
  drawStatusBadge,
  parseImageName,
  sharedVehicleImageName
} from "../../assets/js/status_badges.js"

const INK = "#0f172a"
const PAPER = "#ffffff"
const WHITE = "#ffffff"
const SCOOTER_COLOR = "#0f766e"
const STROKE = "#334155"
const GLYPH_CALL_NAMES = ["stroke", "strokeRect", "fillText"]
const THEMES = ["light", "dark"]

// A canvas whose context records each call with the colors set when it was
// made. The state is the context's own; setting a property stores it there.
function recordingCanvas() {
  const calls = []
  const state = {fillStyle: "", strokeStyle: ""}
  // A proxy's traps take their arguments by position; no call site here
  // writes their argument lists.
  const handler = {
    get(target, name) {
      if (Object.hasOwn(target, name)) {
        return target[name]
      }

      return function recordCall(...args) {
        calls.push({name, args, fillStyle: target.fillStyle, strokeStyle: target.strokeStyle})
      }
    },
    set: Reflect.set
  }
  const context = new Proxy(state, handler)
  const canvas = {getContext: function getContext() { return context }}
  return {canvas, calls}
}

function callName(call) {
  return call.name
}

function isFill(call) {
  return call.name === "fill"
}

function isFillText(call) {
  return call.name === "fillText"
}

function isGlyphCall(call) {
  return GLYPH_CALL_NAMES.includes(call.name)
}

function fillStyleOf(call) {
  return call.fillStyle
}

// The color a glyph call draws in: its stroke's for a line, its fill's for text.
function glyphColor(call) {
  if (call.name === "fillText") {
    return call.fillStyle
  }

  return call.strokeStyle
}

function badgeCalls(badge) {
  const {canvas, calls} = recordingCanvas()
  drawStatusBadge(canvas, {badge, ink: INK, paper: PAPER, x: 0, y: 0})
  return calls
}

function badgeCallNames(badge) {
  const calls = badgeCalls(badge)
  return Array.from(calls, callName)
}

for (const badge of Object.values(BadgeKind)) {
  const calls = badgeCalls(badge)
  const fills = calls.filter(isFill)
  deepStrictEqual(fills[0].fillStyle, INK, `the ${badge} badge's disc is in the ink`)
  const glyphCalls = calls.filter(isGlyphCall)
  ok(glyphCalls.length > 0, `the ${badge} badge draws a glyph`)

  for (const call of glyphCalls) {
    deepStrictEqual(glyphColor(call), PAPER, `the ${badge} badge's glyph is in the paper`)
  }
}

const clockNames = badgeCallNames(BadgeKind.clock)
const questionNames = badgeCallNames(BadgeKind.question)
const timetableNames = badgeCallNames(BadgeKind.timetable)
notDeepStrictEqual(clockNames, questionNames, "the clock and the question mark differ")
notDeepStrictEqual(clockNames, timetableNames, "the clock and the timetable differ")
notDeepStrictEqual(questionNames, timetableNames, "the question mark and the timetable differ")

function drawUnknownBadge() {
  badgeCalls("bell")
}

throws(drawUnknownBadge, AssertionError, "an unknown badge is refused")

function vehicleCalls(isLowRange) {
  const {canvas, calls} = recordingCanvas()
  drawSharedVehicle(canvas, {color: SCOOTER_COLOR, letter: "S", isLowRange, stroke: STROKE, x: 0, y: 0})
  return calls
}

const fullCalls = vehicleCalls(false)
const lowCalls = vehicleCalls(true)
const fullFillCalls = fullCalls.filter(isFill)
const lowFillCalls = lowCalls.filter(isFill)
const fullFills = Array.from(fullFillCalls, fillStyleOf)
const lowFills = Array.from(lowFillCalls, fillStyleOf)
deepStrictEqual(fullFills, [SCOOTER_COLOR], "a vehicle in range is one disc in its kind's color")
deepStrictEqual(lowFills, [SCOOTER_COLOR, WHITE], "a low-range vehicle has its upper half white")
const [fullLetter] = fullCalls.filter(isFillText)
const [lowLetter] = lowCalls.filter(isFillText)
deepStrictEqual(fullLetter.args[0], "S", "the letter is drawn")
deepStrictEqual(fullLetter.fillStyle, WHITE, "a vehicle in range has a white letter")
deepStrictEqual(lowLetter.fillStyle, INK, "a low-range vehicle has a dark letter")

for (const badge of Object.values(BadgeKind)) {
  for (const theme of THEMES) {
    const name = badgeImageName({badge, theme})
    deepStrictEqual(parseImageName(name), {kind: ImageNameKind.badge, badge, theme}, `the name ${name}`)
  }
}

for (const isLowRange of [false, true]) {
  const name = sharedVehicleImageName({formFactor: "e_bike", isLowRange, theme: "dark"})
  const expected = {kind: ImageNameKind.sharedVehicle, formFactor: "e_bike", isLowRange, theme: "dark"}
  deepStrictEqual(parseImageName(name), expected, `the name ${name}`)
}

deepStrictEqual(parseImageName("vehicle-marker-pointed-#ffffff"), {kind: ImageNameKind.other}, "another image's name")

console.log("status badges check passed")
