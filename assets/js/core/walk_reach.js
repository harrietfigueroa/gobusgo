// The stops a walker can reach from a position along the walk graph, in one
// search. Everything here is pure: the tiles are given as decoded tables, and
// the answer is a value keyed by `kind`, the stops with their street meters,
// the tiles still to load, or why no stop is reached.
//
// The rules are those of `walk_path.js`, whose functions build the graph and
// snap each position, so the length a search gives a stop is the length of
// the line drawn to it: a position snaps to the nearest point of each
// component within the snap bound, the component both the position and the
// stop reach with the least summed snap distance is the one walked, and the
// street is the shortest path inside it. The search is a multi-source
// Dijkstra from the position's snap in each component, over a plane tangent
// at the position, and it settles nodes in order of cost up to the street
// bound and `visitedNodeCountMax` nodes.

import {assertCondition} from "./assert.js"
import {tileKey} from "./walk_graph_file.js"
import {NodeHeap, SnapKind, WALK_LIMITS, assertEnd, buildGraph, chooseSnaps, degreesToPlane, pieceTotal, planeOf, snapsByComponent, walkWindowTiles} from "./walk_path.js"

/** The kinds of the answer to a reach. */
export const ReachKind = Object.freeze({
  found: "found",
  notLoaded: "notLoaded",
  offGraph: "offGraph",
  noneInReach: "noneInReach",
  capReached: "capReached"
})

/**
 * The bounds of a reach beside those of a walk: the longest street a stop
 * may be reached by, in meters, and the most targets one search answers.
 */
export const WALK_REACH_LIMITS = Object.freeze({
  ...WALK_LIMITS,
  streetMetersMax: 600,
  targetCountMax: 256
})

const NO_COMPONENT = -1
const UNSETTLED = 0
const SETTLED = 1
const SearchKind = Object.freeze({done: "done", capped: "capped"})

/** The bounds of a reach whose street may be `streetMetersMax` meters, a manifest's `walkStreetMetersMax`. */
export function walkReachLimits(streetMetersMax) {
  assertCondition(Number.isFinite(streetMetersMax) && streetMetersMax > 0, "walk reach: the street bound is not positive: " + streetMetersMax)
  return {...WALK_REACH_LIMITS, streetMetersMax}
}

// The meters from `snap` to the far end of its edge, never below zero
// whatever the rounding of its distance along.
function remaining({edge, snap}) {
  return Math.max(edge.length - snap.along, 0)
}

// The component of each node of `graph`: that of any edge that ends there.
function componentsOfNodes(graph) {
  const components = new Int32Array(graph.nodeX.length).fill(NO_COMPONENT)

  for (const edge of graph.edges) {
    components[edge.a] = edge.component
    components[edge.b] = edge.component
  }

  return components
}

// A Dijkstra from the snap of the position in each component, so the
// components stay apart. A node whose cost leaves no room for its
// component's snap distance and the street bound is passed over. `cost` and
// `settled` are by node; `status` is `done`, or `capped` with `frontier`, the
// cost of the first node left unsettled at the node bound.
function dijkstra({graph, startSnaps, limits}) {
  const nodeCount = graph.nodeX.length
  const cost = new Float64Array(nodeCount).fill(Infinity)
  const settled = new Uint8Array(nodeCount).fill(UNSETTLED)
  const components = componentsOfNodes(graph)
  const bounds = new Map()
  const heap = new NodeHeap()

  function relax({node, meters}) {
    if (meters < cost[node]) {
      cost[node] = meters
      heap.push({node, priority: meters})
    }
  }

  for (const [component, snap] of startSnaps) {
    const edge = graph.edges[snap.edge]
    bounds.set(component, limits.streetMetersMax - snap.distance)
    relax({node: edge.a, meters: snap.along})
    relax({node: edge.b, meters: remaining({edge, snap})})
  }

  let settledCount = 0

  // Each pass settles a node, drops a stale or passed-over entry, or ends the
  // loop; `visitedNodeCountMax` bounds the settled nodes.
  while (heap.size > 0) {
    const node = heap.pop()

    if (settled[node] === SETTLED) {
      continue
    }

    const nodeCost = cost[node]

    if (nodeCost > limits.streetMetersMax) {
      return {kind: SearchKind.done, cost, settled}
    }

    if (nodeCost > bounds.get(components[node])) {
      continue
    }

    if (settledCount >= limits.visitedNodeCountMax) {
      return {kind: SearchKind.capped, cost, settled, frontier: nodeCost}
    }

    settled[node] = SETTLED
    settledCount += 1

    for (const edgeIndex of graph.nodeEdges[node]) {
      const edge = graph.edges[edgeIndex]
      let other = edge.a

      if (edge.a === node) {
        other = edge.b
      }

      relax({node: other, meters: nodeCost + edge.length})
    }
  }

  return {kind: SearchKind.done, cost, settled}
}

// The street meters from the start snap to the goal snap: along their one
// edge, or out of the start by an end of its edge, through the settled
// nodes, and into the goal by an end of its edge. A node the search did not
// settle stands too far and gives infinity.
function streetMeters({graph, start, goal, search}) {
  const goalEdge = graph.edges[goal.edge]
  let throughA = Infinity
  let throughB = Infinity

  if (search.settled[goalEdge.a] === SETTLED) {
    throughA = search.cost[goalEdge.a] + goal.along
  }

  if (search.settled[goalEdge.b] === SETTLED) {
    throughB = search.cost[goalEdge.b] + remaining({edge: goalEdge, snap: goal})
  }

  let sameEdge = Infinity

  if (start.edge === goal.edge) {
    sameEdge = Math.abs(goal.along - start.along)
  }

  return Math.min(throughA, throughB, sameEdge)
}

// The stops of `targets` the search reaches within the street bound, each
// `{stop, streetM}` in the order of the targets, or the capped frontier where
// a target connected to the start stands past what a search that stopped at
// its node bound settled.
function reachedStops({graph, plane, startSnaps, search, targets, limits}) {
  const stops = []

  for (const target of targets) {
    const [x, y] = degreesToPlane({plane, lat: target.lat, lon: target.lon})
    const goalSnaps = snapsByComponent({graph, x, y, snapMetersMax: limits.snapMetersMax})
    const chosen = chooseSnaps({startSnaps, goalSnaps})

    if (chosen.kind !== SnapKind.chosen) {
      continue
    }

    const street = streetMeters({graph, start: chosen.start, goal: chosen.goal, search})
    const isUnknown = search.kind === SearchKind.capped && street > search.frontier

    if (isUnknown) {
      return {kind: SearchKind.capped}
    }

    const meters = street + chosen.start.distance + chosen.goal.distance

    if (meters <= limits.streetMetersMax) {
      stops.push({stop: target.stop, streetM: meters})
    }
  }

  return {kind: SearchKind.done, stops}
}

/**
 * The stops among `targets`, each `{stop, lat, lon}` in degrees, that a
 * walker at `position`, `{lat, lon}` in degrees, reaches along the streets
 * within `limits.streetMetersMax` meters, over `index`, a Set of the
 * `tileKey` of every tile with a shard, and `loaded`, a Map from a `tileKey`
 * to its decoded shard table: a ReachKind member. `{kind: "found", stops}`
 * holds each stop reached as `{stop, streetM}`, the meters of the whole line
 * from the position to the stop, in the order of the targets;
 * `{kind: "notLoaded", tiles}` names the tiles of the 3 by 3 window around
 * the position's tile that `loaded` lacks, which are the whole of what the
 * search reads; `offGraph` is a position farther than `limits.snapMetersMax`
 * from every piece, or a window with none; `noneInReach` is a position on the
 * graph with no target in reach; and `capReached` is a window of more than
 * `limits.edgeCountMax` pieces, or a search that settled
 * `limits.visitedNodeCountMax` nodes with a target still unknown, answers
 * that leave the walk straight. At most `limits.targetCountMax` targets.
 */
export function walkReach({position, targets, index, loaded, limits}) {
  assertEnd(position, "position")
  assertCondition(targets.length <= limits.targetCountMax, "walk reach: " + targets.length + " targets are more than " + limits.targetCountMax)

  for (const target of targets) {
    assertEnd(target, "target")
  }

  const tiles = walkWindowTiles({position, index})
  const missing = []
  const shards = []

  for (const tile of tiles) {
    const key = tileKey(tile)

    if (loaded.has(key)) {
      shards.push(loaded.get(key))
    } else {
      missing.push(tile)
    }
  }

  if (missing.length > 0) {
    return {kind: ReachKind.notLoaded, tiles: missing}
  }

  const pieceCount = pieceTotal(shards)

  if (pieceCount === 0) {
    return {kind: ReachKind.offGraph}
  }

  if (pieceCount > limits.edgeCountMax) {
    return {kind: ReachKind.capReached}
  }

  const plane = planeOf({from: position, to: position})
  const graph = buildGraph({shards, plane})
  const [startX, startY] = degreesToPlane({plane, lat: position.lat, lon: position.lon})
  const startSnaps = snapsByComponent({graph, x: startX, y: startY, snapMetersMax: limits.snapMetersMax})

  if (startSnaps.size === 0) {
    return {kind: ReachKind.offGraph}
  }

  const search = dijkstra({graph, startSnaps, limits})
  const reached = reachedStops({graph, plane, startSnaps, search, targets, limits})

  if (reached.kind === SearchKind.capped) {
    return {kind: ReachKind.capReached}
  }

  if (reached.stops.length === 0) {
    return {kind: ReachKind.noneInReach}
  }

  return {kind: ReachKind.found, stops: reached.stops}
}
