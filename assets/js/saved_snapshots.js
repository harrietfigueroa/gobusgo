// Reads the snapshot tables the page answers for itself from while it is
// offline: for each service date of the saved offline bundle, its stops,
// positions, and names, read from the browser's Cache API alone so the read
// answers with no network. A read is kept for as long as the saved index is
// the same, and is made again once a save writes another.
//
// A file the bundle lacks, or one its reader refuses, leaves that table
// missing, and the page then answers as the bundle allows: a stop with no
// position is refused, and a stop or route with no name keeps its
// identifier.

import {DecodeKind, decodePositions, decodeStops, decodeTrips} from "./routing_snapshot"
import {decodeNames, expandNames} from "./routing_names"
import {IndexKind, OFFLINE_SCHEDULES_CACHE_NAME} from "./offline_bundle"
import {TableKind, snapshotOrder} from "./offline_answers"
import {readSavedIndex} from "./offline_schedules"

const MISSING = Object.freeze({kind: TableKind.missing})

// The read of the bundle saved at `savedAtMs`, while it is the one saved.
let held = null

async function readBuffer({cache, path}) {
  const response = await cache.match(path)

  if (response === undefined) {
    return {kind: TableKind.missing}
  }

  const buffer = await response.arrayBuffer()
  return {kind: TableKind.found, table: buffer}
}

// The table a decoder gives the saved file at `path`, or missing.
async function readTable({cache, path, decode}) {
  const read = await readBuffer({cache, path})

  if (read.kind === TableKind.missing) {
    return read
  }

  const decoded = decode(read.table)

  if (decoded.kind === DecodeKind.refused) {
    console.warn("Saved snapshot file refused", {path, reason: decoded.reason})
    return MISSING
  }

  return {kind: TableKind.found, table: decoded.records}
}

async function readNames({cache, files, stopCount, tripCount}) {
  if (files.names === undefined) {
    return MISSING
  }

  const read = await readBuffer({cache, path: files.names.path})

  if (read.kind === TableKind.missing) {
    return read
  }

  const expanded = await expandNames(read.table)

  if (expanded.kind === DecodeKind.refused) {
    console.warn("Saved names file refused", {path: files.names.path, reason: expanded.reason})
    return MISSING
  }

  const decoded = decodeNames({buffer: expanded.records, stopCount, tripCount})

  if (decoded.kind === DecodeKind.refused) {
    console.warn("Saved names file refused", {path: files.names.path, reason: decoded.reason})
    return MISSING
  }

  return {kind: TableKind.found, table: decoded.records}
}

function indexesOf(stopIds) {
  const indexes = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    indexes.set(stopId, index)
  }

  return indexes
}

// The saved snapshot of the manifest entry `entry`, or missing when its
// stops file is not saved: its stops are what every answer is keyed by.
async function readSnapshot({cache, entry}) {
  const {files} = entry
  const stops = await readTable({cache, path: files.stops.path, decode: decodeStops})

  if (stops.kind === TableKind.missing) {
    return stops
  }

  const positions = await readTable({cache, path: files.positions.path, decode: decodePositions})
  const trips = await readTable({cache, path: files.trips.path, decode: decodeTrips})
  let names = MISSING

  if (trips.kind === TableKind.found) {
    names = await readNames({cache, files, stopCount: stops.table.length, tripCount: trips.table.length})
  }

  const snapshot = {serviceDate: entry.serviceDate, stopIndexes: indexesOf(stops.table), positions, names}
  return {kind: TableKind.found, table: snapshot}
}

async function readBundle(index) {
  const cache = await caches.open(OFFLINE_SCHEDULES_CACHE_NAME)
  const response = await cache.match(index.manifestPath)

  if (response === undefined) {
    return []
  }

  const manifest = await response.json()
  const snapshots = []

  for (const entry of snapshotOrder({manifest, nowMs: Date.now()})) {
    const read = await readSnapshot({cache, entry})

    if (read.kind === TableKind.found) {
      snapshots.push(read.table)
    }
  }

  return snapshots
}

/**
 * The saved snapshots, the service date running when they were read first, each as
 * `offline_answers.js` describes them; none where the browser holds no
 * saved bundle.
 */
export async function savedSnapshots() {
  const read = await readSavedIndex()

  if (read.kind === IndexKind.none) {
    return []
  }

  const {savedAtMs} = read.index
  const isHeld = held !== null && held.savedAtMs === savedAtMs

  if (!isHeld) {
    held = {savedAtMs, snapshots: readBundle(read.index)}
  }

  try {
    return await held.snapshots
  } catch (error) {
    // A failed read is not kept, so the next answer reads the bundle again.
    held = null
    throw error
  }
}
