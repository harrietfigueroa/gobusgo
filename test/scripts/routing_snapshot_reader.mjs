// Decodes the shared routing snapshot fixtures with the JavaScript reader and
// compares each file's records with the expected records the fixtures hold
// beside them, then checks that a file cut short is refused. Run it with
// `node test/scripts/routing_snapshot_reader.mjs`; it exits non-zero on the
// first file whose result differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual} from "node:assert/strict"
import {
  DecodeKind,
  RefusalReason,
  decodeConnections,
  decodeStops,
  decodeTransfers,
  decodeTrips,
} from "../../assets/js/routing_snapshot.js"

const directory = fileURLToPath(new URL("../fixtures/routing/v1/", import.meta.url))
const expected = JSON.parse(readFileSync(directory + "expected.json", "utf-8"))
const BOOLEAN_COLUMNS = ["boarding", "alighting"]

function buffer(kind) {
  const bytes = readFileSync(directory + kind + ".bin")
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

function records(result) {
  deepStrictEqual(result.kind, DecodeKind.decoded)
  return result.records
}

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

const stopsFile = buffer("stops")
const tripsFile = buffer("trips")
const transfersFile = buffer("transfers")
const connections = buffer("connections")
const stops = records(decodeStops(stopsFile))
const trips = records(decodeTrips(tripsFile))
const transferColumns = records(decodeTransfers(transfersFile))
const connectionColumns = records(decodeConnections(connections))
deepStrictEqual(stops, expected.stops)
deepStrictEqual(trips, expected.trips)
deepStrictEqual(rows(transferColumns), expected.transfers)
deepStrictEqual(rows(connectionColumns), expected.connections)

const cutShort = connections.slice(0, connections.byteLength - 1)
deepStrictEqual(decodeConnections(cutShort), {kind: DecodeKind.refused, reason: RefusalReason.invalidLength})

console.log("routing snapshot reader: every fixture decodes to expected.json")
