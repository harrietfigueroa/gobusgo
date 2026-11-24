// Decodes the shared routing snapshot fixtures and compares each file's
// records with the expected records the fixtures hold beside them, then
// checks that each file of the shared refusal table, a fixture with one rule
// of the format broken, is refused for the reason the table names.

import {beforeAll, describe, expect, test} from "vitest"
import {editedBytes} from "../bytes.mjs"
import {fixtureBytes, fixtureJson} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const DIRECTORY = "routing/v2/"
const BOOLEAN_COLUMNS = ["boarding", "alighting"]
const DECODER_NAMES = Object.freeze({
  stops: "decodeStops",
  trips: "decodeTrips",
  transfers: "decodeTransfers",
  connections: "decodeConnections",
  positions: "decodePositions"
})

// The cases name the tests, so they are read before the tests are collected.
const {cases: refusalCases} = await fixtureJson(DIRECTORY + "refusals.json")

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

describe.each(implementationsWith("routingSnapshot"))("routing snapshot ($name)", ({routingSnapshot}) => {
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

  test.each(refusalCases)("refused: $name", ({file, decoder, edits, reason}) => {
    const bytes = editedBytes(new Uint8Array(files[file]), edits)
    const refusal = {kind: DecodeKind.refused, reason: RefusalReason[reason]}
    expect(routingSnapshot[DECODER_NAMES[decoder]](bytes.buffer)).toStrictEqual(refusal)
  })
})
