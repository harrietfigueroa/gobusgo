// Checks the hot paths' assertions against the shared math cases: finite
// numbers and ordered pairs pass, and each refusal throws the AssertionError
// with the message the JavaScript core writes, its numbers written as
// `String` writes them.

import {describe, expect, test} from "vitest"
import {fixtureJson, fixtureNumber} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"
import {FAILURE_BUDGET_MS} from "../repeated_failures.mjs"

const cases = await fixtureJson("math/checks.json")

// A failure's count large enough to use up a binding that leaks a little on
// each, such as a slot of wasm-bindgen's table of JavaScript values.
const REPEATED_FAILURE_COUNT = 1000
const REPEATED_FAILURE_TIMEOUT_MS = REPEATED_FAILURE_COUNT * FAILURE_BUDGET_MS

// Values a caller hands as numbers that are none, which JavaScript's types
// alone can write, so their cases live here rather than in the shared fixture.
const refusedValues = [
  {name: "a numeral", value: "5"},
  {name: "null", value: null},
  {name: "undefined", value: undefined}
]

describe.each(implementationsWith("checks"))("checks ($name)", ({AssertionError, checks}) => {
  test.each(cases.finite)("finite: $name", ({value}) => {
    expect(() => checks.assertFinite(value, "a finite number")).not.toThrow()
  })

  test.each(cases.refusedFinite)("refused finite: $name", ({value, label, failure}) => {
    const failing = () => checks.assertFinite(fixtureNumber(value), label)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })

  test.each(cases.ordered)("ordered: $name", ({low, high}) => {
    expect(() => checks.assertOrdered({low, high, label: "an ordered pair"})).not.toThrow()
  })

  test.each(cases.refusedOrdered)("refused ordered: $name", ({low, high, label, failure}) => {
    const pair = {low: fixtureNumber(low), high: fixtureNumber(high), label}
    const failing = () => checks.assertOrdered(pair)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })

  test.each(refusedValues)("refused finite, no number: $name", ({value}) => {
    const failing = () => checks.assertFinite(value, "a value")
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(`a value: ${value} is not a finite number`))
  })

  // A pair with no label names it as `String` writes `undefined`.
  test("refused ordered: no label", () => {
    const failing = () => checks.assertOrdered({low: 1, high: 0})
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError("undefined: 1 is above 0"))
  })

  // Each failure leaves the implementation as it found it, so a pass follows
  // a long run of them.
  test("a pass after many refusals", () => {
    for (let index = 0; index < REPEATED_FAILURE_COUNT; index++) {
      expect(() => checks.assertOrdered({low: 1, high: 0})).toThrow(AssertionError)
    }
    expect(() => checks.assertOrdered({low: 0, high: 1, label: "a pair"})).not.toThrow()
  }, REPEATED_FAILURE_TIMEOUT_MS)
})
