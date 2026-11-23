// Routes each query of the engine's shared fixture with each implementation
// of the engine and compares the frontier with the one written by hand. The
// inputs and queries come from the fixture's generated file in the terms
// `createEngine`, `route`, and `routeArrivingBy` take, so no snapshot file is
// decoded. The suite also rebuilds the generated file from the two
// hand-written ones to check that it is current, checks the order the engine
// assumes of its inputs, the engine's constants, and that every query the
// engine refuses throws the implementation's `AssertionError`.

import {describe, expect, test} from "vitest"
import {assertCondition, unreachable} from "../../../assets/js/core/assert.js"
import {engineCases} from "../../../test/scripts/routing_engine_cases.mjs"
import {fixtureJson} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const DIRECTORY = "routing/engine-v1/"
const ROUNDS_MAX = 6
const QueryKind = Object.freeze({leaving: "leaving", arrivingBy: "arrivingBy"})
const CONNECTION_COLUMNS = Object.freeze({
  departureS: Int32Array,
  arrivalS: Int32Array,
  departureStop: Uint32Array,
  arrivalStop: Uint32Array,
  trip: Uint32Array,
  sequence: Uint16Array,
  boarding: Uint8Array,
  alighting: Uint8Array
})
const TRANSFER_COLUMNS = Object.freeze({fromStop: Uint32Array, toStop: Uint32Array, durationS: Uint32Array})
const FLAG_VALUES = Object.freeze([0, 1])
const SHORTER_WALK_S = 60
const LONGER_WALK_S = 120
const DIRECT_CASE_NAME = "a direct ride stays aboard through the stops between"

// The cases name the tests, so they are read before the tests are collected.
const expectedFile = await fixtureJson(DIRECTORY + "expected.json")
const journeysFile = await fixtureJson(DIRECTORY + "journeys.json")
const startsFile = await fixtureJson(DIRECTORY + "starts.json")
const {cases} = expectedFile

function queryEntriesOf(engineCases) {
  const entries = []

  for (const engineCase of engineCases) {
    for (const query of engineCase.queries) {
      entries.push({label: engineCase.name + ": " + query.name, engineCase, query})
    }
  }

  return entries
}

const queryEntries = queryEntriesOf(cases)

function isDirectCase(engineCase) {
  return engineCase.name === DIRECT_CASE_NAME
}

const directCase = cases.find(isDirectCase)
assertCondition(directCase !== undefined, "routing engine conformance: no case named " + DIRECT_CASE_NAME)
const {stopCount} = directCase.engine
const STOP_A = directCase.stopIds.indexOf("A")
const STOP_C = directCase.stopIds.indexOf("C")
assertCondition(STOP_A >= 0, "routing engine conformance: the direct case has no stop A")
assertCondition(STOP_C >= 0, "routing engine conformance: the direct case has no stop C")

function typedColumns({columns, types}) {
  expect(Object.keys(columns)).toStrictEqual(Object.keys(types))
  const result = {}

  for (const [name, Column] of Object.entries(types)) {
    result[name] = Column.from(columns[name])
  }

  return result
}

// The engine's arguments, each column a typed array.
function engineArguments(engineCase) {
  const {engine} = engineCase
  const connections = typedColumns({columns: engine.connections, types: CONNECTION_COLUMNS})
  const transfers = typedColumns({columns: engine.transfers, types: TRANSFER_COLUMNS})
  return {stopCount: engine.stopCount, connections, transfers, minimumTransferS: engine.minimumTransferS}
}

function routed({routingEngine, engine, kind, query}) {
  switch (kind) {
    case QueryKind.leaving:
      return routingEngine.route(engine, query)
    case QueryKind.arrivingBy:
      return routingEngine.routeArrivingBy(engine, query)
    default:
      return unreachable(kind, "routing engine conformance: a query of unknown kind")
  }
}

function isOrdered(column) {
  for (let index = 1; index < column.length; index++) {
    if (column[index - 1] > column[index]) {
      return false
    }
  }

  return true
}

function isFlag(value) {
  return FLAG_VALUES.includes(value)
}

const origins = Object.freeze({
  stopA: {kind: "stop", stop: STOP_A},
  pastLastStop: {kind: "stop", stop: stopCount},
  noStarts: {kind: "starts", starts: []},
  startPastLastStop: {kind: "starts", starts: [{stop: stopCount, walkS: 0}]},
  fractionalWalk: {kind: "starts", starts: [{stop: STOP_A, walkS: 0.5}]},
  negativeWalk: {kind: "starts", starts: [{stop: STOP_A, walkS: -1}]},
  unknownKind: {kind: "position", latitude: 0, longitude: 0}
})

const NOT_A_STOP = " is not a stop of the snapshot"
const failures = Object.freeze({
  targetPastLastStop: "routing engine: the target " + stopCount + NOT_A_STOP,
  negativeTarget: "routing engine: the target -1" + NOT_A_STOP,
  fractionalTarget: "routing engine: the target 0.5" + NOT_A_STOP,
  fractionalDeparture: "routing engine: the departure is not whole seconds: 0.5",
  fractionalArrival: "routing engine: the arrival is not whole seconds: 0.5",
  originPastLastStop: "routing engine: the origin stop " + stopCount + NOT_A_STOP,
  noStarts: "routing engine: a query from start stops names none",
  startPastLastStop: "routing engine: the start stop " + stopCount + NOT_A_STOP,
  fractionalWalk: "routing engine: a start stop's walk is not whole seconds: 0.5",
  negativeWalk: "routing engine: a start stop's walk is negative: -1",
  startNamedTwice: "routing engine: the start stop " + STOP_A + " is named twice",
  unknownKind: "routing engine: an origin of unknown kind: position"
})

// Each query the engine refuses, by the rule it breaks, with the failure's message.
const refusedQueries = [
  {rule: "a target past the last stop", kind: QueryKind.leaving, query: {origin: origins.stopA, target: stopCount, departureS: 0}, failure: failures.targetPastLastStop},
  {rule: "a negative target", kind: QueryKind.leaving, query: {origin: origins.stopA, target: -1, departureS: 0}, failure: failures.negativeTarget},
  {rule: "a target that is no whole number", kind: QueryKind.leaving, query: {origin: origins.stopA, target: 0.5, departureS: 0}, failure: failures.fractionalTarget},
  {rule: "a departure that is no whole number", kind: QueryKind.leaving, query: {origin: origins.stopA, target: STOP_C, departureS: 0.5}, failure: failures.fractionalDeparture},
  {rule: "an origin stop past the last stop", kind: QueryKind.leaving, query: {origin: origins.pastLastStop, target: STOP_C, departureS: 0}, failure: failures.originPastLastStop},
  {rule: "no start stop", kind: QueryKind.leaving, query: {origin: origins.noStarts, target: STOP_C, departureS: 0}, failure: failures.noStarts},
  {rule: "a start stop past the last stop", kind: QueryKind.leaving, query: {origin: origins.startPastLastStop, target: STOP_C, departureS: 0}, failure: failures.startPastLastStop},
  {rule: "a start's walk that is no whole number", kind: QueryKind.leaving, query: {origin: origins.fractionalWalk, target: STOP_C, departureS: 0}, failure: failures.fractionalWalk},
  {rule: "a negative start walk", kind: QueryKind.leaving, query: {origin: origins.negativeWalk, target: STOP_C, departureS: 0}, failure: failures.negativeWalk},
  {rule: "an origin of unknown kind", kind: QueryKind.leaving, query: {origin: origins.unknownKind, target: STOP_C, departureS: 0}, failure: failures.unknownKind},
  {rule: "a target past the last stop", kind: QueryKind.arrivingBy, query: {origin: origins.stopA, target: stopCount, arrivalS: 0}, failure: failures.targetPastLastStop},
  {rule: "a negative target", kind: QueryKind.arrivingBy, query: {origin: origins.stopA, target: -1, arrivalS: 0}, failure: failures.negativeTarget},
  {rule: "a target that is no whole number", kind: QueryKind.arrivingBy, query: {origin: origins.stopA, target: 0.5, arrivalS: 0}, failure: failures.fractionalTarget},
  {rule: "an arrival that is no whole number", kind: QueryKind.arrivingBy, query: {origin: origins.stopA, target: STOP_C, arrivalS: 0.5}, failure: failures.fractionalArrival},
  {rule: "an origin stop past the last stop", kind: QueryKind.arrivingBy, query: {origin: origins.pastLastStop, target: STOP_C, arrivalS: 0}, failure: failures.originPastLastStop},
  {rule: "no start stop", kind: QueryKind.arrivingBy, query: {origin: origins.noStarts, target: STOP_C, arrivalS: 0}, failure: failures.noStarts},
  {rule: "a start stop past the last stop", kind: QueryKind.arrivingBy, query: {origin: origins.startPastLastStop, target: STOP_C, arrivalS: 0}, failure: failures.startPastLastStop},
  {rule: "a start's walk that is no whole number", kind: QueryKind.arrivingBy, query: {origin: origins.fractionalWalk, target: STOP_C, arrivalS: 0}, failure: failures.fractionalWalk},
  {rule: "a negative start walk", kind: QueryKind.arrivingBy, query: {origin: origins.negativeWalk, target: STOP_C, arrivalS: 0}, failure: failures.negativeWalk},
  {
    rule: "a start stop named twice",
    kind: QueryKind.arrivingBy,
    query: {
      origin: {kind: "starts", starts: [{stop: STOP_A, walkS: LONGER_WALK_S}, {stop: STOP_A, walkS: SHORTER_WALK_S}]},
      target: STOP_C,
      arrivalS: 0
    },
    failure: failures.startNamedTwice
  },
  {rule: "an origin of unknown kind", kind: QueryKind.arrivingBy, query: {origin: origins.unknownKind, target: STOP_C, arrivalS: 0}, failure: failures.unknownKind}
]

// The one connection of the direct case whose `column` holds `stop`.
function onlyConnection({column, stop}) {
  const indices = []

  for (const [index, value] of column.entries()) {
    if (value === stop) {
      indices.push(index)
    }
  }

  assertCondition(indices.length === 1, "routing engine conformance: " + indices.length + " connections hold the stop " + stop)
  return indices[0]
}

const BOARD_AT_A = onlyConnection({column: directCase.engine.connections.departureStop, stop: STOP_A})
const ALIGHT_AT_C = onlyConnection({column: directCase.engine.connections.arrivalStop, stop: STOP_C})

// A start stop named twice, in both orders, so only keeping the shorter walk
// passes whichever comes first.
const twiceNamedStarts = [
  {order: "the longer walk first", starts: [{stop: STOP_A, walkS: LONGER_WALK_S}, {stop: STOP_A, walkS: SHORTER_WALK_S}]},
  {order: "the shorter walk first", starts: [{stop: STOP_A, walkS: SHORTER_WALK_S}, {stop: STOP_A, walkS: LONGER_WALK_S}]}
]

describe("routing engine fixture", () => {
  test("expected.json is the file the hand-written journeys.json and starts.json give", () => {
    const rebuilt = engineCases({journeys: journeysFile, starts: startsFile})
    expect(rebuilt).toStrictEqual(expectedFile)
  })

  test.for(cases)("$name: connections are ordered by departure", ({engine}) => {
    const isDepartureOrder = isOrdered(engine.connections.departureS)
    expect(isDepartureOrder).toBe(true)
  })

  test.for(cases)("$name: walking links are ordered by the stop they leave", ({engine}) => {
    const isFromStopOrder = isOrdered(engine.transfers.fromStop)
    expect(isFromStopOrder).toBe(true)
  })

  test.for(cases)("$name: boarding and alighting flags are 1 or 0", ({engine}) => {
    const isBoardingFlags = engine.connections.boarding.every(isFlag)
    const isAlightingFlags = engine.connections.alighting.every(isFlag)
    expect(isBoardingFlags).toBe(true)
    expect(isAlightingFlags).toBe(true)
  })
})

describe.for(implementationsWith("routingEngine"))("routing engine ($name)", ({routingEngine, AssertionError}) => {
  test("LegKind names a ride, a walk, and a walk from the position", () => {
    expect(routingEngine.LegKind).toStrictEqual({ride: "ride", walk: "walk", walkFromPosition: "walkFromPosition"})
  })

  test("OriginKind names a stop and start stops", () => {
    expect(routingEngine.OriginKind).toStrictEqual({stop: "stop", starts: "starts"})
  })

  test("a journey takes at most six rides", () => {
    expect(routingEngine.ROUNDS_MAX).toBe(ROUNDS_MAX)
  })

  test.for(queryEntries)("$label", ({engineCase, query}) => {
    const engine = routingEngine.createEngine(engineArguments(engineCase))
    const frontier = routed({routingEngine, engine, kind: query.kind, query: query.query})
    expect(frontier).toStrictEqual(query.expected)
  })

  test.for(refusedQueries)("$kind refuses $rule", ({kind, query, failure}) => {
    const engine = routingEngine.createEngine(engineArguments(directCase))
    const failing = () => routed({routingEngine, engine, kind, query})
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })

  // Where routeArrivingBy refuses a start stop named twice, route takes it
  // and keeps the shorter of its walks; the cases pin that difference.
  test.for(twiceNamedStarts)("leaving takes a start stop named twice, $order, and keeps its shorter walk", ({starts}) => {
    const engine = routingEngine.createEngine(engineArguments(directCase))
    const boardS = directCase.engine.connections.departureS[BOARD_AT_A]
    const query = {origin: {kind: "starts", starts}, target: STOP_C, departureS: boardS - LONGER_WALK_S}
    const frontier = routingEngine.route(engine, query)
    const walk = {kind: "walkFromPosition", toStop: STOP_A, durationS: SHORTER_WALK_S}
    const ride = {kind: "ride", boardConnection: BOARD_AT_A, alightConnection: ALIGHT_AT_C}
    const arrivalS = directCase.engine.connections.arrivalS[ALIGHT_AT_C]
    expect(frontier).toStrictEqual([{arrivalS, changes: 0, legs: [walk, ride]}])
  })
})
