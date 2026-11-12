// Checks the interpolation module against cases written out by hand: the
// two ends and the middle of a line, a fraction past the end, a clamp
// below, inside, and above its bounds, and the refusal of bounds out of
// order and of a value or fraction that is no number. Run it with
// `node test/scripts/interpolation_check.mjs`; it exits non-zero on the
// first case that differs.

import {strictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {clamp, lerp} from "../../assets/js/core/math/interpolation.js"

const lerpCases = [
  {name: "the start", from: 10, to: 30, fraction: 0, value: 10},
  {name: "the end", from: 10, to: 30, fraction: 1, value: 30},
  {name: "the middle", from: 10, to: 30, fraction: 0.5, value: 20},
  {name: "backward", from: 30, to: 10, fraction: 0.25, value: 25},
  {name: "past the end", from: 10, to: 30, fraction: 1.5, value: 40}
]

for (const {name, from, to, fraction, value} of lerpCases) {
  strictEqual(lerp({from, to, fraction}), value, name)
}

const clampCases = [
  {name: "below", value: -5, min: 0, max: 10, clamped: 0},
  {name: "inside", value: 4, min: 0, max: 10, clamped: 4},
  {name: "above", value: 15, min: 0, max: 10, clamped: 10},
  {name: "bounds that meet", value: 15, min: 3, max: 3, clamped: 3}
]

for (const {name, value, min, max, clamped} of clampCases) {
  strictEqual(clamp({value, min, max}), clamped, name)
}

throws(clampOutOfOrder, AssertionError, "bounds out of order")
throws(clampNoNumber, AssertionError, "a value that is no number")
throws(lerpNoFraction, AssertionError, "a fraction that is no number")

function clampOutOfOrder() {
  clamp({value: 1, min: 10, max: 0})
}

function clampNoNumber() {
  clamp({value: Number.NaN, min: 0, max: 1})
}

function lerpNoFraction() {
  lerp({from: 0, to: 1, fraction: Number.NaN})
}

console.log("interpolation: every case holds")
