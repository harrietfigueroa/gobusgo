// Checks the assertions against the shared math cases: a condition that holds
// passes, one that fails throws the AssertionError with the message it was
// given, and an unreachable arm names the value it found.

import {describe, expect, test} from "vitest"
import {fixtureJson} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const cases = await fixtureJson("math/assert.json")

describe.each(implementationsWith("assert"))("assert ($name)", ({AssertionError, assert}) => {
  test.each(cases.heldConditions)("held: $name", ({message}) => {
    expect(() => assert.assertCondition(true, message)).not.toThrow()
  })

  test.each(cases.failedConditions)("failed: $name", ({message}) => {
    const failing = () => assert.assertCondition(false, message)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(message))
  })

  test.each(cases.unreachables)("unreachable: $name", ({value, message, failure}) => {
    const failing = () => assert.unreachable(value, message)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })
})
