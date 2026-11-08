// Checks that both engines return the same frontier for every benchmark
// query over the real snapshot, which the benchmark requires before it
// compares their speed. Run it with `node test/equivalence.mjs` from the
// experiment directory once the data and the WebAssembly module are built.

import {deepStrictEqual} from "node:assert/strict"
import {performance} from "node:perf_hooks"
import {load, queries} from "../bench/measure.js"
import {snapshot, wasmBytes} from "../bench/files.mjs"

const {entry, files} = snapshot()
const common = {files, wasmBytes: wasmBytes(), minimumTransferS: entry.transferRules.minimumTransferS, now: () => performance.now()}
const javascript = await load({engineName: "javascript", ...common})
const wasm = await load({engineName: "wasm", ...common})
let journeyCount = 0

for (const query of queries(entry.stopCount)) {
  const expected = javascript.engine.route(query)
  deepStrictEqual(wasm.engine.route(query), expected, JSON.stringify(query))
  journeyCount += expected.length
}

console.log("routing equivalence: " + queries(entry.stopCount).length + " queries, " + journeyCount + " journeys, the same frontiers")
