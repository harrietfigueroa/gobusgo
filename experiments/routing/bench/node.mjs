// One benchmark run in a fresh node process, printed as JSON: the engine's
// cold start, its warm and repeated query latencies, and the memory the
// snapshot files and the engine hold together once loaded, measured from
// before the files are read. It is meant to run in a process of its own per
// run, so every cold start is cold; run it alone with
// `node --expose-gc bench/node.mjs`.

import {performance} from "node:perf_hooks"
import {latencies, load, queries} from "./measure.js"
import {snapshot} from "./files.mjs"

function now() {
  return performance.now()
}

function heldBytes() {
  globalThis.gc()
  const usage = process.memoryUsage()
  return usage.heapUsed + usage.arrayBuffers
}

const before = heldBytes()
const {entry, files} = snapshot()
const {engine, coldStartMs} = load({files, minimumTransferS: entry.transferRules.minimumTransferS, now})
const loadedBytes = heldBytes() - before
const queryList = queries(entry.stopCount)
const measured = latencies({engine, queryList, now})
console.log(JSON.stringify({coldStartMs, loadedBytes, ...measured}))
