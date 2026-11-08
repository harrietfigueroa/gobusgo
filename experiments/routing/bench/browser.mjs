// The browser benchmark: fetches the snapshot of the benchmark date and the
// WebAssembly module, then measures each engine as the node runner does,
// with the fetch measured apart from the cold start. A reload starts every
// engine cold again.

import {latencies, load, queries} from "./measure.js"

const SERVICE_DATE = "2026-11-08"
const MEBIBYTE_BYTES = 1024 * 1024
const JSON_INDENT_SPACES = 2
const DATA_PATH = "../data"
const WASM_PATH = "../rust/target/wasm32-unknown-unknown/release/routing_csa.wasm"
const ENGINES = ["javascript", "wasm"]
const results = document.getElementById("results")

function now() {
  return performance.now()
}

async function arrayBuffer(path) {
  const response = await fetch(path)
  return await response.arrayBuffer()
}

function isBenchmarkDate(candidate) {
  return candidate.serviceDate === SERVICE_DATE
}

function chunkPath(chunk) {
  return DATA_PATH + chunk.path
}

async function fetchSnapshot() {
  const manifestResponse = await fetch(DATA_PATH + "/manifest.json")
  const manifest = await manifestResponse.json()
  const entry = manifest.snapshots.find(isBenchmarkDate)
  const stops = await arrayBuffer(DATA_PATH + entry.files.stops.path)
  const transfers = await arrayBuffer(DATA_PATH + entry.files.transfers.path)
  const chunkPaths = Array.from(entry.connectionChunks, chunkPath)
  const pending = Array.from(chunkPaths, arrayBuffer)
  const settled = await Promise.allSettled(pending)
  const connectionChunks = []

  for (const outcome of settled) {
    if (outcome.status === "rejected") {
      return {kind: "failed", reason: String(outcome.reason)}
    }

    connectionChunks.push(outcome.value)
  }

  return {kind: "fetched", entry, files: {stops, transfers, connectionChunks}}
}

// The page's JavaScript heap in MiB where the browser reports it, which
// Chrome does and Safari does not.
function heapReading() {
  if (performance.memory === undefined) {
    return "not reported by this browser"
  }

  return performance.memory.usedJSHeapSize / MEBIBYTE_BYTES
}

async function measureEngine({engineName, entry, files, wasmBytes, queryList}) {
  const heapBeforeMiB = heapReading()
  const {engine, coldStartMs} = await load({engineName, files, wasmBytes, minimumTransferS: entry.transferRules.minimumTransferS, now})
  const measured = latencies({engine, queryList, now})
  let wasmMemoryMiB = "not used"

  if (engine.memory !== undefined) {
    wasmMemoryMiB = engine.memory.buffer.byteLength / MEBIBYTE_BYTES
  }

  return {coldStartMs, heapBeforeMiB, heapAfterMiB: heapReading(), wasmMemoryMiB, ...measured}
}

async function run() {
  results.textContent = "Running…"
  const fetchStartedMs = now()
  const fetched = await fetchSnapshot()

  if (fetched.kind === "failed") {
    results.textContent = "Failed to fetch the snapshot: " + fetched.reason
    return
  }

  const wasmBytes = await arrayBuffer(WASM_PATH)
  const fetchMs = now() - fetchStartedMs
  const queryList = queries(fetched.entry.stopCount)
  const report = {userAgent: navigator.userAgent, fetchMs, engines: {}}

  for (const engineName of ENGINES) {
    const measured = await measureEngine({engineName, entry: fetched.entry, files: fetched.files, wasmBytes, queryList})
    report.engines[engineName] = measured
  }

  results.textContent = JSON.stringify(report, null, JSON_INDENT_SPACES)
}

function showFailure(error) {
  results.textContent = "Failed: " + error.message
}

function start() {
  run().catch(showFailure)
}

document.getElementById("run").addEventListener("click", start)
