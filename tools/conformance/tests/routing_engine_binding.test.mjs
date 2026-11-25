// Checks that the web binding's `route` and `routeArrivingBy` check the engine
// object they are handed on every call, since `createEngine` returns plain
// typed arrays its caller can change between calls. Each case builds the
// engine of the engine fixture's direct case through the binding, breaks one
// column of a copy of it, and expects a query of each kind to throw the
// binding's `AssertionError` with the core's message; the last cases break an
// engine in place, route it once, restore it, and expect each query's fixture
// frontier back.

import {describe, expect, test} from "vitest"
import {assertCondition} from "../../../assets/js/core/assert.js"
import {fixtureJson} from "../fixtures.mjs"
import {WEBASSEMBLY_CORE} from "../webassembly_core.mjs"

const DIRECT_CASE_NAME = "a direct ride stays aboard through the stops between"
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
// A trip slot no engine of the direct case's one trip numbers.
const TRIP_SLOT_PAST = 5

const {routingEngine, AssertionError} = WEBASSEMBLY_CORE

// The cases name the tests, so they are read before the tests are collected.
const expectedFile = await fixtureJson("routing/engine-v1/expected.json")

function isDirectCase(engineCase) {
  return engineCase.name === DIRECT_CASE_NAME
}

const directCase = expectedFile.cases.find(isDirectCase)
assertCondition(directCase !== undefined, "routing engine binding: no case named " + DIRECT_CASE_NAME)
const {stopCount} = directCase.engine
const connectionCount = directCase.engine.connections.departureS.length

function typedColumns({columns, types}) {
  const result = {}

  for (const [name, Column] of Object.entries(types)) {
    result[name] = Column.from(columns[name])
  }

  return result
}

// The direct case's engine, built through the binding.
function directEngine() {
  const {engine} = directCase
  const connections = typedColumns({columns: engine.connections, types: CONNECTION_COLUMNS})
  const transfers = typedColumns({columns: engine.transfers, types: TRANSFER_COLUMNS})
  return routingEngine.createEngine({stopCount, connections, transfers, minimumTransferS: engine.minimumTransferS})
}

function isQueryOfKind({query, kind}) {
  return query.kind === kind
}

function firstQueryOf(kind) {
  const found = directCase.queries.find((query) => isQueryOfKind({query, kind}))
  assertCondition(found !== undefined, "routing engine binding: the direct case has no query " + kind)
  return found.query
}

function routed({engine, kind, query}) {
  if (kind === QueryKind.leaving) {
    return routingEngine.route(engine, query)
  }

  return routingEngine.routeArrivingBy(engine, query)
}

// The failures' messages name the built engine's trip count, so it is read
// before the tests are collected.
const {tripCount} = directEngine()
assertCondition(tripCount < TRIP_SLOT_PAST, "routing engine binding: the direct case numbers slot " + TRIP_SLOT_PAST)

// Each break returns a copy of its own of `engine`, so no case sees another's.
function withNoTrips(engine) {
  return {...engine, tripCount: 0}
}

function withTripSlotPast(engine) {
  const broken = structuredClone(engine)
  broken.connections.tripSlot[0] = TRIP_SLOT_PAST
  return broken
}

function withDeparturesReversed(engine) {
  const broken = structuredClone(engine)
  broken.connections.departureS.reverse()
  return broken
}

function withTripCountPastConnections(engine) {
  return {...engine, tripCount: connectionCount + 1}
}

function withDepartureStopPastLastStop(engine) {
  const broken = structuredClone(engine)
  broken.connections.departureStop[0] = stopCount
  return broken
}

function withArrivalsShortened(engine) {
  const broken = structuredClone(engine)
  broken.connections.arrivalS = engine.connections.arrivalS.slice(1)
  return broken
}

function withLinkOffsetsDecreasing(engine) {
  const broken = structuredClone(engine)
  broken.links.offsets[0] = engine.links.offsets[stopCount] + 1
  return broken
}

// Routes `engine` and swallows the refusal it throws.
function refusedOnce({engine, kind, query}) {
  try {
    routed({engine, kind, query})
  } catch {
    return
  }
}

// Each break of an engine object, with the message the core refuses it with.
const brokenEngines = [
  {rule: "a trip count of 0", breakEngine: withNoTrips, failure: "routing engine: the trip slot 0 is not below the trip count 0"},
  {
    rule: "a trip slot past the trip count",
    breakEngine: withTripSlotPast,
    failure: "routing engine: the trip slot " + TRIP_SLOT_PAST + " is not below the trip count " + tripCount
  },
  {rule: "departures reversed", breakEngine: withDeparturesReversed, failure: "routing engine: the connections are not ordered by departure"},
  {
    rule: "a trip count past the connection count",
    breakEngine: withTripCountPastConnections,
    failure: "routing engine: the trip count " + (connectionCount + 1) + " exceeds the " + connectionCount + " connections"
  },
  {
    rule: "a departure stop past the last stop",
    breakEngine: withDepartureStopPastLastStop,
    failure: "routing engine: " + stopCount + " in the departure_stop column is not a stop of the snapshot"
  },
  {
    rule: "a shortened arrival column",
    breakEngine: withArrivalsShortened,
    failure: "routing engine: the arrival_s column holds " + (connectionCount - 1) + " values, not " + connectionCount
  },
  {rule: "decreasing link offsets", breakEngine: withLinkOffsetsDecreasing, failure: "routing engine: the link offsets decrease"}
]

function refusalEntriesOf(engines) {
  const entries = []

  for (const broken of engines) {
    for (const kind of Object.values(QueryKind)) {
      entries.push({...broken, kind})
    }
  }

  return entries
}

describe("routing engine binding", () => {
  test.for(refusalEntriesOf(brokenEngines))("$kind refuses an engine object with $rule", ({breakEngine, failure, kind}) => {
    const built = directEngine()
    const engine = breakEngine(built)
    const query = firstQueryOf(kind)
    const failing = () => routed({engine, kind, query})
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(failure))
  })

  test.for(directCase.queries)("an engine broken in place, routed, and restored answers $name", ({kind, query, expected}) => {
    const engine = directEngine()
    const {tripSlot} = engine.connections
    const slot = tripSlot[0]
    tripSlot[0] = TRIP_SLOT_PAST
    refusedOnce({engine, kind, query})
    tripSlot[0] = slot
    const frontier = routed({engine, kind, query})
    expect(frontier).toStrictEqual(expected)
  })
})
