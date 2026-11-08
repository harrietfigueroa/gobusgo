// One benchmark run of one engine in a fresh node process, printed as JSON:
// its cold start, its warm and repeated query latencies, and the memory it
// holds once loaded. It is meant to run in a process of its own per run, so
// every cold start is cold; run it alone with
// `node --expose-gc bench/node.mjs javascript|wasm`.

import {performance} from "node:perf_hooks"
import {latencies, load, queries} from "./measure.js"
import {snapshot, wasmBytes} from "./files.mjs"

const ARGUMENTS_START = 2
const [engineName] = process.argv.slice(ARGUMENTS_START)
const {entry, files} = snapshot()
const bytes = wasmBytes()

function now() {
  return performance.now()
}

function heldBytes() {
  globalThis.gc()
  const usage = process.memoryUsage()
  return usage.heapUsed + usage.arrayBuffers
}

const before = heldBytes()
const {engine, coldStartMs} = await load({engineName, files, wasmBytes: bytes, minimumTransferS: entry.transferRules.minimumTransferS, now})
const loadedBytes = heldBytes() - before
const queryList = queries(entry.stopCount)
const measured = latencies({engine, queryList, now})
let wasmMemoryBytes = 0

if (engine.memory !== undefined) {
  wasmMemoryBytes = engine.memory.buffer.byteLength
}

console.log(JSON.stringify({engineName, coldStartMs, loadedBytes, wasmMemoryBytes, ...measured}))
