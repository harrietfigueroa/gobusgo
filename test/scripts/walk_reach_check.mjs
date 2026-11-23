// Checks the stops a rider can walk to over the walk graph, in the browser's
// core: the one-to-many search from a position over the golden file's
// fixture graph agrees with the drawn walk, `planWalk`, to within
// TOLERANCE_METERS for every pair of its points, so the planned time of a
// walk from a position is the length of the line drawn. Also the answers of
// each other kind (an island, a position off the graph, tiles not loaded, a
// cap reached, no stop in reach), the target bound as an assertion, that the
// street search's candidates fit that bound, and that the seconds of the start
// stops a reach gives are those of the line drawn.
// Run it with `node test/scripts/walk_reach_check.mjs`; it exits non-zero on
// the first result that differs.

import {deepStrictEqual, ok, strictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {tileKey} from "../../assets/js/core/walk_graph_file.js"
import {WALK_LIMITS, WalkPathKind, planWalk} from "../../assets/js/core/walk_path.js"
import {ReachKind, WALK_REACH_LIMITS, walkReach, walkReachLimits} from "../../assets/js/core/walk_reach.js"
import {WALK_CANDIDATE_COUNT_MAX, startsFromStreets} from "../../assets/js/core/routing_walk.js"
import {TOLERANCE_METERS, goldenGraph} from "./walk_links_queries.mjs"

const STREET_METERS_MAX = 600
const WALK_SPEED_M_PER_S = 1.2
const LINK_COUNT_MAX = 64
const ONE_NODE = 1
const SHORT_STREET_METERS = 100
const TARGET_OVER_COUNT = WALK_REACH_LIMITS.targetCountMax + 1
const WEST_TILE_KEY = "4761_-8156"

const {indexTable, shardsByKey, points} = goldenGraph()
const index = indexTable.tileKeys
const limits = walkReachLimits(STREET_METERS_MAX)

function pointNamed(name) {
  const point = points.find((candidate) => candidate.name === name)
  ok(point !== undefined, "the golden graph has no point named " + name)
  return point
}

function targetOf(point, stop) {
  return {stop, lat: point.lat, lon: point.lon}
}

function reachFrom({start, targets, loaded = shardsByKey, indexHeld = index, limitsHeld = limits}) {
  return walkReach({position: {lat: start.lat, lon: start.lon}, targets, index: indexHeld, loaded, limits: limitsHeld})
}

function stopOf(reached) {
  return reached.stop
}

// Every golden point but `start`, as targets numbered in the order of the points.
function targetsExcluding(start) {
  const targets = []

  for (const point of points) {
    if (point.name !== start.name) {
      targets.push(targetOf(point, targets.length))
    }
  }

  return targets
}

function targetAtStart(unused, stop) {
  return targetOf(pointNamed("north middle"), stop)
}

function reachWithTooMany() {
  return reachFrom({start: pointNamed("north middle"), targets: Array.from({length: TARGET_OVER_COUNT}, targetAtStart)})
}

// Every pair of the golden points: a street length at most the bound that the
// drawn walk has is the reach's, to a tolerance, and any other pair is not
// reached.
for (const start of points) {
  // The two streets of the tie are exactly as near "tie first" and "tie
  // second" as each other; the tie goes to the ends and segment starts in the
  // graph's units, which the plane at the position and the plane at the
  // middle of a pair share, so from either end the reach takes the street
  // the drawn walk takes.
  const others = points.filter((candidate) => candidate.name !== start.name)
  const targets = Array.from(others, targetOf)
  const reached = reachFrom({start, targets})

  if (reached.kind !== ReachKind.found) {
    for (const target of others) {
      const drawn = planWalk({from: start, to: target, index, loaded: shardsByKey, limits: WALK_LIMITS})
      const isReachable = drawn.kind === WalkPathKind.found && drawn.meters <= STREET_METERS_MAX
      ok(!isReachable, start.name + " reaches no stop, yet the walk to " + target.name + " is " + drawn.meters + " m")
    }

    continue
  }

  const reachedByStop = new Map()

  for (const stop of reached.stops) {
    reachedByStop.set(stop.stop, stop.streetM)
  }

  for (const [stop, target] of others.entries()) {
    const drawn = planWalk({from: start, to: target, index, loaded: shardsByKey, limits: WALK_LIMITS})
    const isDrawnReachable = drawn.kind === WalkPathKind.found && drawn.meters <= STREET_METERS_MAX
    const label = start.name + " to " + target.name
    strictEqual(reachedByStop.has(stop), isDrawnReachable, label + ": reached " + reachedByStop.get(stop) + " m, drawn " + drawn.meters + " m")

    if (isDrawnReachable) {
      ok(Math.abs(reachedByStop.get(stop) - drawn.meters) <= TOLERANCE_METERS, label + ": reached " + reachedByStop.get(stop) + " m, drawn " + drawn.meters + " m")
    }
  }
}

// The island has its own streets: from it only its own are reached.
const islandWest = pointNamed("island west")
const islandMiddle = pointNamed("island middle")
const northMiddle = pointNamed("north middle")
const onIsland = reachFrom({start: islandWest, targets: [targetOf(islandMiddle, 0), targetOf(northMiddle, 1)]})
strictEqual(onIsland.kind, ReachKind.found)
const islandStops = Array.from(onIsland.stops, stopOf)
deepStrictEqual(islandStops, [0], "only the island's own stop is reached from the island")

// A position no piece is within the snap bound of is off the graph.
const offGraph = reachFrom({start: pointNamed("off the graph"), targets: [targetOf(northMiddle, 0)]})
deepStrictEqual(offGraph, {kind: ReachKind.offGraph})

// Tiles the index holds and the held map lacks come back to be fetched.
const withoutWest = new Map(shardsByKey)
withoutWest.delete(WEST_TILE_KEY)
const notLoaded = reachFrom({start: northMiddle, targets: [targetOf(pointNamed("south middle"), 0)], loaded: withoutWest})
strictEqual(notLoaded.kind, ReachKind.notLoaded)
const missingKeys = Array.from(notLoaded.tiles, tileKey)
deepStrictEqual(missingKeys, [WEST_TILE_KEY])

// An index with no tile near the position holds no piece: off the graph.
const emptyIndex = new Set()
deepStrictEqual(reachFrom({start: northMiddle, targets: [targetOf(pointNamed("south middle"), 0)], indexHeld: emptyIndex}), {kind: ReachKind.offGraph})

// A search that settles its node bound with a target still beyond it is a cap.
const cappedTargets = targetsExcluding(northMiddle)
const capped = reachFrom({start: northMiddle, targets: cappedTargets, limitsHeld: {...limits, visitedNodeCountMax: ONE_NODE}})
strictEqual(capped.kind, ReachKind.capReached)

// Stops farther by street than the bound are not reached, and none in reach is its own answer.
const tight = reachFrom({start: northMiddle, targets: [targetOf(pointNamed("south east"), 0)], limitsHeld: walkReachLimits(SHORT_STREET_METERS)})
deepStrictEqual(tight, {kind: ReachKind.noneInReach})
deepStrictEqual(reachFrom({start: northMiddle, targets: []}), {kind: ReachKind.noneInReach})

// More targets than the bound is a programmer error.
throws(reachWithTooMany, AssertionError)

// The bound is the manifest's, and a reader takes the shared limits otherwise.
deepStrictEqual({...WALK_REACH_LIMITS, streetMetersMax: STREET_METERS_MAX}, limits)

ok(WALK_CANDIDATE_COUNT_MAX <= WALK_REACH_LIMITS.targetCountMax, "the candidates fit the search's target bound")

// The seconds of the start stops a reach gives are those of the line drawn.
const rules = {walkRadiusM: 400, walkSpeedMPerS: WALK_SPEED_M_PER_S, walkLinkCountPerStopMax: LINK_COUNT_MAX, walkStreetMetersMax: STREET_METERS_MAX}
const north = pointNamed("north west")
const targets = targetsExcluding(north)
const reachedFromNorth = reachFrom({start: north, targets})
strictEqual(reachedFromNorth.kind, ReachKind.found)
const starts = startsFromStreets({stops: reachedFromNorth.stops, transferRules: rules})
ok(starts.length > 1, "the golden graph reaches more than one stop from a point")

for (const start of starts) {
  const target = targets[start.stop]
  const drawn = planWalk({from: north, to: target, index, loaded: shardsByKey, limits: WALK_LIMITS})
  strictEqual(drawn.kind, WalkPathKind.found)
  strictEqual(start.walkS, Math.ceil(drawn.meters / WALK_SPEED_M_PER_S), "the walk to " + target.name + " takes the time of the line drawn")
}

console.log("walk reach checks passed")
