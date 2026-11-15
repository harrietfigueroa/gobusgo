// The shortest path along streets between the two ends of a walk, over the
// pieces of way of the walk graph's shards. Everything here is pure: the
// shards a walk needs are given as decoded tables, and the answer is a value
// keyed by `kind`, a path, the reason there is none, or the tiles that are
// still to be loaded, so the caller keeps the straight line for any but a
// path.
//
// A graph is built over the shards for one walk. A node is a position that
// ends a piece, and pieces that end at one position, whether in one shard or
// two, meet there. Each end of the walk is snapped to the nearest point on
// any piece within `snapMetersMax`; that point is a virtual node that joins
// the two ends of its piece. The search is A* with the straight-line
// distance as its heuristic, over a plane tangent at the walk's middle, in
// which an edge's length is its polyline's length, so the heuristic never
// overestimates. It stops after `visitedNodeCountMax` nodes.

import {assertCondition, unreachable} from "./assert.js"
import {METERS_PER_DEGREE, metersPerDegreeLongitude} from "./math/geodesy.js"
import {UNITS_PER_DEGREE, tileKey, tileOf} from "./walk_graph_file.js"

/** The kinds of the answer to a walk. */
export const WalkPathKind = Object.freeze({found: "found", noPath: "noPath", notLoaded: "notLoaded"})

/** Why a walk has no path. */
export const NoPathReason = Object.freeze({
  tooFar: "tooFar",
  noShards: "noShards",
  offGraph: "offGraph",
  disconnected: "disconnected",
  capReached: "capReached"
})

/**
 * The bounds of a walk's search. `distanceMetersMax` is the farthest apart
 * the ends may stand, `snapMetersMax` the farthest an end may stand from
 * the nearest piece, `tileCountMax` the most tiles a walk reads,
 * `edgeCountMax` the most pieces a graph holds, and `visitedNodeCountMax`
 * the most nodes the search settles.
 */
export const WALK_LIMITS = Object.freeze({
  distanceMetersMax: 1_500,
  snapMetersMax: 100,
  tileCountMax: 16,
  edgeCountMax: 250_000,
  visitedNodeCountMax: 30_000
})

const COORDINATE_COUNT = 2
const LATITUDE_DEGREES_MAX = 90
const LONGITUDE_DEGREES_MAX = 180
const POSITION_KEY_LAT_OFFSET = 9_000_000
const POSITION_KEY_LON_OFFSET = 18_000_000
const POSITION_KEY_LAT_SCALE = 67_108_864
const NO_NODE = -1
const NO_EDGE = -1
const MIDDLE_DIVISOR = 2
const WINDOW_RADIUS = 1
const VIRTUAL_NODE_COUNT = 2
const HEAP_ARITY = 2
const DUPLICATE_METERS = 0.001
const DRAWN_COST_TOLERANCE_METERS = 0.01
const TIE_UNITS_PER_METER = 1_000_000
const KEY_ENDS_FROM = 3
const KEY_ENDS_TO = 7
const TilesKind = Object.freeze({tiles: "tiles", tooFar: "tooFar"})
export const SnapKind =Object.freeze({snapped: "snapped", chosen: "chosen", none: "none"})
const SearchKind = Object.freeze({reached: "reached", exhausted: "exhausted", capped: "capped"})

export function planeOf({from, to}) {
  const referenceLat = (from.lat + to.lat) / MIDDLE_DIVISOR
  const referenceLon = (from.lon + to.lon) / MIDDLE_DIVISOR
  return {referenceLat, referenceLon, metersPerLat: METERS_PER_DEGREE, metersPerLon: metersPerDegreeLongitude(referenceLat)}
}

// The length of the vector (deltaX, deltaY) as the square root of the sum of
// its squares, so a sum is computed in one order wherever it is made.
export function distanceOf(deltaX, deltaY) {
  return Math.sqrt(deltaX * deltaX + deltaY * deltaY)
}

// The two ends of an edge as one list of four numbers, the lesser end first,
// so the same piece has the same ends whichever way it is walked.
function endsOf({firstEnd, lastEnd}) {
  if (compareLists(firstEnd, lastEnd) <= 0) {
    return [...firstEnd, ...lastEnd]
  }

  return [...lastEnd, ...firstEnd]
}

// The first difference of two lists of numbers, which is negative where
// `left` comes first, and 0 where they are equal.
function compareLists(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return left[index] - right[index]
    }
  }

  return 0
}

// A position in degrees as meters east and north on the plane.
export function degreesToPlane({plane, lat, lon}) {
  return [(lon - plane.referenceLon) * plane.metersPerLon, (lat - plane.referenceLat) * plane.metersPerLat]
}

function unitsToPlane({plane, latUnits, lonUnits}) {
  return degreesToPlane({plane, lat: latUnits / UNITS_PER_DEGREE, lon: lonUnits / UNITS_PER_DEGREE})
}

// A point on the plane as a GeoJSON coordinate, [lon, lat].
function planeToCoordinate({plane, x, y}) {
  return [plane.referenceLon + x / plane.metersPerLon, plane.referenceLat + y / plane.metersPerLat]
}

export function assertEnd(end, name) {
  assertCondition(Number.isFinite(end.lat), "walk path: the " + name + " latitude is a number")
  assertCondition(Number.isFinite(end.lon), "walk path: the " + name + " longitude is a number")
  assertCondition(Math.abs(end.lat) <= LATITUDE_DEGREES_MAX, "walk path: the " + name + " latitude is on the globe")
  assertCondition(Math.abs(end.lon) <= LONGITUDE_DEGREES_MAX, "walk path: the " + name + " longitude is on the globe")
}

function straightMeters({plane, from, to}) {
  const [fromX, fromY] = degreesToPlane({plane, lat: from.lat, lon: from.lon})
  const [toX, toY] = degreesToPlane({plane, lat: to.lat, lon: to.lon})
  return distanceOf(toX - fromX, toY - fromY)
}

// The 3 by 3 tiles around the tile of `end`, `{lat, lon}` in degrees, each
// `{row, column}`, whether or not the index holds them.
function windowAround(end) {
  const latUnits = Math.floor(end.lat * UNITS_PER_DEGREE)
  const lonUnits = Math.floor(end.lon * UNITS_PER_DEGREE)
  const center = tileOf({lat: latUnits, lon: lonUnits})
  const tiles = []

  for (let row = center.row - WINDOW_RADIUS; row <= center.row + WINDOW_RADIUS; row += 1) {
    for (let column = center.column - WINDOW_RADIUS; column <= center.column + WINDOW_RADIUS; column += 1) {
      tiles.push({row, column})
    }
  }

  return tiles
}

/**
 * The tiles of the 3 by 3 window around the tile of `position`, `{lat, lon}`
 * in degrees, that `index`, a Set of `tileKey`s, holds, each `{row, column}`,
 * in row then column order: the tiles `walkTilesNeeded` reads for the walk
 * that has `position` for an end, which is the whole of what a search from
 * `position` needs.
 */
export function walkWindowTiles({position, index}) {
  assertEnd(position, "position")
  const tiles = []

  for (const tile of windowAround(position)) {
    if (index.has(tileKey(tile))) {
      tiles.push(tile)
    }
  }

  tiles.sort(compareTiles)
  return tiles
}

/**
 * The tiles a walk from `from` to `to`, each `{lat, lon}` in degrees, reads:
 * the 3 by 3 tiles around the tile of each end that `index`, a Set of
 * `tileKey`s, holds. The answer is `{kind: "tiles", tiles}`, each tile
 * `{row, column}` in row then column order, or `{kind: "tooFar"}` where the
 * two windows together hold more than `limits.tileCountMax` tiles. The
 * answer is a function of the tiles of the two ends alone.
 */
export function walkTilesNeeded({from, to, index, limits}) {
  assertEnd(from, "from")
  assertEnd(to, "to")
  const windowed = new Map()

  for (const end of [from, to]) {
    for (const tile of windowAround(end)) {
      windowed.set(tileKey(tile), tile)
    }
  }

  if (windowed.size > limits.tileCountMax) {
    return {kind: TilesKind.tooFar}
  }

  const tiles = []

  for (const [key, tile] of windowed) {
    if (index.has(key)) {
      tiles.push(tile)
    }
  }

  tiles.sort(compareTiles)
  return {kind: TilesKind.tiles, tiles}
}

function compareTiles(first, second) {
  if (first.row !== second.row) {
    return first.row - second.row
  }

  return first.column - second.column
}

function positionKey({latUnits, lonUnits}) {
  return (latUnits + POSITION_KEY_LAT_OFFSET) * POSITION_KEY_LAT_SCALE + (lonUnits + POSITION_KEY_LON_OFFSET)
}

export function pieceTotal(shards) {
  let total = 0

  for (const shard of shards) {
    total += shard.pieceCount
  }

  return total
}

// The edge of one piece: its polyline on the plane, the distance along it at
// each position, and the nodes at its ends.
function edgeOfPiece({shard, piece, plane, nodeAt}) {
  const first = shard.pieceStarts[piece]
  const count = shard.pieceStarts[piece + 1] - first
  const xy = new Float64Array(count * COORDINATE_COUNT)
  const cumulative = new Float64Array(count)

  for (let position = 0; position < count; position += 1) {
    const offset = (first + position) * COORDINATE_COUNT
    const [x, y] = unitsToPlane({plane, latUnits: shard.points[offset], lonUnits: shard.points[offset + 1]})
    xy[position * COORDINATE_COUNT] = x
    xy[position * COORDINATE_COUNT + 1] = y

    if (position > 0) {
      const before = (position - 1) * COORDINATE_COUNT
      cumulative[position] = cumulative[position - 1] + distanceOf(x - xy[before], y - xy[before + 1])
    }
  }

  const firstOffset = first * COORDINATE_COUNT
  const lastOffset = (first + count - 1) * COORDINATE_COUNT
  const a = nodeAt({latUnits: shard.points[firstOffset], lonUnits: shard.points[firstOffset + 1]})
  const b = nodeAt({latUnits: shard.points[lastOffset], lonUnits: shard.points[lastOffset + 1]})
  const firstEnd = [shard.points[firstOffset], shard.points[firstOffset + 1]]
  const lastEnd = [shard.points[lastOffset], shard.points[lastOffset + 1]]
  const ends = endsOf({firstEnd, lastEnd})
  return {a, b, xy, cumulative, length: cumulative[count - 1], count, ends}
}

// The graph over `shards`: for each piece an edge between the nodes at its
// ends, and for each node the edges that end there.
export function buildGraph({shards, plane}) {
  const nodeByKey = new Map()
  const nodeX = []
  const nodeY = []
  const nodeEdges = []
  const edges = []

  function nodeAt({latUnits, lonUnits}) {
    const key = positionKey({latUnits, lonUnits})
    const held = nodeByKey.get(key)

    if (held !== undefined) {
      return held
    }

    const [x, y] = unitsToPlane({plane, latUnits, lonUnits})
    const node = nodeX.length
    nodeByKey.set(key, node)
    nodeX.push(x)
    nodeY.push(y)
    nodeEdges.push([])
    return node
  }

  for (const shard of shards) {
    for (let piece = 0; piece < shard.pieceCount; piece += 1) {
      const edge = edgeOfPiece({shard, piece, plane, nodeAt})
      assertCondition(edge.a !== edge.b, "walk path: a piece starts and ends at one node")
      const edgeIndex = edges.length
      edges.push(edge)
      nodeEdges[edge.a].push(edgeIndex)
      nodeEdges[edge.b].push(edgeIndex)
    }
  }

  labelComponents({nodeCount: nodeX.length, edges})
  return {nodeX, nodeY, nodeEdges, edges}
}

// Gives each edge the number of the connected component its ends are in,
// by a union-find over the nodes.
function labelComponents({nodeCount, edges}) {
  const parent = new Int32Array(nodeCount)

  for (let node = 0; node < nodeCount; node += 1) {
    parent[node] = node
  }

  function root(node) {
    let current = node

    // Each step moves to a node nearer the root of a finite forest.
    while (parent[current] !== current) {
      parent[current] = parent[parent[current]]
      current = parent[current]
    }

    return current
  }

  for (const edge of edges) {
    parent[root(edge.a)] = root(edge.b)
  }

  for (const edge of edges) {
    edge.component = root(edge.a)
  }
}

// The nearest point of the segment from (startX, startY) to (endX, endY) to
// (x, y): its position, its distance from (x, y), and how far along the
// segment it lies, as a share.
function nearestOnSegment({x, y, startX, startY, endX, endY}) {
  const deltaX = endX - startX
  const deltaY = endY - startY
  const lengthSquared = deltaX * deltaX + deltaY * deltaY
  let fraction = 0

  if (lengthSquared > 0) {
    fraction = Math.min(1, Math.max(0, ((x - startX) * deltaX + (y - startY) * deltaY) / lengthSquared))
  }

  const pointX = startX + fraction * deltaX
  const pointY = startY + fraction * deltaY
  return {pointX, pointY, distance: distanceOf(x - pointX, y - pointY), fraction, segmentLength: Math.sqrt(lengthSquared)}
}

// Two snaps whose distances agree to a micrometer tie, and the tie goes to
// the lesser x, then the lesser y, then the lesser ends of the edge, then the
// lesser start of the segment, so the choice rests on geometry and not on
// the order the pieces arrived in. A snap carries that order as its `key`.
function tieUnits(meters) {
  return Math.round(meters * TIE_UNITS_PER_METER)
}

function snapKey({nearest, edge, startX, startY}) {
  return [tieUnits(nearest.distance), nearest.pointX, nearest.pointY, ...edge.ends, startX, startY]
}

// The nearest point to (x, y) within `snapMetersMax` on the edges of each
// connected component, a Map from a component to `{kind: "snapped", edge,
// x, y, distance, along}`; a component with no edge that near is left out.
export function snapsByComponent({graph, x, y, snapMetersMax}) {
  const snaps = new Map()

  for (const [edgeIndex, edge] of graph.edges.entries()) {
    for (let segment = 0; segment < edge.count - 1; segment += 1) {
      const startOffset = segment * COORDINATE_COUNT
      const endOffset = startOffset + COORDINATE_COUNT
      const nearest = nearestOnSegment({x, y, startX: edge.xy[startOffset], startY: edge.xy[startOffset + 1], endX: edge.xy[endOffset], endY: edge.xy[endOffset + 1]})

      const key = snapKey({nearest, edge, startX: edge.xy[startOffset], startY: edge.xy[startOffset + 1]})
      const held = snaps.get(edge.component)
      const isNearer = held === undefined || compareLists(key, held.key) < 0
      const isNear = nearest.distance <= snapMetersMax
      const isChosen = isNear && isNearer

      if (isChosen) {
        const along = edge.cumulative[segment] + nearest.fraction * nearest.segmentLength
        snaps.set(edge.component, {kind: SnapKind.snapped, edge: edgeIndex, x: nearest.pointX, y: nearest.pointY, distance: nearest.distance, along, key})
      }
    }
  }

  return snaps
}

// The pair of snaps, one for each end, in a component both reach, whose
// distances from the ends sum least: `{kind: "chosen", start, goal}`; or
// `{kind: "none", reason}` with `offGraph` where an end reaches no
// component and `disconnected` where the two reach none in common.
// Sums that agree to a micrometer tie, and the tie goes to the start snap
// nearer its end, then to the lesser start and goal positions, then to the
// lesser ends of the start and goal edges, so the choice rests on geometry
// and not on the order of the components.
function pairKey({start, goal}) {
  return [tieUnits(start.distance + goal.distance), tieUnits(start.distance), start.x, start.y, goal.x, goal.y, ...start.key.slice(KEY_ENDS_FROM, KEY_ENDS_TO), ...goal.key.slice(KEY_ENDS_FROM, KEY_ENDS_TO)]
}

function isBetterPair({candidate, best}) {
  return compareLists(pairKey(candidate), pairKey(best)) < 0
}

export function chooseSnaps({startSnaps, goalSnaps}) {
  let best = {kind: SnapKind.none, reason: NoPathReason.disconnected}

  for (const [component, start] of startSnaps) {
    const goal = goalSnaps.get(component)

    if (goal === undefined) {
      continue
    }

    const candidate = {start, goal}
    const isFirst = best.kind === SnapKind.none
    const isChosen = isFirst || isBetterPair({candidate, best})

    if (isChosen) {
      best = {kind: SnapKind.chosen, start, goal}
    }
  }

  const isAnyOff = startSnaps.size === 0 || goalSnaps.size === 0

  if (isAnyOff) {
    return {kind: SnapKind.none, reason: NoPathReason.offGraph}
  }

  return best
}

// A binary min-heap of node numbers by priority; a node may be pushed more
// than once, and the search skips the stale entries.
export class NodeHeap {
  constructor() {
    this.nodes = []
    this.priorities = []
  }

  get size() {
    return this.nodes.length
  }

  push({node, priority}) {
    let index = this.nodes.length
    this.nodes.push(node)
    this.priorities.push(priority)

    while (index > 0) {
      const parent = Math.floor((index - 1) / HEAP_ARITY)

      if (this.priorities[parent] <= this.priorities[index]) {
        break
      }

      this.swap(parent, index)
      index = parent
    }
  }

  pop() {
    const node = this.nodes[0]
    const lastNode = this.nodes.pop()
    const lastPriority = this.priorities.pop()

    if (this.nodes.length > 0) {
      this.nodes[0] = lastNode
      this.priorities[0] = lastPriority
      this.siftDown()
    }

    return node
  }

  siftDown() {
    let index = 0

    // Each pass moves the entry one level down a tree of finite depth.
    for (;;) {
      const left = index * HEAP_ARITY + 1
      const right = left + 1
      let smallest = index
      const hasLeft = left < this.nodes.length
      const hasRight = right < this.nodes.length
      const isLeftSmaller = hasLeft && this.priorities[left] < this.priorities[smallest]

      if (isLeftSmaller) {
        smallest = left
      }

      const isRightSmaller = hasRight && this.priorities[right] < this.priorities[smallest]

      if (isRightSmaller) {
        smallest = right
      }

      if (smallest === index) {
        return
      }

      this.swap(smallest, index)
      index = smallest
    }
  }

  swap(first, second) {
    const node = this.nodes[first]
    const priority = this.priorities[first]
    this.nodes[first] = this.nodes[second]
    this.priorities[first] = this.priorities[second]
    this.nodes[second] = node
    this.priorities[second] = priority
  }
}

function pointAlong({edge, along}) {
  for (let segment = 0; segment < edge.count - 1; segment += 1) {
    const isInside = along <= edge.cumulative[segment + 1]

    if (isInside) {
      const segmentLength = edge.cumulative[segment + 1] - edge.cumulative[segment]
      let fraction = 0

      if (segmentLength > 0) {
        fraction = (along - edge.cumulative[segment]) / segmentLength
      }

      const startX = edge.xy[segment * COORDINATE_COUNT]
      const startY = edge.xy[segment * COORDINATE_COUNT + 1]
      const endX = edge.xy[(segment + 1) * COORDINATE_COUNT]
      const endY = edge.xy[(segment + 1) * COORDINATE_COUNT + 1]
      return [startX + fraction * (endX - startX), startY + fraction * (endY - startY)]
    }
  }

  const last = edge.count - 1
  return [edge.xy[last * COORDINATE_COUNT], edge.xy[last * COORDINATE_COUNT + 1]]
}

// The points of `edge` from the distance `from` along it to `to`, in the
// order walked, the ends interpolated where they fall inside a segment.
function sliceEdge({edge, from, to}) {
  const low = Math.min(from, to)
  const high = Math.max(from, to)
  const points = [pointAlong({edge, along: low})]

  for (let position = 0; position < edge.count; position += 1) {
    const isAfterLow = edge.cumulative[position] > low
    const isBeforeHigh = edge.cumulative[position] < high
    const isBetween = isAfterLow && isBeforeHigh

    if (isBetween) {
      points.push([edge.xy[position * COORDINATE_COUNT], edge.xy[position * COORDINATE_COUNT + 1]])
    }
  }

  points.push(pointAlong({edge, along: high}))

  if (from > to) {
    points.reverse()
  }

  return points
}

// A* from the start snap to the goal snap, which are virtual nodes numbered
// after the graph's own. Each settled node keeps the node and edge it was
// reached by.
function search({graph, start, goal, visitedNodeCountMax}) {
  const nodeCount = graph.nodeX.length
  const startNode = nodeCount
  const goalNode = nodeCount + 1
  const totalCount = nodeCount + VIRTUAL_NODE_COUNT
  const cost = new Float64Array(totalCount).fill(Infinity)
  const previous = new Int32Array(totalCount).fill(NO_NODE)
  const via = new Int32Array(totalCount).fill(NO_EDGE)
  const isSettled = new Uint8Array(totalCount)
  const heap = new NodeHeap()
  const startEdge = graph.edges[start.edge]
  const goalEdge = graph.edges[goal.edge]

  function heuristic(node) {
    if (node === goalNode) {
      return 0
    }

    if (node === startNode) {
      return distanceOf(start.x - goal.x, start.y - goal.y)
    }

    return distanceOf(graph.nodeX[node] - goal.x, graph.nodeY[node] - goal.y)
  }

  function relax({from, to, meters, edge}) {
    const candidate = cost[from] + meters

    if (candidate < cost[to]) {
      cost[to] = candidate
      previous[to] = from
      via[to] = edge
      heap.push({node: to, priority: candidate + heuristic(to)})
    }
  }

  function expandStart() {
    relax({from: startNode, to: startEdge.a, meters: start.along, edge: start.edge})
    relax({from: startNode, to: startEdge.b, meters: startEdge.length - start.along, edge: start.edge})

    if (start.edge === goal.edge) {
      relax({from: startNode, to: goalNode, meters: Math.abs(goal.along - start.along), edge: start.edge})
    }
  }

  function expandNode(node) {
    for (const edgeIndex of graph.nodeEdges[node]) {
      const edge = graph.edges[edgeIndex]
      let other = edge.a

      if (edge.a === node) {
        other = edge.b
      }

      relax({from: node, to: other, meters: edge.length, edge: edgeIndex})
    }

    if (node === goalEdge.a) {
      relax({from: node, to: goalNode, meters: goal.along, edge: goal.edge})
    }

    if (node === goalEdge.b) {
      relax({from: node, to: goalNode, meters: goalEdge.length - goal.along, edge: goal.edge})
    }
  }

  cost[startNode] = 0
  heap.push({node: startNode, priority: heuristic(startNode)})
  let visitedCount = 0

  // Each pass settles one node or drops a stale entry, and the visited cap
  // ends the loop after `visitedNodeCountMax` settled nodes.
  while (heap.size > 0) {
    const node = heap.pop()

    if (isSettled[node] === 1) {
      continue
    }

    isSettled[node] = 1

    if (node === goalNode) {
      return {kind: SearchKind.reached, previous, via, startNode, goalNode, cost: cost[goalNode]}
    }

    visitedCount += 1

    if (visitedCount > visitedNodeCountMax) {
      return {kind: SearchKind.capped}
    }

    if (node === startNode) {
      expandStart()
    } else {
      expandNode(node)
    }
  }

  return {kind: SearchKind.exhausted}
}

// How far along `edge` the node `node` lies: 0 at its first end, its length
// at its second.
function alongOfNode({edge, node}) {
  if (node === edge.a) {
    return 0
  }

  return edge.length
}

// The plane points of the path the search found, from the start snap to the
// goal snap, along the edges it settled.
function pathPoints({graph, start, goal, reached}) {
  const steps = []

  for (let node = reached.goalNode; node !== reached.startNode; node = reached.previous[node]) {
    steps.push({node, from: reached.previous[node], edge: reached.via[node]})
  }

  steps.reverse()
  const points = [[start.x, start.y]]

  for (const step of steps) {
    const edge = graph.edges[step.edge]
    let fromAlong = start.along
    let toAlong = goal.along

    if (step.from !== reached.startNode) {
      fromAlong = alongOfNode({edge, node: step.from})
    }

    if (step.node !== reached.goalNode) {
      toAlong = alongOfNode({edge, node: step.node})
    }

    for (const point of sliceEdge({edge, from: fromAlong, to: toAlong})) {
      points.push(point)
    }
  }

  points.push([goal.x, goal.y])
  return points
}

function withoutRepeats(points) {
  const kept = []

  for (const point of points) {
    const last = kept[kept.length - 1]
    const isRepeat = last !== undefined && distanceOf(point[0] - last[0], point[1] - last[1]) < DUPLICATE_METERS

    if (!isRepeat) {
      kept.push(point)
    }
  }

  return kept
}

function lengthOf(points) {
  let meters = 0

  for (let index = 1; index < points.length; index += 1) {
    meters += distanceOf(points[index][0] - points[index - 1][0], points[index][1] - points[index - 1][1])
  }

  return meters
}

export function noPath(reason) {
  return {kind: WalkPathKind.noPath, reason}
}

function coordinatesOfPoints({plane, points}) {
  const coordinates = []

  for (const [x, y] of points) {
    coordinates.push(planeToCoordinate({plane, x, y}))
  }

  return coordinates
}

/**
 * The shortest path along the pieces of `shards`, decoded shard tables,
 * from `from` to `to`, each `{lat, lon}` in degrees: `{kind: "found",
 * coordinates, meters}`, the coordinates `[lon, lat]` from `from` to `to`
 * through the point each end snaps to, and the length of the whole line in
 * meters; or `{kind: "noPath", reason}` with a `NoPathReason`: `offGraph`
 * where an end is farther than `limits.snapMetersMax` from every piece,
 * `disconnected` where the graph holds no path between the snapped ends,
 * `capReached` where the search settled `limits.visitedNodeCountMax` nodes
 * or the graph holds more than `limits.edgeCountMax` pieces, or `noShards`
 * where `shards` holds no piece.
 */
export function findWalkPath({from, to, shards, limits}) {
  assertEnd(from, "from")
  assertEnd(to, "to")
  const pieceCount = pieceTotal(shards)

  if (pieceCount === 0) {
    return noPath(NoPathReason.noShards)
  }

  if (pieceCount > limits.edgeCountMax) {
    return noPath(NoPathReason.capReached)
  }

  const plane = planeOf({from, to})
  const graph = buildGraph({shards, plane})
  const [fromX, fromY] = degreesToPlane({plane, lat: from.lat, lon: from.lon})
  const [toX, toY] = degreesToPlane({plane, lat: to.lat, lon: to.lon})
  const startSnaps = snapsByComponent({graph, x: fromX, y: fromY, snapMetersMax: limits.snapMetersMax})
  const goalSnaps = snapsByComponent({graph, x: toX, y: toY, snapMetersMax: limits.snapMetersMax})
  const chosen = chooseSnaps({startSnaps, goalSnaps})

  if (chosen.kind === SnapKind.none) {
    return noPath(chosen.reason)
  }

  const {start, goal} = chosen

  const outcome = search({graph, start, goal, visitedNodeCountMax: limits.visitedNodeCountMax})

  switch (outcome.kind) {
    case SearchKind.capped:
      return noPath(NoPathReason.capReached)
    case SearchKind.exhausted:
      return noPath(NoPathReason.disconnected)
    case SearchKind.reached: {
      const along = pathPoints({graph, start, goal, reached: outcome})
      const points = withoutRepeats([[fromX, fromY], ...along, [toX, toY]])
      const meters = lengthOf(points)
      const costedMeters = outcome.cost + start.distance + goal.distance
      assertCondition(Math.abs(meters - costedMeters) < DRAWN_COST_TOLERANCE_METERS, "walk path: the line drawn is " + meters + " m and the search costed " + costedMeters + " m")
      return {kind: WalkPathKind.found, coordinates: coordinatesOfPoints({plane, points}), meters}
    }
    default:
      return unreachable(outcome.kind, "walk path: a search of unknown kind")
  }
}

/**
 * The answer to the walk from `from` to `to`, each `{lat, lon}` in degrees,
 * over `index`, a Set of the `tileKey` of every tile with a shard, and
 * `loaded`, a Map from a `tileKey` to its decoded shard table: a
 * `WalkPathKind`. `{kind: "notLoaded", tiles}` names the tiles the walk reads
 * that `loaded` does not hold, in tile order; the other answers are those of
 * `findWalkPath`, with `noPath` and `tooFar` for ends past `limits`. Which
 * tiles are asked for depends on the tiles of the ends alone, so the
 * distance between the ends is checked once the tiles are held.
 */
export function planWalk({from, to, index, loaded, limits}) {
  const needed = walkTilesNeeded({from, to, index, limits})

  if (needed.kind === TilesKind.tooFar) {
    return noPath(NoPathReason.tooFar)
  }

  const missing = []
  const shards = []

  for (const tile of needed.tiles) {
    const key = tileKey(tile)

    if (loaded.has(key)) {
      shards.push(loaded.get(key))
    } else {
      missing.push(tile)
    }
  }

  if (missing.length > 0) {
    return {kind: WalkPathKind.notLoaded, tiles: missing}
  }

  const plane = planeOf({from, to})

  if (straightMeters({plane, from, to}) > limits.distanceMetersMax) {
    return noPath(NoPathReason.tooFar)
  }

  return findWalkPath({from, to, shards, limits})
}
