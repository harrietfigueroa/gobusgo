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

const refusedCalls = [
  {name: "the stops of a detached buffer", call: ({routingSnapshot}) => routingSnapshot.decodeStops(detachedBuffer())},
  {name: "the stops of a revoked proxy", call: ({routingSnapshot}) => routingSnapshot.decodeStops(revokedProxy())},
  {name: "a path whose points throw an unwritable error", call: ({tripPath}) => tripPath.decodeTripPath(throwingPath())},
  {name: "a built path with no stops to read", call: ({tripPath}) => tripPath.tripPathOf({tripId: "trip", routeId: "route", serviceDateMs: 0, points: [[0, 0]], stops: null})},
  {name: "the street starts of a revoked proxy", call: ({routingWalk}) => routingWalk.startsFromStreets({stops: revokedProxy(), transferRules: WALK_RULES})}
]

// Calls `call` and swallows what it throws, a refusal either way.
function refusedOnce({call, implementation}) {
  try {
    call(implementation)
  } catch {
    return
  }
}

describe.for(implementationsWith("routingSnapshot", "tripPath", "routingWalk"))("refused calls ($name)", (implementation) => {
  const {routingSnapshot} = implementation

  test.each(refusedCalls)("$name, repeated, leaves the core working", ({call}) => {
    for (let count = 0; count < REFUSED_CALL_COUNT; count += 1) {
      refusedOnce({call, implementation})
    }

    const stops = routingSnapshot.decodeStops(stopsBuffer)
    expect(stops.kind).toBe(routingSnapshot.DecodeKind.decoded)
  }, refusedCallTimeoutMs)
})
