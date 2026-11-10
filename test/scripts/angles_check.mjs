// Checks the angles module against cases written out by hand: conversions
// of the quarter and half turns, the range normalized angles fall in, the
// smaller turn between two directions across north, and the refusal of an
// angle that is no number. Run it with `node test/scripts/angles_check.mjs`;
// it exits non-zero on the first case that differs.

import {ok, strictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {DEGREES_PER_HALF_TURN, degrees, normalizedDegrees, radians, turnDegrees} from "../../assets/js/math/angles.js"

const TOLERANCE = 1e-12

function near({actual, expected, message}) {
  ok(Math.abs(actual - expected) <= TOLERANCE, `${message}: ${actual} is not ${expected}`)
}

const HALVES_PER_WHOLE = 2
const QUARTER_TURN_RADIANS = Math.PI / HALVES_PER_WHOLE
const SEATTLE_LATITUDE = 47.6062

const conversionCases = [
  {name: "no angle", degrees: 0, radians: 0},
  {name: "a quarter turn", degrees: 90, radians: QUARTER_TURN_RADIANS},
  {name: "a half turn", degrees: 180, radians: Math.PI},
  {name: "a quarter turn back", degrees: -90, radians: -QUARTER_TURN_RADIANS}
]

for (const conversion of conversionCases) {
  near({actual: radians(conversion.degrees), expected: conversion.radians, message: `${conversion.name} in radians`})
  near({actual: degrees(conversion.radians), expected: conversion.degrees, message: `${conversion.name} in degrees`})
}

// A conversion multiplies before it divides, so it gives the bits of
// `degrees * Math.PI / 180`.
strictEqual(radians(SEATTLE_LATITUDE), SEATTLE_LATITUDE * Math.PI / DEGREES_PER_HALF_TURN, "Seattle's latitude in radians")

const normalizedCases = [
  {name: "north", degrees: 0, normalized: 0},
  {name: "a whole turn", degrees: 360, normalized: 0},
  {name: "a quarter turn back", degrees: -90, normalized: 270},
  {name: "two turns and a bit", degrees: 725, normalized: 5},
  {name: "a whole turn back", degrees: -360, normalized: 0}
]

for (const {name, degrees: angle, normalized} of normalizedCases) {
  strictEqual(normalizedDegrees(angle), normalized, name)
}

const turnCases = [
  {name: "no turn", from: 10, to: 10, turn: 0},
  {name: "across north clockwise", from: 350, to: 10, turn: 20},
  {name: "across north counterclockwise", from: 10, to: 350, turn: 20},
  {name: "a half turn", from: 0, to: 180, turn: 180},
  {name: "from below zero", from: -30, to: 30, turn: 60}
]

for (const {name, from, to, turn} of turnCases) {
  strictEqual(turnDegrees({from, to}), turn, name)
}

throws(radiansOfNoNumber, AssertionError, "radians of no number")
throws(normalizedEndlessAngle, AssertionError, "an endless angle")

function radiansOfNoNumber() {
  radians(Number.NaN)
}

function normalizedEndlessAngle() {
  normalizedDegrees(Number.POSITIVE_INFINITY)
}

console.log("angles: every case holds")
