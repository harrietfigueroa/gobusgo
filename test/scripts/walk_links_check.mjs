// Checks the golden fixture test/fixtures/walk_links/v1/expected.json against
// the browser's core: every query's answer over the walk graph fixture's
// shards is what the file holds, within TOLERANCE_METERS, and the fixture
// covers each kind of answer. Also checks that the snap choice rests on
// geometry: two components at an equal distance from both ends give one
// answer whichever order the shards come in. Run it with
// `node test/scripts/walk_links_check.mjs`; it exits non-zero on the first
// result that differs. `node test/scripts/walk_links_fixtures.mjs` writes
// the file again after a change.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual, ok, strictEqual} from "node:assert/strict"
import {WALK_LIMITS, WalkPathKind, findWalkPath} from "../../assets/js/core/walk_path.js"
import {TOLERANCE_METERS, goldenQueries} from "./walk_links_queries.mjs"

const goldenPath = fileURLToPath(new URL("../fixtures/walk_links/v1/expected.json", import.meta.url))
const golden = JSON.parse(readFileSync(goldenPath, "utf8"))
const computed = goldenQueries()

deepStrictEqual(computed.indexTileKeys, golden.indexTileKeys)
deepStrictEqual(computed.limits, golden.limits)
strictEqual(computed.queries.length, golden.queries.length)

for (const [position, expected] of golden.queries.entries()) {
  const actual = computed.queries[position]
  strictEqual(actual.name, expected.name)
  strictEqual(actual.kind, expected.kind, expected.name)
  deepStrictEqual(actual.tiles, expected.tiles, expected.name)
  strictEqual(actual.reason, expected.reason, expected.name)

  if (expected.kind === "found") {
    ok(Math.abs(actual.meters - expected.meters) <= TOLERANCE_METERS, expected.name + ": " + actual.meters + " m, not " + expected.meters + " m")
  }
}

const kinds = new Set(golden.queries.map((query) => query.kind + ":" + query.reason))
for (const wanted of ["found:undefined", "noPath:disconnected", "noPath:offGraph", "tooFar:undefined"]) {
  ok(kinds.has(wanted), "the fixture holds no answer of kind " + wanted)
}

// Two components, one on each side of the ends, each 20 m from both: the
// lesser start position wins, in either order of the shards.
const UNITS_PER_METER_LAT = 1 / 1.11195
const TIE_LAT = 4_760_000
const TIE_LON = -12_234_000
const OFFSET_UNITS = 20 * UNITS_PER_METER_LAT

function lineTable({latUnits, lonStartUnits, lonEndUnits}) {
  return {pieceCount: 1, classes: Uint8Array.of(4), pieceStarts: Uint32Array.of(0, 2), points: Int32Array.of(latUnits, lonStartUnits, latUnits, lonEndUnits)}
}

const above = lineTable({latUnits: Math.round(TIE_LAT + OFFSET_UNITS), lonStartUnits: TIE_LON - 400, lonEndUnits: TIE_LON + 400})
const below = lineTable({latUnits: Math.round(TIE_LAT - OFFSET_UNITS), lonStartUnits: TIE_LON - 400, lonEndUnits: TIE_LON + 400})
const from = {lat: TIE_LAT / 100_000, lon: (TIE_LON - 200) / 100_000}
const to = {lat: TIE_LAT / 100_000, lon: (TIE_LON + 200) / 100_000}
const forward = findWalkPath({from, to, shards: [above, below], limits: WALK_LIMITS})
const backward = findWalkPath({from, to, shards: [below, above], limits: WALK_LIMITS})
strictEqual(forward.kind, WalkPathKind.found)
deepStrictEqual(forward, backward, "the shard order decides the walk")
