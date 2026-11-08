// Runs the node benchmark in five fresh processes, then prints the medians of
// each measure beside the size of the dataset, raw and gzipped. Run it with
// `node bench/run.mjs` from the experiment directory once the data is built.

import {execFileSync} from "node:child_process"
import {gzipSync} from "node:zlib"
import {fileURLToPath} from "node:url"
import {snapshot} from "./files.mjs"

const RUN_COUNT = 5
const MEBIBYTE_BYTES = 1024 * 1024
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

function runOnce() {
  const output = execFileSync(process.execPath, ["--expose-gc", script], {encoding: "utf-8"})
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

function sizes() {
  const {bytes} = snapshot()
  let raw = 0
  let gzipped = 0

  for (const file of bytes) {
    raw += file.byteLength
    gzipped += gzipSync(file).byteLength
  }

  return {datasetMiB: raw / MEBIBYTE_BYTES, datasetGzipMiB: gzipped / MEBIBYTE_BYTES}
}

const runs = []

for (let run = 0; run < RUN_COUNT; run++) {
  runs.push(runOnce())
}

const engine = {
  coldStartMs: medianOf(runs, coldStart),
  warmMedianMs: medianOf(runs, warmMedian),
  warmP95Ms: medianOf(runs, warmP95),
  repeatedMedianMs: medianOf(runs, repeatedMedian),
  loadedMiB: medianOf(runs, loaded) / MEBIBYTE_BYTES,
  journeyCount: runs[0].journeyCount,
}

const report = {node: process.version, platform: process.platform + " " + process.arch, runs: RUN_COUNT, sizes: sizes(), engine}
console.log(JSON.stringify(report, null, JSON_INDENT_SPACES))
