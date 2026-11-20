// Checks the interpolation module against cases written out by hand: the
// two ends and the middle of a line, a fraction past the end, a clamp
// below, inside, and above its bounds, and the refusal of bounds out of
// order and of a value or fraction that is no number.

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const lerpCases = [
  {name: "the start", from: 10, to: 30, fraction: 0, value: 10},
  {name: "the end", from: 10, to: 30, fraction: 1, value: 30},
  {name: "the middle", from: 10, to: 30, fraction: 0.5, value: 20},
  {name: "backward", from: 30, to: 10, fraction: 0.25, value: 25},
  {name: "past the end", from: 10, to: 30, fraction: 1.5, value: 40}
]

const clampCases = [
  {name: "below", value: -5, min: 0, max: 10, clamped: 0},
  {name: "inside", value: 4, min: 0, max: 10, clamped: 4},
  {name: "above", value: 15, min: 0, max: 10, clamped: 10},
  {name: "bounds that meet", value: 15, min: 3, max: 3, clamped: 3}
]

describe.each(IMPLEMENTATIONS)("interpolation ($name)", ({AssertionError, interpolation}) => {
  test.each(lerpCases)("lerp: $name", ({from, to, fraction, value}) => {
    expect(interpolation.lerp({from, to, fraction})).toBe(value)
  })

  test.each(clampCases)("clamp: $name", ({value, min, max, clamped}) => {
    expect(interpolation.clamp({value, min, max})).toBe(clamped)
  })

  test("bounds out of order", () => {
    expect(() => interpolation.clamp({value: 1, min: 10, max: 0})).toThrow(AssertionError)
  })

  test("a value that is no number", () => {
    expect(() => interpolation.clamp({value: Number.NaN, min: 0, max: 1})).toThrow(AssertionError)
  })

  test("a fraction that is no number", () => {
    expect(() => interpolation.lerp({from: 0, to: 1, fraction: Number.NaN})).toThrow(AssertionError)
  })
})
