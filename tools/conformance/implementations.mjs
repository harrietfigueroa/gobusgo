// The implementations of the core every conformance case runs against. Each
// entry names an implementation and holds its modules under the names the
// cases read, so a case takes one entry as its parameter and never imports an
// implementation itself.
//
// The JavaScript entry holds every module of the core and comes first; the
// WebAssembly entry holds the modules the Rust core has ported, and a case
// runs against each entry holding every module it reads.

import * as assert from "../../assets/js/core/assert.js"
import * as angles from "../../assets/js/core/math/angles.js"
import * as checks from "../../assets/js/core/math/checks.js"
import * as colorContrast from "../../assets/js/core/math/color_contrast.js"
import * as geodesy from "../../assets/js/core/math/geodesy.js"
import * as interpolation from "../../assets/js/core/math/interpolation.js"
import * as polyline from "../../assets/js/core/math/polyline.js"
import * as offlineAnswers from "../../assets/js/core/offline_answers.js"
import * as offlineBundle from "../../assets/js/core/offline_bundle.js"
import * as packedContainer from "../../assets/js/core/packed_container.js"
import * as pointJourneys from "../../assets/js/core/point_journeys.js"
import * as routingEngine from "../../assets/js/core/routing_engine.js"
import * as routingJourneys from "../../assets/js/core/routing_journeys.js"
import * as routingNames from "../../assets/js/core/routing_names.js"
import * as routingSnapshot from "../../assets/js/core/routing_snapshot.js"
import * as routingWalk from "../../assets/js/core/routing_walk.js"
import * as scheduledPath from "../../assets/js/core/scheduled_path.js"
import * as scheduledService from "../../assets/js/core/scheduled_service.js"
import * as tripPlan from "../../assets/js/core/trip_plan.js"
import * as tripPath from "../../assets/js/core/trip_path.js"
import * as tripPathFiles from "../../assets/js/core/trip_path_files.js"
import * as tripPathShard from "../../assets/js/core/trip_path_shard.js"
import {WEBASSEMBLY_CORE} from "./webassembly_core.mjs"

/** One entry per implementation of the core, each with its modules. */
export const IMPLEMENTATIONS = Object.freeze([
  Object.freeze({
    name: "javascript",
    AssertionError: assert.AssertionError,
    angles,
    assert,
    checks,
    colorContrast,
    geodesy,
    interpolation,
    offlineAnswers,
    offlineBundle,
    packedContainer,
    pointJourneys,
    polyline,
    routingEngine,
    routingJourneys,
    routingNames,
    routingSnapshot,
    routingWalk,
    scheduledPath,
    scheduledService,
    tripPlan,
    tripPath,
    tripPathFiles,
    tripPathShard
  }),
  WEBASSEMBLY_CORE
])

/** The entries holding every module of `moduleNames`, the JavaScript entry first. */
export function implementationsWith(...moduleNames) {
  const entries = []
  for (const implementation of IMPLEMENTATIONS) {
    if (moduleNames.every((moduleName) => moduleName in implementation)) {
      entries.push(implementation)
    }
  }
  assert.assertCondition(entries.length > 0, `conformance: no implementation holds ${moduleNames.join(", ")}`)
  assert.assertCondition(entries[0].name === "javascript", `conformance: ${entries[0].name} comes before the JavaScript entry`)
  return entries
}
