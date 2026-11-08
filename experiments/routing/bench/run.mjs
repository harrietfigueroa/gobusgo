// Runs the node benchmark: each engine in five fresh processes, then prints
// the medians of each measure beside the sizes of the dataset and of the
// WebAssembly module, raw and gzipped. Run it with `node bench/run.mjs` from
// the experiment directory once the data and the module are built.

import {execFileSync} from "node:child_process"
import {gzipSync} from "node:zlib"
import {fileURLToPath} from "node:url"
import {snapshot, wasmBytes} from "./files.mjs"

const RUN_COUNT = 5
const ENGINES = ["javascript", "wasm"]
const MEBIBYTE_BYTES = 1024 * 1024
const KIBIBYTE_BYTES = 1024
const JSON_INDENT_SPACES = 2
const script = fileURLToPath(new URL("node.mjs", import.meta.url))

function ascending(left, right) {
  return left - right
}

// The median of one measure across `runs`, read by `read`.
function medianOf(runs, read) {
  const values = Array.from(runs, read)
  values.sort(ascending)
  return values[values.length >>> 1]
}

function runOnce(engineName) {
  const output = execFileSync(process.execPath, ["--expose-gc", script, engineName], {encoding: "utf-8"})
  return JSON.parse(output)
}

function coldStart(run) {
  return run.coldStartMs
}

function warmMedian(run) {
  return run.warm.medianMs
}

function warmP95(run) {
  return run.warm.p95Ms
}

function repeatedMedian(run) {
  return run.repeated.medianMs
}

function loaded(run) {
  return run.loadedBytes
}

function wasmMemory(run) {
  return run.wasmMemoryBytes
}

function sizes() {
  const {bytes} = snapshot()
  let raw = 0
  let gzipped = 0

  for (const file of bytes) {
    raw += file.byteLength
    gzipped += gzipSync(file).byteLength
  }

  const module = wasmBytes()
  const moduleGzipped = gzipSync(module)

  return {
    datasetMiB: raw / MEBIBYTE_BYTES,
    datasetGzipMiB: gzipped / MEBIBYTE_BYTES,
    wasmKiB: module.byteLength / KIBIBYTE_BYTES,
    wasmGzipKiB: moduleGzipped.byteLength / KIBIBYTE_BYTES,
  }
}

const rows = {}

for (const engineName of ENGINES) {
  const runs = []

  for (let run = 0; run < RUN_COUNT; run++) {
    runs.push(runOnce(engineName))
  }

  rows[engineName] = {
    coldStartMs: medianOf(runs, coldStart),
    warmMedianMs: medianOf(runs, warmMedian),
    warmP95Ms: medianOf(runs, warmP95),
    repeatedMedianMs: medianOf(runs, repeatedMedian),
    loadedMiB: medianOf(runs, loaded) / MEBIBYTE_BYTES,
    wasmMemoryMiB: medianOf(runs, wasmMemory) / MEBIBYTE_BYTES,
    journeyCount: runs[0].journeyCount,
  }
}

const report = {node: process.version, platform: process.platform + " " + process.arch, runs: RUN_COUNT, sizes: sizes(), engines: rows}
console.log(JSON.stringify(report, null, JSON_INDENT_SPACES))
