// Checks the interpolation module against the shared math cases: the two ends
// and the middle of a line, a fraction past the end, a clamp below, inside,
// and above its bounds, and the refusal of bounds out of order and of a value
// or fraction that is no number.

import {describe, expect, test} from "vitest"
import {fixtureJson, fixtureNumber} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const cases = await fixtureJson("math/interpolation.json")

describe.each(implementationsWith("interpolation"))("interpolation ($name)", ({AssertionError, interpolation}) => {
  test.each(cases.lerps)("lerp: $name", ({from, to, fraction, value}) => {
    expect(interpolation.lerp({from, to, fraction})).toBe(value)
  })

  test.each(cases.clamps)("clamp: $name", ({value, min, max, clamped}) => {
    expect(interpolation.clamp({value, min, max})).toBe(clamped)
  })

  test.each(cases.refusedLerps)("refused lerp: $name", ({from, to, fraction}) => {
    const line = {from: fixtureNumber(from), to: fixtureNumber(to), fraction: fixtureNumber(fraction)}
    expect(() => interpolation.lerp(line)).toThrow(AssertionError)
  })

  test.each(cases.refusedClamps)("refused clamp: $name", ({value, min, max}) => {
    const bounds = {value: fixtureNumber(value), min: fixtureNumber(min), max: fixtureNumber(max)}
    expect(() => interpolation.clamp(bounds)).toThrow(AssertionError)
  })
})
