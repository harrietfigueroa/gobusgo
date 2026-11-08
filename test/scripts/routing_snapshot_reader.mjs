// Decodes the shared routing snapshot fixtures with the JavaScript reader and
// compares each file's records with expected.json, the records the Elixir
// encoder wrote them from. Run it with
// `node test/scripts/routing_snapshot_reader.mjs`; it exits non-zero on the
// first file whose records differ.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual} from "node:assert/strict"
import {decodeConnections, decodeStops, decodeTransfers, decodeTrips} from "../../assets/js/routing_snapshot.js"

const directory = fileURLToPath(new URL("../fixtures/routing/v1/", import.meta.url))
const expected = JSON.parse(readFileSync(directory + "expected.json", "utf-8"))

function buffer(kind) {
  const bytes = readFileSync(directory + kind + ".bin")
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

// A typed-array column set as one record per index, the shape expected.json holds.
function rows(columns, booleanColumns) {
  const names = Object.keys(columns)
  return Array.from(columns[names[0]], (_value, index) =>
    Object.fromEntries(names.map(name => {
      const value = columns[name][index]
      return [name, booleanColumns.includes(name) ? value === 1 : value]
    })))
}

deepStrictEqual(decodeStops(buffer("stops")), expected.stops)
deepStrictEqual(decodeTrips(buffer("trips")), expected.trips)
deepStrictEqual(rows(decodeTransfers(buffer("transfers")), []), expected.transfers)
deepStrictEqual(rows(decodeConnections(buffer("connections")), ["boarding", "alighting"]), expected.connections)
console.log("routing snapshot reader: every fixture decodes to expected.json")
