// Checks the hot paths' assertions against the shared math cases: finite
// numbers and ordered pairs pass, and each refusal throws the AssertionError
// with the message the JavaScript core writes, its numbers written as
// `String` writes them.

import {describe, expect, test} from "vitest"
import {fixtureJson, fixtureNumber} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const cases = await fixtureJson("math/checks.json")

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
})
