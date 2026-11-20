// Checks that every implementation of the core answers the same journey
// queries alike over a real routing snapshot: 200 seeded queries between
// stops of the date running now, drawn as the routing benchmark draws them,
// each leaving at a time and arriving by it. Each implementation drives the
// query through startQuery and
// resumeQuery over the same fetched files, and its answer must equal the
// first implementation's. The files come from the site GOBUSGO_FILE_ORIGIN
// names, through the test server, and each browser fetches a file once.

import {beforeAll, describe, expect, test} from "vitest"
import {commands} from "vitest/browser"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const MANIFEST_PATH = "/api/routing/manifest"
const QUERY_COUNT = 200
const QUERY_SEED = 232
const HOUR_SECONDS = 60 * 60
const DEPARTURE_HOUR_MIN = 6
const DEPARTURE_HOUR_SPAN = 16
const LCG_MULTIPLIER = 1664525
const LCG_INCREMENT = 1013904223
const LCG_MODULUS = 4294967296
const TEXT_DECODER = new TextDecoder()

// The reference every other implementation is compared with.
const [reference] = IMPLEMENTATIONS
const {FetchKind, FromKind, StepKind, TimeKind} = reference.routingJourneys

// The benchmark's generator: the same draws in every run, as fractions of the
// date's stop count and departures between 06:00 and 22:00.
function seededQueries() {
  let state = QUERY_SEED
  const result = []

  function next() {
    state = (state * LCG_MULTIPLIER + LCG_INCREMENT) % LCG_MODULUS
    return state / LCG_MODULUS
  }

  for (let index = 0; index < QUERY_COUNT; index++) {
    const sourceFraction = next()
    const targetFraction = next()
    const hours = DEPARTURE_HOUR_MIN + next() * DEPARTURE_HOUR_SPAN
    const seconds = Math.floor(hours * HOUR_SECONDS)
    result.push({index, sourceFraction, targetFraction, seconds})
  }

  return result
}

const queries = seededQueries()
const fetchedByPath = new Map()
const shared = {}

function bufferOf(encoded) {
  const text = atob(encoded)
  const bytes = Uint8Array.from(text, charCode)
  return bytes.buffer
}

function charCode(character) {
  return character.charCodeAt(0)
}

// The bytes of `path`, fetched once for this browser.
async function fileBuffer(path) {
  if (fetchedByPath.has(path)) {
    return fetchedByPath.get(path)
  }

  const encoded = await commands.fileFromOrigin(path)
  const buffer = bufferOf(encoded)
  fetchedByPath.set(path, buffer)
  return buffer
}

async function loadSnapshot() {
  const manifestBuffer = await fileBuffer(MANIFEST_PATH)
  const manifestText = TEXT_DECODER.decode(manifestBuffer)
  shared.manifest = JSON.parse(manifestText)
  const now = reference.routingJourneys.serviceDateAt({manifest: shared.manifest, departureMs: Date.now()})
  expect(now.kind).toBe(reference.routingJourneys.ServiceDateKind.found)
  shared.serviceDate = now.serviceDate
  const entry = shared.manifest.snapshots.find(isServiceDate)
  const stopsBuffer = await fileBuffer(entry.files.stops.path)
  const stops = reference.routingSnapshot.decodeStops(stopsBuffer)
  expect(stops.kind).toBe(reference.routingSnapshot.DecodeKind.decoded)
  shared.stopIds = stops.records
}

beforeAll(loadSnapshot)

function isServiceDate(entry) {
  return entry.serviceDate === shared.serviceDate
}

function pathOf(file) {
  return file.path
}

// The answer of one implementation, its query driven over the fetched files.
async function answerOf({routingJourneys, request}) {
  const {manifest} = shared
  const held = new Map()
  let {state, step} = routingJourneys.startQuery({manifest, request})

  for (let round = 0; round < routingJourneys.ROUND_COUNT_MAX; round++) {
    if (step.kind === StepKind.done) {
      return step.answer
    }

    const paths = Array.from(step.files, pathOf)
    const fetched = []

    for (const path of paths) {
      const buffer = await fileBuffer(path)
      held.set(path, buffer)
      fetched.push({kind: FetchKind.fetched, buffer})
    }

    const resumed = routingJourneys.resumeQuery({manifest, state, fetched, files: held})
    state = resumed.state
    step = resumed.step
  }

  return expect.unreachable("parity: a query asked for files past the round bound")
}

function requestOf({query, kind}) {
  const {stopIds, serviceDate} = shared
  const fromStopId = stopIds[Math.floor(query.sourceFraction * stopIds.length)]
  const toStopId = stopIds[Math.floor(query.targetFraction * stopIds.length)]
  return {kind, serviceDate, seconds: query.seconds, from: {kind: FromKind.stop, stopId: fromStopId}, toStopId}
}

const timeKinds = [
  {name: "leaving", kind: TimeKind.leaving},
  {name: "arriving by", kind: TimeKind.arrivingBy}
]

function journeysOfKind({kind}) {
  async function queryAgrees(query) {
    const request = requestOf({query, kind})
    const expected = await answerOf({routingJourneys: reference.routingJourneys, request})

    for (const implementation of IMPLEMENTATIONS.slice(1)) {
      const answer = await answerOf({routingJourneys: implementation.routingJourneys, request})
      expect(answer, implementation.name).toStrictEqual(expected)
    }
  }

  test.each(queries)("query $index", queryAgrees)
}

describe.each(timeKinds)("journeys $name", journeysOfKind)
