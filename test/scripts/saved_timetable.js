// The saved snapshot of a hand-written fixture timetable as the page reads it
// from the offline bundle: the fixture's snapshot files, decoded by the
// page's own readers. Everything here is pure.

import {deepStrictEqual} from "node:assert/strict"
import {TableKind} from "../../assets/js/core/offline_answers.js"
import {DecodeKind, decodeConnections, decodePositions, decodeTrips} from "../../assets/js/core/routing_snapshot.js"
import {snapshotOf} from "./routing_timetable.js"

/** A table the bundle holds. */
export function found(table) {
  return {kind: TableKind.found, table}
}

function decoded(result) {
  deepStrictEqual(result.kind, DecodeKind.decoded, "a fixture file decodes")
  return result.records
}

function indexesOf(stopIds) {
  const indexes = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    indexes.set(stopId, index)
  }

  return indexes
}

function decodeChunk(buffer) {
  return decoded(decodeConnections(buffer))
}

/**
 * The saved snapshot of `fixture` with `names`, a names table or missing,
 * and every connection chunk decoded.
 */
export function savedOf({fixture, names}) {
  const snapshot = snapshotOf(fixture)
  const {entry, filesByPath, stopIds} = snapshot
  const tripsBuffer = filesByPath.get(entry.files.trips.path)
  const positionsBuffer = filesByPath.get(entry.files.positions.path)
  const trips = decoded(decodeTrips(tripsBuffer))
  const positions = decoded(decodePositions(positionsBuffer))

  return {
    serviceDate: entry.serviceDate,
    serviceDayStartMs: entry.serviceDayStartMs,
    connectionChunks: entry.connectionChunks,
    stopIndexes: indexesOf(stopIds),
    trips: found(trips),
    positions: found(positions),
    names,
    connections: Array.from(snapshot.files.connectionChunks, decodeChunk)
  }
}
