// Decodes the shared routing snapshot fixtures and compares each file's
// records with the expected records the fixtures hold beside them, then
// checks that a file cut short, a position past the pole, and a file of
// another kind are refused.

import {beforeAll, describe, expect, test} from "vitest"
import {fixtureBytes, fixtureJson} from "../fixtures.mjs"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const DIRECTORY = "routing/v2/"
const POSITION_BYTES = 8
const LAT_MICRODEGREES_OUT_OF_RANGE = 90000001
const BOOLEAN_COLUMNS = ["boarding", "alighting"]

function cell({columns, name, index}) {
  const value = columns[name][index]

  if (BOOLEAN_COLUMNS.includes(name)) {
    return value === 1
  }

  return value
}

// A typed-array column set as one record per index, the shape of the
// expected records.
function rows(columns) {
  const names = Object.keys(columns)
  const result = []

  for (let index = 0; index < columns[names[0]].length; index++) {
    const row = {}

    for (const name of names) {
      row[name] = cell({columns, name, index})
    }

    result.push(row)
  }

  return result
}

const files = {}
let expected = null

beforeAll(async () => {
  expected = await fixtureJson(DIRECTORY + "expected.json")

  for (const kind of ["stops", "trips", "transfers", "connections", "positions"]) {
    files[kind] = await fixtureBytes(DIRECTORY + kind + ".bin")
  }
})

describe.each(IMPLEMENTATIONS)("routing snapshot ($name)", ({routingSnapshot}) => {
  const {DecodeKind, RefusalReason} = routingSnapshot

  function records(result) {
    expect(result.kind).toBe(DecodeKind.decoded)
    return result.records
  }

  test("stops decode to the expected records", () => {
    const result = routingSnapshot.decodeStops(files.stops)
    expect(records(result)).toStrictEqual(expected.stops)
  })

  test("trips decode to the expected records", () => {
    const result = routingSnapshot.decodeTrips(files.trips)
    expect(records(result)).toStrictEqual(expected.trips)
  })

  test("transfers decode to the expected records", () => {
    const result = routingSnapshot.decodeTransfers(files.transfers)
    const columns = records(result)
    expect(rows(columns)).toStrictEqual(expected.transfers)
  })

  test("connections decode to the expected records", () => {
    const result = routingSnapshot.decodeConnections(files.connections)
    const columns = records(result)
    expect(rows(columns)).toStrictEqual(expected.connections)
  })

  test("positions decode to the expected records", () => {
    const result = routingSnapshot.decodePositions(files.positions)
    const columns = records(result)
    expect(rows(columns)).toStrictEqual(expected.positions)
  })

  test("a connections file cut short", () => {
    const cutShort = files.connections.slice(0, files.connections.byteLength - 1)
    const refusal = {kind: DecodeKind.refused, reason: RefusalReason.invalidLength}
    expect(routingSnapshot.decodeConnections(cutShort)).toStrictEqual(refusal)
  })

  // The first position moved one microdegree past the north pole.
  test("a position past the pole", () => {
    const outOfRange = files.positions.slice(0)
    const outOfRangeView = new DataView(outOfRange)
    const firstPositionOffset = outOfRange.byteLength - POSITION_BYTES * expected.stops.length
    outOfRangeView.setInt32(firstPositionOffset, LAT_MICRODEGREES_OUT_OF_RANGE, true)
    const refusal = {kind: DecodeKind.refused, reason: RefusalReason.invalidPosition}
    expect(routingSnapshot.decodePositions(outOfRange)).toStrictEqual(refusal)
  })

  test("a stops file read as positions", () => {
    const refusal = {kind: DecodeKind.refused, reason: RefusalReason.invalidHeader}
    expect(routingSnapshot.decodePositions(files.stops)).toStrictEqual(refusal)
  })
})
