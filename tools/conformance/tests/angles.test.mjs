// Checks the angles module against the shared math cases: conversions of the
// quarter and half turns, the exact bits of a conversion that multiplies
// before it divides, the range normalized angles fall in, the smaller turn
// between two directions across north, and the refusal of an angle that is
// no number.

import {describe, expect, test} from "vitest"
import {fixtureJson, fixtureNumber} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const cases = await fixtureJson("math/angles.json")
const TOLERANCE = cases.conversionTolerance

describe.each(implementationsWith("angles"))("angles ($name)", ({AssertionError, angles}) => {
  test.each(Object.entries(cases.constants))("the constant %s", (constantName, value) => {
    expect(angles[constantName]).toBe(value)
  })

  test.each(cases.conversions)("$name in radians", ({degrees, radians}) => {
    expect(Math.abs(angles.radians(degrees) - radians)).toBeLessThanOrEqual(TOLERANCE)
  })

  test.each(cases.conversions)("$name in degrees", ({degrees, radians}) => {
    expect(Math.abs(angles.degrees(radians) - degrees)).toBeLessThanOrEqual(TOLERANCE)
  })

  test.each(cases.exactRadians)("exactly: $name", ({degrees, radians}) => {
    expect(angles.radians(degrees)).toBe(radians)
  })

  test.each(cases.normalized)("normalized: $name", ({degrees, normalized}) => {
    expect(angles.normalizedDegrees(degrees)).toBe(normalized)
  })

  test.each(cases.turns)("turn: $name", ({from, to, turn}) => {
    expect(angles.turnDegrees({from, to})).toBe(turn)
  })

  test.each(cases.refusedRadians)("refused: $name", ({degrees}) => {
    expect(() => angles.radians(fixtureNumber(degrees))).toThrow(AssertionError)
  })

  test.each(cases.refusedNormalized)("refused: $name", ({degrees}) => {
    expect(() => angles.normalizedDegrees(fixtureNumber(degrees))).toThrow(AssertionError)
  })
})
