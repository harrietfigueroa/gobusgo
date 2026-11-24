// Runs each case of the walk's shared fixture with each implementation of the
// walk and compares the answer with the one written by hand: the basis a
// manifest entry's rules give and whether it plans a walk on the streets, the
// street length bound, the start stops and the street search's candidates near
// a position, and the start stops a reach's street meters give. The suite also
// checks the module's constants, that a start leaves the reach's stops in their
// order, and that every input the module refuses throws the implementation's
// `AssertionError` with its message.

import {describe, expect, test} from "vitest"
import {assertCondition} from "../../../assets/js/core/assert.js"
import {fixtureJson, fixtureNumber} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const DIRECTORY = "routing/walk-v1/"
const WALK_CANDIDATE_COUNT_MAX = 256
const NEAR_CASE_NAME = "stops within the radius and past it, and one with no known position"
const BOUND_CASE_NAME = "260 stops within the radius, under a link bound of three"
const STREETS_CASE_NAME = "four stops reached out of order, two at one street length"
const UNBOUNDED_CASE_NAME = "a streets table with no street bound"
const NEAR_FUNCTION_NAMES = Object.freeze(["startsNear", "walkCandidatesNear"])

// The cases name the tests, so they are read before the tests are collected.
const {bases, streetWalks, streetBounds, near, streets} = await fixtureJson(DIRECTORY + "expected.json")

function isNamed(name) {
  return function isNamedCase(fixtureCase) {
    return fixtureCase.name === name
  }
}

function caseNamed({cases, name}) {
  const found = cases.find(isNamed(name))
  assertCondition(found !== undefined, "routing walk conformance: no case named " + name)
  return found
}

// The rules a manifest entry holds, its street bound read as the number the
// fixture writes.
function rulesOf(fixtureRules) {
  const isBounded = Object.hasOwn(fixtureRules, "walkStreetMetersMax")

  if (isBounded) {
    const walkStreetMetersMax = fixtureNumber(fixtureRules.walkStreetMetersMax)
    return {...fixtureRules, walkStreetMetersMax}
  }

  return {...fixtureRules}
}

// A decoded positions file, each column a typed array.
function positionsOf({latMicrodegrees, lonMicrodegrees}) {
  return {latMicrodegrees: Int32Array.from(latMicrodegrees), lonMicrodegrees: Int32Array.from(lonMicrodegrees)}
}

function nearInputOf(nearCase) {
  const positions = positionsOf(nearCase.positions)
  const transferRules = rulesOf(nearCase.transferRules)
  return {position: nearCase.position, positions, transferRules}
}

const nearCase = caseNamed({cases: near, name: NEAR_CASE_NAME})
const boundCase = caseNamed({cases: near, name: BOUND_CASE_NAME})
const streetsCase = caseNamed({cases: streets, name: STREETS_CASE_NAME})
const unboundedCase = caseNamed({cases: bases, name: UNBOUNDED_CASE_NAME})
const nearInput = nearInputOf(nearCase)
const {position, transferRules} = nearInput
const streetRules = rulesOf(streetsCase.transferRules)

// Each set of rules the module refuses, by the rule it breaks, with the failure's message.
const refusedRules = [
  {rule: "a walking radius that is not positive", transferRules: {...transferRules, walkRadiusM: 0}, failure: "routing walk: the walking radius is not positive: 0"},
  {rule: "a walking speed that is not positive", transferRules: {...transferRules, walkSpeedMPerS: 0}, failure: "routing walk: the walking speed is not positive: 0"},
  {rule: "a link bound that is no whole number", transferRules: {...transferRules, walkLinkCountPerStopMax: 2.5}, failure: "routing walk: the link count is not whole: 2.5"}
]

function nearRefusalOfRules(refused) {
  return {rule: refused.rule, input: {...nearInput, transferRules: refused.transferRules}, failure: refused.failure}
}

const refusedRulesNear = Array.from(refusedRules, nearRefusalOfRules)
const lonColumnShorter = nearInput.positions.lonMicrodegrees.subarray(1)

// Each query near a position the module refuses, by the rule it breaks, with the failure's message.
const refusedNear = [
  {rule: "a latitude that is no number", input: {...nearInput, position: {...position, lat: Number.NaN}}, failure: "routing walk: the position's latitude is not a number: NaN"},
  {rule: "a longitude that is no number", input: {...nearInput, position: {...position, lon: Number.NaN}}, failure: "routing walk: the position's longitude is not a number: NaN"},
  {rule: "a latitude past the pole", input: {...nearInput, position: {...position, lat: 90.5}}, failure: "routing walk: the position's latitude is out of range: 90.5"},
  {rule: "a longitude past the antimeridian", input: {...nearInput, position: {...position, lon: -180.5}}, failure: "routing walk: the position's longitude is out of range: -180.5"},
  ...refusedRulesNear,
  {
    rule: "position columns of different lengths",
    input: {...nearInput, positions: {latMicrodegrees: nearInput.positions.latMicrodegrees, lonMicrodegrees: lonColumnShorter}},
    failure: "routing walk: the position columns differ in length"
  }
]

function refusedNearEntries() {
  const entries = []

  for (const functionName of NEAR_FUNCTION_NAMES) {
    for (const refused of refusedNear) {
      entries.push({functionName, ...refused})
    }
  }

  return entries
}

const refusedNearCalls = refusedNearEntries()

const unboundedRules = rulesOf(unboundedCase.transferRules)

// Street bounds that are no number, which a manifest's JSON could carry, each
// read as a straight-line table.
const nonNumberBounds = [
  {name: "null", bound: null},
  {name: "text", bound: "600"}
]

// Each street bound the module refuses, by the rule it breaks, with the failure's message.
const refusedBounds = [
  {rule: "no bound", transferRules: unboundedRules, failure: "routing walk: the street length bound is not a number: undefined"},
  {rule: "a bound that is no number", transferRules: {...streetRules, walkStreetMetersMax: Number.NaN}, failure: "routing walk: the street length bound is not a number: NaN"},
  {rule: "an infinite bound", transferRules: {...streetRules, walkStreetMetersMax: Number.POSITIVE_INFINITY}, failure: "routing walk: the street length bound is not a number: Infinity"},
  {rule: "a zero bound", transferRules: {...streetRules, walkStreetMetersMax: 0}, failure: "routing walk: the street length bound is not positive: 0"},
  {rule: "a negative bound", transferRules: {...streetRules, walkStreetMetersMax: -600}, failure: "routing walk: the street length bound is not positive: -600"}
]

describe("routing walk fixture", () => {
  test("the 260-stop case holds more stops than the street search keeps", () => {
    const stopCount = boundCase.positions.latMicrodegrees.length
    expect(stopCount).toBeGreaterThan(WALK_CANDIDATE_COUNT_MAX)
  })

  test("the 260-stop case expects as many candidates as the street search keeps", () => {
    const candidateCount = boundCase.candidates.length
    expect(candidateCount).toBe(WALK_CANDIDATE_COUNT_MAX)
  })
})

describe.for(implementationsWith("routingWalk"))("routing walk ($name)", ({routingWalk, AssertionError}) => {
  test("WalkBasis names a straight line, the streets, and a mix", () => {
    expect(routingWalk.WalkBasis).toStrictEqual({straight: "straight", streets: "streets", mixed: "mixed"})
  })

  test("a walk over the streets searches at most 256 candidates", () => {
    expect(routingWalk.WALK_CANDIDATE_COUNT_MAX).toBe(WALK_CANDIDATE_COUNT_MAX)
  })

  test.for(bases)("walkBasisOf reads $name as $basis", (basisCase) => {
    const rules = rulesOf(basisCase.transferRules)
    const basis = routingWalk.walkBasisOf(rules)
    expect(basis).toBe(basisCase.basis)
  })

  test.for(nonNumberBounds)("walkBasisOf reads a street bound of $name as a straight-line table", ({bound}) => {
    const basis = routingWalk.walkBasisOf({...streetRules, walkStreetMetersMax: bound})
    expect(basis).toBe(routingWalk.WalkBasis.straight)
  })

  test.for(streetWalks)("isStreetWalk of $basis is $isStreetWalk", ({basis, isStreetWalk}) => {
    const isStreet = routingWalk.isStreetWalk(basis)
    expect(isStreet).toBe(isStreetWalk)
  })

  test("isStreetWalk refuses a basis of unknown kind", () => {
    const failing = () => routingWalk.isStreetWalk("teleport")
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError("routing walk: a walking basis of unknown kind: teleport"))
  })

  test("isStreetWalk refuses a basis that is a String object rather than text", () => {
    // A String object is the input under test: it writes as a basis's name and is no member of WalkBasis.
    const failing = () => routingWalk.isStreetWalk(new String("streets"))
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError("routing walk: a walking basis of unknown kind: streets"))
  })

  test.for(streetBounds)("streetMetersMaxOf reads $name as $meters", (streetBoundCase) => {
    const rules = rulesOf(streetBoundCase.transferRules)
    const meters = routingWalk.streetMetersMaxOf(rules)
    expect(meters).toBe(streetBoundCase.meters)
  })

  test.for(refusedBounds)("streetMetersMaxOf refuses $rule", ({transferRules: rules, failure}) => {
    const failing = () => routingWalk.streetMetersMaxOf(rules)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })

  test.for(near)("startsNear over $name", (fixtureCase) => {
    const starts = routingWalk.startsNear(nearInputOf(fixtureCase))
    expect(starts).toStrictEqual(fixtureCase.starts)
  })

  test.for(near)("walkCandidatesNear over $name", (fixtureCase) => {
    const candidates = routingWalk.walkCandidatesNear(nearInputOf(fixtureCase))
    expect(candidates).toStrictEqual(fixtureCase.candidates)
  })

  test.for(refusedNearCalls)("$functionName refuses $rule", ({functionName, input, failure}) => {
    const failing = () => routingWalk[functionName](input)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })

  test.for(streets)("startsFromStreets over $name", (fixtureCase) => {
    const rules = rulesOf(fixtureCase.transferRules)
    // A copy, so the fixture keeps the order it was written in.
    const stops = structuredClone(fixtureCase.stops)
    const starts = routingWalk.startsFromStreets({stops, transferRules: rules})
    expect(starts).toStrictEqual(fixtureCase.starts)
  })

  test("startsFromStreets leaves the reach's stops in their order", () => {
    const stops = structuredClone(streetsCase.stops)
    routingWalk.startsFromStreets({stops, transferRules: streetRules})
    expect(stops).toStrictEqual(streetsCase.stops)
  })

  test.for(refusedRules)("startsFromStreets refuses $rule", ({transferRules: rules, failure}) => {
    const stops = structuredClone(streetsCase.stops)
    const failing = () => routingWalk.startsFromStreets({stops, transferRules: rules})
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })
})
