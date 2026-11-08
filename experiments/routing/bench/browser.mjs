// The browser benchmark: fetches the snapshot of the benchmark date, then
// measures the engine as the node runner does, with the fetch measured apart
// from the cold start. A reload starts the engine cold again.

import {latencies, load, queries} from "./measure.js"

const SERVICE_DATE = "2026-11-08"
const MEBIBYTE_BYTES = 1024 * 1024
const JSON_INDENT_SPACES = 2
const DATA_PATH = "../data"
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

async function run() {
  results.textContent = "Running…"
  const fetchStartedMs = now()
  const fetched = await fetchSnapshot()

  if (fetched.kind === "failed") {
    results.textContent = "Failed to fetch the snapshot: " + fetched.reason
    return
  }

  const fetchMs = now() - fetchStartedMs
  const heapBeforeMiB = heapReading()
  const {engine, coldStartMs} = load({files: fetched.files, minimumTransferS: fetched.entry.transferRules.minimumTransferS, now})
  const queryList = queries(fetched.entry.stopCount)
  const measured = latencies({engine, queryList, now})
  const report = {userAgent: navigator.userAgent, fetchMs, coldStartMs, heapBeforeMiB, heapAfterMiB: heapReading(), ...measured}
  results.textContent = JSON.stringify(report, null, JSON_INDENT_SPACES)
}

function showFailure(error) {
  results.textContent = "Failed: " + error.message
}

function start() {
  run().catch(showFailure)
}

document.getElementById("run").addEventListener("click", start)
