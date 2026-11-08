// Checks both engines against the hand-written journeys of
// ../fixtures/journeys.json: each case's timetable is written as snapshot
// files, loaded into the JavaScript engine and the WebAssembly engine, and
// every query's frontier, read back as readable legs, must equal the
// expected one in both. Run it with `node test/fixtures.mjs` from the
// experiment directory after `cargo build --release --target
// wasm32-unknown-unknown` in rust/; it exits non-zero on the first mismatch.

import {readFileSync} from "node:fs"
import {deepStrictEqual} from "node:assert/strict"
import {LegKind} from "../engine/csa.js"
import {loadJavaScriptEngine, loadWasmEngine} from "../engine/load.js"
import {clock, seconds, snapshotOf} from "./timetable.js"

const TRANSFER_S_MIN = 120
const root = new URL("../", import.meta.url)
const fixturesText = readFileSync(new URL("fixtures/journeys.json", root), "utf-8")
const fixtures = JSON.parse(fixturesText)
const wasmBytes = readFileSync(new URL("rust/target/wasm32-unknown-unknown/release/routing_csa.wasm", root))
const module = await WebAssembly.compile(wasmBytes)

// A frontier as the readable legs the fixtures are written in.
function readable({frontier, snapshot}) {
  return Array.from(frontier, journey => ({
    arrive: clock(journey.arrivalS),
    changes: journey.changes,
    legs: Array.from(journey.legs, leg => {
      if (leg.kind === LegKind.walk) {
        return "walk " + snapshot.stopIds[leg.fromStop] + " " + snapshot.stopIds[leg.toStop] + " " + leg.durationS
      }

      const board = snapshot.connections[leg.boardConnection]
      const alight = snapshot.connections[leg.alightConnection]
      const parts = [
        "ride",
        snapshot.tripIds[board.trip],
        snapshot.stopIds[board.departureStop],
        clock(board.departureS),
        snapshot.stopIds[alight.arrivalStop],
        clock(alight.arrivalS),
      ]
      return parts.join(" ")
    }),
  }))
}

let checked = 0

for (const fixture of fixtures.cases) {
  const snapshot = snapshotOf(fixture)
  const wasm = await loadWasmEngine({module, files: snapshot.files, minimumTransferS: TRANSFER_S_MIN})
  const engines = {
    javascript: loadJavaScriptEngine({files: snapshot.files, minimumTransferS: TRANSFER_S_MIN}),
    wasm,
  }

  for (const query of fixture.queries) {
    const routed = {
      source: snapshot.stopIndex.get(query.from),
      target: snapshot.stopIndex.get(query.to),
      departureS: seconds(query.depart),
    }

    for (const [name, engine] of Object.entries(engines)) {
      const frontier = engine.route(routed)
      const label = fixture.name + ", " + query.from + " to " + query.to + " at " + query.depart + ", " + name
      deepStrictEqual(readable({frontier, snapshot}), query.expected, label)
      checked += 1
    }
  }
}

console.log("routing fixtures: " + checked + " frontiers match, both engines")
