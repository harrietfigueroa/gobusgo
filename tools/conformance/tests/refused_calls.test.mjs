// Checks that a call refused 1,100 times leaves an implementation of the core
// working: each case makes one of the binding's reads of a caller's value
// throw in JavaScript, repeats it past the 1,024 slots of wasm-bindgen's table
// of JavaScript values, and then decodes the stops fixture. A call refused
// with a throw or with a refusal value both count, since the JavaScript core
// refuses some of these with a value.

import {beforeAll, describe, expect, test} from "vitest"
import {fixtureBytes} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"
import {FAILURE_BUDGET_MS} from "../repeated_failures.mjs"

const REFUSED_CALL_COUNT = 1100
const refusedCallTimeoutMs = REFUSED_CALL_COUNT * FAILURE_BUDGET_MS

// Walking rules the walk takes, so a call fails on its stops alone.
const WALK_RULES = Object.freeze({walkRadiusM: 400, walkSpeedMPerS: 1.2, walkLinkCountPerStopMax: 64})

// A query from the one stop of `oneStopEngineArguments` to itself, so a call
// fails on its engine alone.
const ONE_STOP_QUERY = Object.freeze({origin: {kind: "stop", stop: 0}, target: 0, departureS: 0})

let stopsBuffer = null

beforeAll(async () => {
  stopsBuffer = await fixtureBytes("routing/v2/stops.bin")
})

// An ArrayBuffer whose bytes were transferred away, which no view can read.
function detachedBuffer() {
  const buffer = new ArrayBuffer(1)
  buffer.transfer()
  return buffer
}

// A value every read of which throws, `Object.prototype.toString` included.
function revokedProxy() {
  const {proxy, revoke} = Proxy.revocable({}, {})
  revoke()
  return proxy
}

// An error whose conversion to text throws too.
function unwritableError() {
  return {toString: throwUnwritable}
}

function throwUnwritable() {
  throw new Error("refused calls: this error cannot be written")
}

function throwingPath() {
  return {
    get points() {
      throw unwritableError()
    }
  }
}

// The arguments of an engine over one stop, with no connections and no
// walking links.
function oneStopEngineArguments() {
  return {
    stopCount: 1,
    connections: {
      departureS: new Int32Array(0),
      arrivalS: new Int32Array(0),
      departureStop: new Uint32Array(0),
      arrivalStop: new Uint32Array(0),
      trip: new Uint32Array(0),
      sequence: new Uint16Array(0),
      boarding: new Uint8Array(0),
      alighting: new Uint8Array(0)
    },
    transfers: {fromStop: new Uint32Array(0), toStop: new Uint32Array(0), durationS: new Uint32Array(0)},
    minimumTransferS: 0
  }
}

// The arguments of an engine over one stop whose walking links leave from
// `fromStop`, every other column empty.
function engineArgumentsLeavingFrom(fromStop) {
  const engineArguments = oneStopEngineArguments()
  return {...engineArguments, transfers: {...engineArguments.transfers, fromStop}}
}

// A column whose bytes were transferred away, which no read can copy.
function detachedColumn() {
  const column = new Uint32Array(1)
  column.buffer.transfer()
  return column
}

// The engine over one stop that `routingEngine` builds.
function oneStopEngine(routingEngine) {
  const engineArguments = oneStopEngineArguments()
  return routingEngine.createEngine(engineArguments)
}

// The engine over one stop, with `key` replaced by `value`.
function oneStopEngineWith({routingEngine, key, value}) {
  const engine = oneStopEngine(routingEngine)
  return {...engine, [key]: value}
}

// An engine over one stop whose walking links leave from `fromStop`.
function engineLeavingFrom({routingEngine, fromStop}) {
  const engineArguments = engineArgumentsLeavingFrom(fromStop)
  return routingEngine.createEngine(engineArguments)
}

// A route over the engine of one stop from `origin`.
function oneStopRoute({routingEngine, origin}) {
  const engine = oneStopEngine(routingEngine)
  return routingEngine.route(engine, {...ONE_STOP_QUERY, origin})
}

// A start stop whose stop throws an error that cannot be written.
function throwingStart() {
  return {
    get stop() {
      throw unwritableError()
    }
  }
}

const refusedCalls = [
  {name: "the stops of a detached buffer", call: ({routingSnapshot}) => routingSnapshot.decodeStops(detachedBuffer())},
  {name: "the stops of a revoked proxy", call: ({routingSnapshot}) => routingSnapshot.decodeStops(revokedProxy())},
  {name: "a path whose points throw an unwritable error", call: ({tripPath}) => tripPath.decodeTripPath(throwingPath())},
  {name: "a built path with no stops to read", call: ({tripPath}) => tripPath.tripPathOf({tripId: "trip", routeId: "route", serviceDateMs: 0, points: [[0, 0]], stops: null})},
  {name: "the street starts of a revoked proxy", call: ({routingWalk}) => routingWalk.startsFromStreets({stops: revokedProxy(), transferRules: WALK_RULES})},
  {name: "an engine of a revoked proxy", call: ({routingEngine}) => routingEngine.createEngine(revokedProxy())},
  {name: "an engine whose walking links are a revoked proxy", call: ({routingEngine}) => routingEngine.createEngine({...oneStopEngineArguments(), transfers: revokedProxy()})},
  {name: "an engine whose links' stops are a revoked proxy", call: ({routingEngine}) => engineLeavingFrom({routingEngine, fromStop: revokedProxy()})},
  {name: "an engine whose links' stops are detached", call: ({routingEngine}) => engineLeavingFrom({routingEngine, fromStop: detachedColumn()})},
  {name: "a route over a revoked proxy", call: ({routingEngine}) => routingEngine.route(revokedProxy(), ONE_STOP_QUERY)},
  {
    name: "a route over an engine whose connections are a revoked proxy",
    call: ({routingEngine}) => routingEngine.route(oneStopEngineWith({routingEngine, key: "connections", value: revokedProxy()}), ONE_STOP_QUERY)
  },
  {name: "a route of a revoked proxy", call: ({routingEngine}) => routingEngine.route(oneStopEngine(routingEngine), revokedProxy())},
  {name: "a route from an origin whose kind cannot be written", call: ({routingEngine}) => oneStopRoute({routingEngine, origin: {kind: unwritableError()}})},
  {name: "a route from start stops of a revoked proxy", call: ({routingEngine}) => oneStopRoute({routingEngine, origin: {kind: "starts", starts: revokedProxy()}})},
  {
    name: "a route arriving by a time from a start whose stop throws an unwritable error",
    call: ({routingEngine}) => routingEngine.routeArrivingBy(oneStopEngine(routingEngine), {origin: {kind: "starts", starts: [throwingStart()]}, target: 0, arrivalS: 0})
  }
]

// Calls `call` and swallows what it throws, a refusal either way.
function refusedOnce({call, implementation}) {
  try {
    call(implementation)
  } catch {
    return
  }
}

describe.for(implementationsWith("routingSnapshot", "tripPath", "routingWalk", "routingEngine"))("refused calls ($name)", (implementation) => {
  const {routingSnapshot} = implementation

  test.each(refusedCalls)("$name, repeated, leaves the core working", ({call}) => {
    for (let count = 0; count < REFUSED_CALL_COUNT; count += 1) {
      refusedOnce({call, implementation})
    }

    const stops = routingSnapshot.decodeStops(stopsBuffer)
    expect(stops.kind).toBe(routingSnapshot.DecodeKind.decoded)
  }, refusedCallTimeoutMs)
})
