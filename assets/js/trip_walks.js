// Plans the walks at the ends of a trip that a position or a point sets:
// where the snapshot plans its walks along the streets, the stops a walk from
// the rider's position or to the destination reaches over the walk graph,
// and where that is unavailable, the straight line the snapshot's radius
// gives, with the reason. The tiles are fetched from the
// shared tile store within a deadline, in one round, so a plan never waits on
// the graph past it. A position is an argument of the pure reach and never of
// a request: the requests name the tiles around the position's tile.

import {assertCondition, unreachable} from "./core/assert.js"
import {isStreetWalk, streetMetersMaxOf, walkBasisOf, walkCandidatesNear} from "./core/routing_walk.js"
import {ReachKind, walkReach, walkReachLimits} from "./core/walk_reach.js"
import {WindowKind} from "./walk_tiles.js"

/**
 * How long the tiles around a position are waited for, in milliseconds: a
 * walk waits at most this for the graph, and is a straight line after it.
 */
export const WALK_TILES_DEADLINE_MS = 5000

/** The kinds of an end of a trip: a position the walk starts or ends at, or a stop, which has no walk to plan. */
export const PlaceKind = Object.freeze({position: "position", absent: "absent"})

/** The kinds of how an end's walk is planned. */
export const EndWalkKind = Object.freeze({
  // The end has no walk to plan, or the snapshot plans its walks as straight lines.
  straight: "straight",
  // The walk is planned along the streets, `stops` the `{stop, streetM}` reached.
  streets: "streets",
  // The walk is a straight line where the streets were planned for, `reason` why.
  fallback: "fallback"
})

/** Why a walk planned for the streets is a straight line. */
export const FallbackReason = Object.freeze({
  tiles: "tiles",
  stopsNotRead: "stopsNotRead",
  offGraph: "offGraph",
  noneInReach: "noneInReach",
  capReached: "capReached"
})

/** The kinds of what the snapshot's stops read gives. */
export const StopsKind = Object.freeze({read: "read", skipped: "skipped"})

const STRAIGHT = Object.freeze({kind: EndWalkKind.straight})
const NO_WINDOW = Object.freeze({kind: PlaceKind.absent})

function streetsOf(stops) {
  return {kind: EndWalkKind.streets, stops}
}

function fallbackOf(reason) {
  return {kind: EndWalkKind.fallback, reason}
}

// The reason a reach that found no stop leaves the walk straight.
function reasonOf(reach) {
  switch (reach.kind) {
    case ReachKind.offGraph:
      return FallbackReason.offGraph
    case ReachKind.noneInReach:
      return FallbackReason.noneInReach
    case ReachKind.capReached:
      return FallbackReason.capReached
    case ReachKind.found:
    case ReachKind.notLoaded:
      return unreachable(reach.kind, "trip walks: a reach with nothing to fall back from")
    default:
      return unreachable(reach.kind, "trip walks: a reach of unknown kind")
  }
}

// The walk of the end at `position`, from the tiles around it, `window`, and
// the snapshot's positions file: the stops reached along the streets, or the
// straight line with the reason.
function streetWalkOf({position, window, positions, transferRules}) {
  if (window.kind === WindowKind.failed) {
    return fallbackOf(FallbackReason.tiles)
  }

  const targets = walkCandidatesNear({position, positions, transferRules})

  if (targets.length === 0) {
    return streetsOf([])
  }

  const limits = walkReachLimits(streetMetersMaxOf(transferRules))
  const reach = walkReach({position, targets, index: window.index, loaded: window.loaded, limits})
  assertCondition(reach.kind !== ReachKind.notLoaded, "trip walks: tiles are missing after the one round that fetched them")

  if (reach.kind === ReachKind.found) {
    return streetsOf(reach.stops)
  }

  return fallbackOf(reasonOf(reach))
}

async function windowAround({walkTiles, place}) {
  if (place.kind === PlaceKind.absent) {
    return NO_WINDOW
  }

  return await walkTiles.fetchWindow({position: place.position, deadlineMs: WALK_TILES_DEADLINE_MS})
}

function walkOf({place, window, stops, transferRules}) {
  if (place.kind === PlaceKind.absent) {
    return STRAIGHT
  }

  if (stops.kind !== StopsKind.read) {
    return fallbackOf(FallbackReason.stopsNotRead)
  }

  return streetWalkOf({position: place.position, window, positions: stops.positions, transferRules})
}

function fulfilled(settled, name) {
  assertCondition(settled.status === "fulfilled", "trip walks: the " + name + " rejected")
  return settled.value
}

/**
 * The walks of the two ends of a trip under `entry`, a manifest entry:
 * `{stops, start, destination}`, each walk an EndWalkKind member, where
 * `start` and `destination` are each `{kind: PlaceKind.position, position}`,
 * `{lat, lon}` in degrees, or `{kind: PlaceKind.absent}`. `readStops()`
 * hands back the snapshot's `{kind: StopsKind.read, stopIds, positions}` or
 * a failure, and is read where the snapshot plans along the streets or a
 * destination is a point, concurrently with the tiles around each position,
 * so the graph and the routing tables come in one wait; `stops` is that
 * answer, or `{kind: StopsKind.skipped}` where it was not read.
 */
export async function planWalks({walkTiles, entry, readStops, start, destination}) {
  const {transferRules} = entry
  const isStreets = isStreetWalk(walkBasisOf(transferRules))
  const isDestinationPoint = destination.kind === PlaceKind.position
  const isStopsNeeded = isStreets || isDestinationPoint
  const skipped = {kind: StopsKind.skipped}

  if (!isStopsNeeded) {
    return {stops: skipped, start: STRAIGHT, destination: STRAIGHT}
  }

  const startWindow = windowAroundIf({isStreets, walkTiles, place: start})
  const destinationWindow = windowAroundIf({isStreets, walkTiles, place: destination})
  const stopsPending = readStops()
  const [startSettled, destinationSettled, stopsSettled] = await Promise.allSettled([startWindow, destinationWindow, stopsPending])
  const stops = fulfilled(stopsSettled, "stops read")

  if (!isStreets) {
    return {stops, start: STRAIGHT, destination: STRAIGHT}
  }

  const startWalk = walkOf({place: start, window: fulfilled(startSettled, "start's tiles"), stops, transferRules})
  const destinationWalk = walkOf({place: destination, window: fulfilled(destinationSettled, "destination's tiles"), stops, transferRules})
  return {stops, start: startWalk, destination: destinationWalk}
}

async function windowAroundIf({isStreets, walkTiles, place}) {
  if (!isStreets) {
    return NO_WINDOW
  }

  return await windowAround({walkTiles, place})
}
