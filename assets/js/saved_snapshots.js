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

import {DecodeKind, decodeConnections, decodePositions, decodeStops, decodeTrips} from "./core/routing_snapshot"
import {decodeNames} from "./core/routing_names"
import {expandNames} from "./names_stream.js"
import {IndexKind, OFFLINE_SCHEDULES_CACHE_NAME} from "./core/offline_bundle"
import {TableKind, snapshotOrder} from "./core/offline_answers"
import {readSavedIndex} from "./offline_schedules"

const MISSING = Object.freeze({kind: TableKind.missing})

// Two saved dates' worth of the chunks a page reads at one time.
const CHUNK_HELD_COUNT_MAX = 8

// The read of the bundle saved at `savedAtMs`, while it is the one saved.
let held = null

// The decoded connection chunks by path, the most recently read last. A
// chunk's path names its content, so a held chunk never goes stale.
const heldChunks = new Map()

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

  const snapshot = {
    serviceDate: entry.serviceDate,
    serviceDayStartMs: entry.serviceDayStartMs,
    connectionChunks: entry.connectionChunks,
    stopIndexes: indexesOf(stops.table),
    trips,
    positions,
    names
  }

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
 * The saved snapshots, the service date running when they were read first,
 * each `{serviceDate, serviceDayStartMs, connectionChunks, stopIndexes,
 * trips, positions, names}` with each table found or missing; none where
 * the browser holds no saved bundle.
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

async function readChunk(path) {
  const cache = await caches.open(OFFLINE_SCHEDULES_CACHE_NAME)
  return await readTable({cache, path, decode: decodeConnections})
}

/**
 * The decoded connections of the saved chunk at `path`, or missing where the
 * bundle lacks it or its reader refuses it. At most CHUNK_HELD_COUNT_MAX
 * chunks are held, the least recently read let go first.
 */
export async function savedConnections(path) {
  let read = heldChunks.get(path)

  if (read === undefined) {
    read = readChunk(path)
  }

  // Taken out and set again, the chunk becomes the most recently read.
  heldChunks.delete(path)
  heldChunks.set(path, read)

  for (const heldPath of heldChunks.keys()) {
    if (heldChunks.size <= CHUNK_HELD_COUNT_MAX) {
      break
    }

    heldChunks.delete(heldPath)
  }

  try {
    return await read
  } catch (error) {
    // A failed read is not kept, so the next tick reads the chunk again.
    heldChunks.delete(path)
    throw error
  }
}
