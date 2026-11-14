// Checks the golden file of the walk queries against the browser's core:
// every query's answer over the walk graph fixture's shards is what the file
// holds, within TOLERANCE_METERS, and the file covers each kind of answer.
// Also checks that the snap choice rests on geometry: two components at an
// equal distance from both ends give one answer whichever order the shards
// come in. Run it with `node test/scripts/walk_links_check.mjs`; it exits
// non-zero on the first result that differs.

import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {deepStrictEqual, ok, strictEqual} from "node:assert/strict"
import {UNITS_PER_DEGREE} from "../../assets/js/core/walk_graph_file.js"
import {METERS_PER_DEGREE} from "../../assets/js/core/math/geodesy.js"
import {WALK_LIMITS, WalkPathKind, findWalkPath} from "../../assets/js/core/walk_path.js"
import {TOLERANCE_METERS, goldenQueries} from "./walk_links_queries.mjs"

const goldenPath = fileURLToPath(new URL("../fixtures/walk_links/v1/expected.json", import.meta.url))
const TIE_LAT_UNITS = 4_760_000
const TIE_LON_UNITS = -12_234_000
const TIE_OFFSET_METERS = 20
const LINE_HALF_UNITS = 400
const ENDS_HALF_UNITS = 200
const PIECE_COUNT = 1
const STREET_CLASS = 4
const FIRST_POINT = 0
const SECOND_POINT = 2
const WANTED_KINDS = ["found:undefined", "noPath:disconnected", "noPath:offGraph", "tooFar:undefined"]

function kindOf(query) {
  return query.kind + ":" + query.reason
}

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

const goldenKinds = Array.from(golden.queries, kindOf)
const kinds = new Set(goldenKinds)

for (const wanted of WANTED_KINDS) {
  ok(kinds.has(wanted), "the golden file holds no answer of kind " + wanted)
}

// Two components, one on each side of the ends, each as far from both: the
// lesser start position wins, in either order of the shards.
const offsetUnits = Math.round((TIE_OFFSET_METERS * UNITS_PER_DEGREE) / METERS_PER_DEGREE)

function lineTable({latUnits}) {
  const points = Int32Array.of(latUnits, TIE_LON_UNITS - LINE_HALF_UNITS, latUnits, TIE_LON_UNITS + LINE_HALF_UNITS)
  return {pieceCount: PIECE_COUNT, classes: Uint8Array.of(STREET_CLASS), pieceStarts: Uint32Array.of(FIRST_POINT, SECOND_POINT), points}
}

const above = lineTable({latUnits: TIE_LAT_UNITS + offsetUnits})
const below = lineTable({latUnits: TIE_LAT_UNITS - offsetUnits})
const from = {lat: TIE_LAT_UNITS / UNITS_PER_DEGREE, lon: (TIE_LON_UNITS - ENDS_HALF_UNITS) / UNITS_PER_DEGREE}
const to = {lat: TIE_LAT_UNITS / UNITS_PER_DEGREE, lon: (TIE_LON_UNITS + ENDS_HALF_UNITS) / UNITS_PER_DEGREE}
const forward = findWalkPath({from, to, shards: [above, below], limits: WALK_LIMITS})
const backward = findWalkPath({from, to, shards: [below, above], limits: WALK_LIMITS})
strictEqual(forward.kind, WalkPathKind.found)
deepStrictEqual(forward, backward, "the shard order decides the walk")
