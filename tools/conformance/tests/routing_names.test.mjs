// Expands the shared routing names fixture with the web's gzip stream,
// decodes it, and compares the names with the expected names the fixture
// holds beside it, then checks that a stream cut short, a file of another
// version, counts that differ from the snapshot's, text that is no JSON, and
// a route of the wrong shape are refused. The expansion is the web shell's,
// so it runs once; the decoding runs once per implementation.

import {beforeAll, describe, expect, test} from "vitest"
import {expandNames} from "../../../assets/js/names_stream.js"
import {fixtureBytes, fixtureJson} from "../fixtures.mjs"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const DIRECTORY = "routing/names-v1/"
const STOP_COUNT = 3
const TRIP_COUNT = 3
const TRUNCATED_BYTE_COUNT = 10
const TEXT_ENCODER = new TextEncoder()

let expected = null
let stream = null
let expanded = null

beforeAll(async () => {
  expected = await fixtureJson(DIRECTORY + "expected.json")
  stream = await fixtureBytes(DIRECTORY + "names.json.gz")
  expanded = await expandNames(stream)
})

describe.each(IMPLEMENTATIONS)("routing names ($name)", ({routingNames, routingSnapshot}) => {
  const {DecodeKind} = routingSnapshot
  const {NamesRefusalReason} = routingNames

  function records(result) {
    expect(result.kind).toBe(DecodeKind.decoded)
    return result.records
  }

  function refusal(reason) {
    return {kind: DecodeKind.refused, reason}
  }

  test("the fixture decodes to the expected names", () => {
    const content = records(expanded)
    const names = records(routingNames.decodeNames({buffer: content, stopCount: STOP_COUNT, tripCount: TRIP_COUNT}))
    expect(names).toStrictEqual(expected)
  })

  test("a stream cut short", async () => {
    const cutShort = await expandNames(stream.slice(0, stream.byteLength - TRUNCATED_BYTE_COUNT))
    expect(cutShort).toStrictEqual(refusal(NamesRefusalReason.invalidStream))
  })

  test("counts that differ from the snapshot's", () => {
    const content = records(expanded)
    const otherCount = routingNames.decodeNames({buffer: content, stopCount: STOP_COUNT + 1, tripCount: TRIP_COUNT})
    expect(otherCount).toStrictEqual(refusal(NamesRefusalReason.countMismatch))
  })

  test("a file of another version", () => {
    const otherVersion = TEXT_ENCODER.encode(JSON.stringify({version: 2})).buffer
    const result = routingNames.decodeNames({buffer: otherVersion, stopCount: 0, tripCount: 0})
    expect(result).toStrictEqual(refusal(NamesRefusalReason.unsupportedVersion))
  })

  test("text that is no JSON", () => {
    const notJson = TEXT_ENCODER.encode("{").buffer
    const result = routingNames.decodeNames({buffer: notJson, stopCount: 0, tripCount: 0})
    expect(result).toStrictEqual(refusal(NamesRefusalReason.invalidText))
  })

  test("a route of the wrong shape", () => {
    const badRoute = TEXT_ENCODER.encode(JSON.stringify({...expected, version: 1, routes: {r: {shortName: 7}}})).buffer
    const result = routingNames.decodeNames({buffer: badRoute, stopCount: STOP_COUNT, tripCount: TRIP_COUNT})
    expect(result).toStrictEqual(refusal(NamesRefusalReason.invalidShape))
  })
})
