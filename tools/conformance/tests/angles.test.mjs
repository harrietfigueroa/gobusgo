// Checks the angles module against cases written out by hand: conversions
// of the quarter and half turns, the range normalized angles fall in, the
// smaller turn between two directions across north, and the refusal of an
// angle that is no number.

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const TOLERANCE = 1e-12

const HALVES_PER_WHOLE = 2
const QUARTER_TURN_RADIANS = Math.PI / HALVES_PER_WHOLE
const SEATTLE_LATITUDE = 47.6062
const DEGREES_PER_HALF_TURN = 180

const conversionCases = [
  {name: "no angle", degrees: 0, radians: 0},
  {name: "a quarter turn", degrees: 90, radians: QUARTER_TURN_RADIANS},
  {name: "a half turn", degrees: 180, radians: Math.PI},
  {name: "a quarter turn back", degrees: -90, radians: -QUARTER_TURN_RADIANS}
]

const normalizedCases = [
  {name: "north", degrees: 0, normalized: 0},
  {name: "a whole turn", degrees: 360, normalized: 0},
  {name: "a quarter turn back", degrees: -90, normalized: 270},
  {name: "two turns and a bit", degrees: 725, normalized: 5},
  {name: "a whole turn back", degrees: -360, normalized: 0}
]

const turnCases = [
  {name: "no turn", from: 10, to: 10, turn: 0},
  {name: "across north clockwise", from: 350, to: 10, turn: 20},
  {name: "across north counterclockwise", from: 10, to: 350, turn: 20},
  {name: "a half turn", from: 0, to: 180, turn: 180},
  {name: "from below zero", from: -30, to: 30, turn: 60}
]

describe.each(IMPLEMENTATIONS)("angles ($name)", ({AssertionError, angles}) => {
  test.each(conversionCases)("$name in radians", ({degrees, radians}) => {
    expect(Math.abs(angles.radians(degrees) - radians)).toBeLessThanOrEqual(TOLERANCE)
  })

  test.each(conversionCases)("$name in degrees", ({degrees, radians}) => {
    expect(Math.abs(angles.degrees(radians) - degrees)).toBeLessThanOrEqual(TOLERANCE)
  })

  // A conversion multiplies before it divides, so it gives the bits of
  // `degrees * Math.PI / 180`.
  test("Seattle's latitude in radians", () => {
    expect(angles.radians(SEATTLE_LATITUDE)).toBe(SEATTLE_LATITUDE * Math.PI / DEGREES_PER_HALF_TURN)
  })

  test("the half turn constant", () => {
    expect(angles.DEGREES_PER_HALF_TURN).toBe(DEGREES_PER_HALF_TURN)
  })

  test.each(normalizedCases)("normalized: $name", ({degrees, normalized}) => {
    expect(angles.normalizedDegrees(degrees)).toBe(normalized)
  })

  test.each(turnCases)("turn: $name", ({from, to, turn}) => {
    expect(angles.turnDegrees({from, to})).toBe(turn)
  })

  test("radians of no number", () => {
    expect(() => angles.radians(Number.NaN)).toThrow(AssertionError)
  })

  test("an endless angle", () => {
    expect(() => angles.normalizedDegrees(Number.POSITIVE_INFINITY)).toThrow(AssertionError)
  })
})
