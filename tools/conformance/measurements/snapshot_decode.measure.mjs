// Times the decoding of a routing snapshot date's four tables and one
// connection chunk, the files a journey query decodes first, in each
// implementation of the core, and prints each one's median over repeated
// runs. The date is the one running now on the site GOBUSGO_FILE_ORIGIN
// names, and the chunk is its largest, the busiest hour. Each run decodes
// every file from its ArrayBuffer, as a query's round does; the WebAssembly
// core's time includes copying the bytes in and the columns out.

import {beforeAll, describe, expect, test} from "vitest"
import {commands} from "vitest/browser"
import {implementationsWith} from "../implementations.mjs"

const MANIFEST_PATH = "/api/routing/manifest"
const WARM_UP_RUN_COUNT = 5
const RUN_COUNT = 31
const MILLISECOND_DIGITS = 2
// The middle of an odd count of sorted runs is at half its length, rounded down.
const MIDDLE_DIVISOR = 2
const TEXT_DECODER = new TextDecoder()
const TABLE_KINDS = Object.freeze(["stops", "trips", "transfers", "positions"])
const DECODER_NAMES = Object.freeze({
  stops: "decodeStops",
  trips: "decodeTrips",
  transfers: "decodeTransfers",
  positions: "decodePositions",
  connections: "decodeConnections"
})

const implementations = implementationsWith("routingSnapshot")
const [{routingJourneys}] = implementationsWith("routingJourneys")
const files = []

function bufferOf(encoded) {
  const text = atob(encoded)
  const bytes = Uint8Array.from(text, charCode)
  return bytes.buffer
}

function charCode(character) {
  return character.charCodeAt(0)
}

async function fileBuffer(path) {
  const encoded = await commands.fileFromOrigin(path)
  return bufferOf(encoded)
}

function isLarger(chunk, largest) {
  return chunk.byteSize > largest.byteSize
}

// The entry of the date running now.
function currentEntry(manifest) {
  const now = routingJourneys.serviceDateAt({manifest, departureMs: Date.now()})
  expect(now.kind).toBe(routingJourneys.ServiceDateKind.found)
  return manifest.snapshots.find((entry) => entry.serviceDate === now.serviceDate)
}

// The four tables and the largest chunk of the date running now.
async function loadFiles() {
  const manifestBuffer = await fileBuffer(MANIFEST_PATH)
  const manifest = JSON.parse(TEXT_DECODER.decode(manifestBuffer))
  const entry = currentEntry(manifest)

  for (const kind of TABLE_KINDS) {
    const buffer = await fileBuffer(entry.files[kind].path)
    files.push({kind, buffer})
  }

  let largest = entry.connectionChunks[0]

  for (const chunk of entry.connectionChunks) {
    if (isLarger(chunk, largest)) {
      largest = chunk
    }
  }

  const chunkBuffer = await fileBuffer(largest.path)
  files.push({kind: "connections", buffer: chunkBuffer})
  const sizes = Array.from(files, fileSize)
  await commands.reportMeasurement(`snapshot decode: ${entry.serviceDate}, ${sizes.join(", ")}`)
}

beforeAll(loadFiles)

function fileSize({kind, buffer}) {
  return `${kind} ${buffer.byteLength} bytes`
}

// One run: every file decoded once.
function decodeAll(routingSnapshot) {
  for (const {kind, buffer} of files) {
    const result = routingSnapshot[DECODER_NAMES[kind]](buffer)
    expect(result.kind).toBe(routingSnapshot.DecodeKind.decoded)
  }
}

function median(values) {
  const sorted = Float64Array.from(values).sort()
  return sorted[Math.floor(sorted.length / MIDDLE_DIVISOR)]
}

function measureImplementation({name, routingSnapshot}) {
  test("a date's four tables and one connection chunk", async () => {
    for (let run = 0; run < WARM_UP_RUN_COUNT; run++) {
      decodeAll(routingSnapshot)
    }

    const durationsMs = []

    for (let run = 0; run < RUN_COUNT; run++) {
      const startMs = performance.now()
      decodeAll(routingSnapshot)
      durationsMs.push(performance.now() - startMs)
    }

    const medianMs = median(durationsMs).toFixed(MILLISECOND_DIGITS)
    const line = `snapshot decode: ${name}, ${navigator.userAgent}, median ${medianMs} ms over ${RUN_COUNT} runs`
    await commands.reportMeasurement(line)
  })

  // Each file alone, decoded the run count times between two clock reads,
  // since Firefox and WebKit give a page a clock of whole milliseconds.
  test("each file alone", async () => {
    const perFile = []

    for (const {kind, buffer} of files) {
      const decoder = routingSnapshot[DECODER_NAMES[kind]]
      const startMs = performance.now()

      for (let run = 0; run < RUN_COUNT; run++) {
        decoder(buffer)
      }

      const meanMs = (performance.now() - startMs) / RUN_COUNT
      perFile.push(`${kind} ${meanMs.toFixed(MILLISECOND_DIGITS)} ms`)
    }

    await commands.reportMeasurement(`snapshot decode: ${name}, ${navigator.userAgent}, mean per file: ${perFile.join(", ")}`)
  })
}

describe.each(implementations)("snapshot decode ($name)", measureImplementation)
