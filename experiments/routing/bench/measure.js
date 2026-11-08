// The measurements of the routing benchmark, shared by the node runner and
// the browser page so both report the same quantities: the time to build an
// engine from snapshot files (cold start), the latency of a fixed set of
// queries once warm, and the latency of one query repeated. The queries come
// from a seeded generator, so every run and every engine routes the same
// ones. The clock is the caller's `now`, in milliseconds.

import {loadJavaScriptEngine, loadWasmEngine} from "../engine/load.js"

export const QUERY_COUNT = 200
export const REPEAT_COUNT = 50
export const QUERY_SEED = 232
const HOUR_SECONDS = 60 * 60
const DEPARTURE_HOUR_MIN = 6
const DEPARTURE_HOUR_SPAN = 16
const LCG_MULTIPLIER = 1664525
const LCG_INCREMENT = 1013904223
const LCG_MODULUS = 4294967296
const PERCENTILE_95 = 0.95

/** The benchmark's queries over a snapshot of `stopCount` stops, the same for every run. */
export function queries(stopCount) {
  let state = QUERY_SEED
  const result = []

  function next() {
    state = (state * LCG_MULTIPLIER + LCG_INCREMENT) % LCG_MODULUS
    return state / LCG_MODULUS
  }

  for (let index = 0; index < QUERY_COUNT; index++) {
    const source = Math.floor(next() * stopCount)
    const target = Math.floor(next() * stopCount)
    const departureS = (DEPARTURE_HOUR_MIN + next() * DEPARTURE_HOUR_SPAN) * HOUR_SECONDS
    result.push({source, target, departureS: Math.floor(departureS)})
  }

  return result
}

function ascending(left, right) {
  return left - right
}

function summary(durationsMs) {
  const sorted = Array.from(durationsMs).sort(ascending)
  const middle = sorted.length >>> 1
  const p95 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * PERCENTILE_95))]
  return {medianMs: sorted[middle], p95Ms: p95, maxMs: sorted[sorted.length - 1]}
}

/** Builds the engine named `engineName` from `files` and returns it with its cold start. */
export async function load({engineName, files, wasmBytes, minimumTransferS, now}) {
  const startedMs = now()

  if (engineName === "wasm") {
    const module = await WebAssembly.compile(wasmBytes)
    const engine = await loadWasmEngine({module, files, minimumTransferS})
    return {engine, coldStartMs: now() - startedMs}
  }

  const engine = loadJavaScriptEngine({files, minimumTransferS})
  return {engine, coldStartMs: now() - startedMs}
}

/** The warm and repeated query latencies of `engine` over `queryList`. */
export function latencies({engine, queryList, now}) {
  for (const query of queryList) {
    engine.route(query)
  }

  const warm = []
  let journeyCount = 0

  for (const query of queryList) {
    const startedMs = now()
    const frontier = engine.route(query)
    warm.push(now() - startedMs)
    journeyCount += frontier.length
  }

  const repeated = []
  const [first] = queryList

  for (let repeat = 0; repeat < REPEAT_COUNT; repeat++) {
    const startedMs = now()
    engine.route(first)
    repeated.push(now() - startedMs)
  }

  return {warm: summary(warm), repeated: summary(repeated), journeyCount}
}
