// Expands and decodes the shared routing names fixture with the JavaScript
// reader and compares the names with the expected names the fixture holds
// beside it, then checks that a stream cut short, a file of another
// version, and counts that differ from the snapshot's are refused. Run it
// with `node test/scripts/routing_names_reader.mjs`; it exits non-zero on
// the first result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual} from "node:assert/strict"
import {DecodeKind} from "../../assets/js/core/routing_snapshot.js"
import {NamesRefusalReason, decodeNames} from "../../assets/js/core/routing_names.js"
import {expandNames} from "../../assets/js/names_stream.js"

const directory = fileURLToPath(new URL("../fixtures/routing/names-v1/", import.meta.url))
const STOP_COUNT = 3
const TRIP_COUNT = 3
const TRUNCATED_BYTE_COUNT = 10
const expected = JSON.parse(readFileSync(directory + "expected.json", "utf-8"))
const textEncoder = new TextEncoder()

function fixtureStream() {
  const bytes = readFileSync(directory + "names.json.gz")
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

function records(result) {
  deepStrictEqual(result.kind, DecodeKind.decoded)
  return result.records
}

function refusal(reason) {
  return {kind: DecodeKind.refused, reason}
}

const stream = fixtureStream()
const expanded = await expandNames(stream)
const content = records(expanded)
const names = records(decodeNames({buffer: content, stopCount: STOP_COUNT, tripCount: TRIP_COUNT}))
deepStrictEqual(names, expected)

const cutShort = await expandNames(stream.slice(0, stream.byteLength - TRUNCATED_BYTE_COUNT))
deepStrictEqual(cutShort, refusal(NamesRefusalReason.invalidStream))

const otherCount = decodeNames({buffer: content, stopCount: STOP_COUNT + 1, tripCount: TRIP_COUNT})
deepStrictEqual(otherCount, refusal(NamesRefusalReason.countMismatch))

const otherVersion = textEncoder.encode(JSON.stringify({version: 2})).buffer
deepStrictEqual(decodeNames({buffer: otherVersion, stopCount: 0, tripCount: 0}), refusal(NamesRefusalReason.unsupportedVersion))

const notJson = textEncoder.encode("{").buffer
deepStrictEqual(decodeNames({buffer: notJson, stopCount: 0, tripCount: 0}), refusal(NamesRefusalReason.invalidText))

const badRoute = textEncoder.encode(JSON.stringify({...expected, version: 1, routes: {r: {shortName: 7}}})).buffer
deepStrictEqual(decodeNames({buffer: badRoute, stopCount: STOP_COUNT, tripCount: TRIP_COUNT}), refusal(NamesRefusalReason.invalidShape))

console.log("routing names reader: the fixture decodes to expected.json")
