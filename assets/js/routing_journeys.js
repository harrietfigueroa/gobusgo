// Routes a journey from the files of one routing snapshot, fetched through a
// function the caller hands in, so the same code reads the network, the
// offline store, or files held in memory. The rider's position never reaches
// that function: a start from a position is decided here, from the
// snapshot's positions file.
//
// A query loads the stops, trips, transfers, and positions files, then the
// connection chunks from the hour of its departure onward, one at a time,
// routing after each. It stops before the first chunk that departs after the
// cutoff, the earliest arrival found plus WINDOW_SECONDS, and keeps the
// frontier journeys that arrive by the cutoff. The scan reads connections
// from the departure onward and stops at the best arrival, so every journey
// that arrives by the cutoff uses only connections that depart before it,
// which the loaded chunks hold: the answer is the whole snapshot's frontier
// cut at the cutoff.
//
// A departure belongs to the latest snapshot whose service day has started
// by then. That snapshot holds its own date's trips and the trips of the
// date before that run past its start, so every trip running at the
// departure is in it; a journey that needs a trip of the next service date
// is found once that date has started.

import {assertCondition, unreachable} from "./assert.js"
import {LegKind, OriginKind, createEngine, route} from "./routing_engine.js"
import {DecodeKind, FORMAT_VERSION, decodeConnections, decodePositions, decodeStops, decodeTransfers, decodeTrips} from "./routing_snapshot.js"
import {startsNear} from "./routing_walk.js"

/** How long past the earliest arrival a journey with fewer changes is still shown. */
export const WINDOW_SECONDS = 45 * 60

const FETCH_TIMEOUT_MS = 20 * 1000
const CHUNK_COUNT_MAX = 48
const SECOND_MS = 1000
const CONNECTION_COLUMNS = Object.freeze({
  departureS: Int32Array,
  arrivalS: Int32Array,
  departureStop: Uint32Array,
  arrivalStop: Uint32Array,
  trip: Uint32Array,
  sequence: Uint16Array,
  boarding: Uint8Array,
  alighting: Uint8Array,
})

/** The kinds of a query's start: a stop by identifier, or a position in degrees. */
export const FromKind = Object.freeze({stop: "stop", position: "position"})

/** The kinds of what a file fetch hands back. */
export const FetchKind = Object.freeze({fetched: "fetched", failed: "failed"})

/** The kinds of the service date a departure belongs to. */
export const ServiceDateKind = Object.freeze({found: "found", none: "none"})

/** The kinds of a journey query's outcome. */
export const JourneysKind = Object.freeze({
  found: "found",
  none: "none",
  unknownStop: "unknownStop",
  noStartStop: "noStartStop",
  failed: "failed",
})

/** Why a journey query failed. */
export const FailureReason = Object.freeze({
  unsupportedVersion: "unsupportedVersion",
  unknownServiceDate: "unknownServiceDate",
  tooManyChunks: "tooManyChunks",
  fetchFailed: "fetchFailed",
  timedOut: "timedOut",
  sizeMismatch: "sizeMismatch",
  refused: "refused",
  positionsMismatch: "positionsMismatch",
})

function failed({reason, path}) {
  return {kind: JourneysKind.failed, reason, path}
}

function lastDepartureS(entry) {
  let lastS = 0

  for (const chunk of entry.connectionChunks) {
    lastS = Math.max(lastS, chunk.departureSMax)
  }

  return lastS
}

/**
 * The service date of `manifest` that a departure at `departureMs`, in
 * milliseconds since the Unix epoch, is routed in, and the departure in
 * seconds from that date's start: the latest snapshot whose day has started
 * by then, while a connection departs at or after it.
 */
export function serviceDateAt({manifest, departureMs}) {
  let chosen = {kind: ServiceDateKind.none}

  for (const entry of manifest.snapshots) {
    const isStarted = entry.serviceDayStartMs <= departureMs
    const isLaterStart = chosen.kind === ServiceDateKind.none || entry.serviceDayStartMs > chosen.entry.serviceDayStartMs
    const isLaterStarted = isStarted && isLaterStart

    if (isLaterStarted) {
      chosen = {kind: ServiceDateKind.found, entry}
    }
  }

  if (chosen.kind === ServiceDateKind.none) {
    return chosen
  }

  const departureS = Math.floor((departureMs - chosen.entry.serviceDayStartMs) / SECOND_MS)

  if (departureS > lastDepartureS(chosen.entry)) {
    return {kind: ServiceDateKind.none}
  }

  return {kind: ServiceDateKind.found, serviceDate: chosen.entry.serviceDate, departureS}
}

// Resolves on the outcome a timed-out fetch gets once `signal` aborts.
function timeoutOf(signal) {
  return new Promise(function awaitTimeout(resolve) {
    function resolveTimedOut() {
      resolve({kind: FetchKind.failed, reason: FailureReason.timedOut})
    }

    signal.addEventListener("abort", resolveTimedOut, {once: true})
  })
}

async function fetchSettled({fetchFile, path, signal}) {
  try {
    const outcome = await fetchFile({path, signal})
    const isFetched = outcome.kind === FetchKind.fetched
    const isFailed = outcome.kind === FetchKind.failed
    const isKnown = isFetched || isFailed
    assertCondition(isKnown, "routing journeys: a fetch handed back an outcome of unknown kind " + outcome.kind)
    return outcome
  } catch (error) {
    return {kind: FetchKind.failed, reason: FailureReason.fetchFailed, error}
  }
}

// The content of one file the manifest names, fetched within
// FETCH_TIMEOUT_MS and of the size the manifest gives it.
async function fetchChecked({fetchFile, file}) {
  const signal = AbortSignal.timeout(FETCH_TIMEOUT_MS)
  const pending = fetchSettled({fetchFile, path: file.path, signal})
  const expiry = timeoutOf(signal)
  const outcome = await Promise.race([pending, expiry])

  if (outcome.kind === FetchKind.failed) {
    return failed({reason: outcome.reason, path: file.path})
  }

  if (outcome.buffer.byteLength !== file.byteSize) {
    return failed({reason: FailureReason.sizeMismatch, path: file.path})
  }

  return outcome
}

function decodedOrFailed({fetched, decode, path}) {
  const result = decode(fetched.buffer)

  if (result.kind === DecodeKind.refused) {
    return failed({reason: FailureReason.refused, path})
  }

  return {kind: DecodeKind.decoded, records: result.records, byteCount: fetched.buffer.byteLength}
}

const TABLE_DECODERS = Object.freeze({stops: decodeStops, trips: decodeTrips, transfers: decodeTransfers, positions: decodePositions})

// The four tables of `entry`, fetched together and decoded.
async function loadTables({entry, fetchFile}) {
  const names = Object.keys(TABLE_DECODERS)
  const files = Array.from(names, function fileOf(name) {
    return entry.files[name]
  })
  const pending = Array.from(files, function fetchTable(file) {
    return fetchChecked({fetchFile, file})
  })
  const settled = await Promise.allSettled(pending)
  const tables = {byteCount: 0}

  for (const [index, name] of names.entries()) {
    const result = settled[index]
    assertCondition(result.status === "fulfilled", "routing journeys: a checked fetch rejected: " + result.reason)

    if (result.value.kind === JourneysKind.failed) {
      return result.value
    }

    const table = decodedOrFailed({fetched: result.value, decode: TABLE_DECODERS[name], path: files[index].path})

    if (table.kind === JourneysKind.failed) {
      return table
    }

    tables[name] = table.records
    tables.byteCount += table.byteCount
  }

  if (tables.positions.latMicrodegrees.length !== tables.stops.length) {
    return failed({reason: FailureReason.positionsMismatch, path: entry.files.positions.path})
  }

  return {kind: DecodeKind.decoded, tables}
}

// The decoded chunks' columns joined into one set, in chunk order.
function joinChunks(chunks) {
  let count = 0

  for (const columns of chunks) {
    count += columns.departureS.length
  }

  const joined = {}

  for (const [name, Column] of Object.entries(CONNECTION_COLUMNS)) {
    const column = new Column(count)
    let offset = 0

    for (const columns of chunks) {
      column.set(columns[name], offset)
      offset += columns[name].length
    }

    joined[name] = column
  }

  return joined
}

function decodedRecords({result, name}) {
  assertCondition(result.kind === DecodeKind.decoded, "routing journeys: the " + name + " file was refused: " + result.reason)
  return result.records
}

function decodeChunk(chunk) {
  const result = decodeConnections(chunk)
  return decodedRecords({result, name: "connections"})
}

/**
 * The engine over `files`, every file of a snapshot already in hand: a
 * stops file, a transfers file, and every connection chunk in departure
 * order, each an ArrayBuffer the format admits. Its `route` takes the
 * engine's query.
 */
export function loadEngine({files, minimumTransferS}) {
  const stopsResult = decodeStops(files.stops)
  const stopIds = decodedRecords({result: stopsResult, name: "stops"})
  const transfersResult = decodeTransfers(files.transfers)
  const transfers = decodedRecords({result: transfersResult, name: "transfers"})
  const chunks = Array.from(files.connectionChunks, decodeChunk)
  const connections = joinChunks(chunks)
  const engine = createEngine({stopCount: stopIds.length, connections, transfers, minimumTransferS})

  function routeQuery(query) {
    return route(engine, query)
  }

  return {route: routeQuery}
}

function stopIndexOf(stopIds) {
  const index = new Map()

  for (const [stop, stopId] of stopIds.entries()) {
    index.set(stopId, stop)
  }

  return index
}

// The engine's origin for `from`, or why there is none.
function originOf({from, stopIndex, tables, entry}) {
  switch (from.kind) {
    case FromKind.stop: {
      const stop = stopIndex.get(from.stopId)

      if (stop === undefined) {
        return {kind: JourneysKind.unknownStop, stopId: from.stopId}
      }

      return {kind: OriginKind.stop, stop}
    }
    case FromKind.position: {
      const position = {lat: from.lat, lon: from.lon}
      const starts = startsNear({position, positions: tables.positions, transferRules: entry.transferRules})

      if (starts.length === 0) {
        return {kind: JourneysKind.noStartStop}
      }

      return {kind: OriginKind.starts, starts}
    }
    default:
      return unreachable(from.kind, "routing journeys: a start of unknown kind")
  }
}

function firstChunkIndex({chunks, departureS}) {
  for (const [index, chunk] of chunks.entries()) {
    if (chunk.departureSMax >= departureS) {
      return index
    }
  }

  return chunks.length
}

function earliestArrivalS(frontier) {
  const earliest = frontier[frontier.length - 1]
  return earliest.arrivalS
}

// The frontier over the chunks loaded so far.
function routeLoaded({tables, chunks, minimumTransferS, query}) {
  const connections = joinChunks(chunks)
  const engine = createEngine({stopCount: tables.stops.length, connections, transfers: tables.transfers, minimumTransferS})
  const frontier = route(engine, query)
  return {frontier, connections}
}

// Loads chunks from the departure onward until the next one departs after
// the cutoff, routing after each.
async function scanByWindow({entry, tables, query, fetchFile}) {
  const chunks = entry.connectionChunks
  const transferSMin = entry.transferRules.minimumTransferS
  const loaded = []
  let byteCount = 0
  let scan = routeLoaded({tables, chunks: loaded, minimumTransferS: transferSMin, query})

  for (let index = firstChunkIndex({chunks, departureS: query.departureS}); index < chunks.length; index++) {
    const isReached = scan.frontier.length > 0

    if (isReached) {
      const cutoffS = earliestArrivalS(scan.frontier) + WINDOW_SECONDS

      if (chunks[index].departureSMin > cutoffS) {
        break
      }
    }

    const fetched = await fetchChecked({fetchFile, file: chunks[index]})

    if (fetched.kind === JourneysKind.failed) {
      return fetched
    }

    const chunk = decodedOrFailed({fetched, decode: decodeConnections, path: chunks[index].path})

    if (chunk.kind === JourneysKind.failed) {
      return chunk
    }

    loaded.push(chunk.records)
    byteCount += chunk.byteCount
    scan = routeLoaded({tables, chunks: loaded, minimumTransferS: transferSMin, query})
  }

  return {kind: DecodeKind.decoded, scan, chunkCount: loaded.length, byteCount}
}

function journeyLeg({leg, connections, tables}) {
  switch (leg.kind) {
    case LegKind.ride: {
      const trip = tables.trips[connections.trip[leg.boardConnection]]

      return {
        kind: LegKind.ride,
        tripId: trip.id,
        routeId: trip.routeId,
        serviceDayOffset: trip.serviceDayOffset,
        fromStopId: tables.stops[connections.departureStop[leg.boardConnection]],
        departureS: connections.departureS[leg.boardConnection],
        toStopId: tables.stops[connections.arrivalStop[leg.alightConnection]],
        arrivalS: connections.arrivalS[leg.alightConnection],
      }
    }
    case LegKind.walk:
      return {kind: LegKind.walk, fromStopId: tables.stops[leg.fromStop], toStopId: tables.stops[leg.toStop], durationS: leg.durationS}
    case LegKind.walkFromPosition:
      return {kind: LegKind.walkFromPosition, toStopId: tables.stops[leg.toStop], durationS: leg.durationS}
    default:
      return unreachable(leg.kind, "routing journeys: a leg of unknown kind")
  }
}

// The frontier journeys arriving by the cutoff, as identifiers, the
// earliest marked.
function journeysOf({scan, tables}) {
  const {frontier, connections} = scan
  const earliestS = earliestArrivalS(frontier)
  const cutoffS = earliestS + WINDOW_SECONDS
  const journeys = []

  for (const journey of frontier) {
    if (journey.arrivalS <= cutoffS) {
      const legs = []

      for (const leg of journey.legs) {
        const converted = journeyLeg({leg, connections, tables})
        legs.push(converted)
      }

      journeys.push({arrivalS: journey.arrivalS, changes: journey.changes, isEarliest: journey.arrivalS === earliestS, legs})
    }
  }

  return journeys
}

/**
 * The journeys of `serviceDate` in `manifest` from `from` to the stop
 * `toStopId`, leaving at or after `departureS`, seconds from that date's
 * start. `from` is `{kind: FromKind.stop, stopId}` or
 * `{kind: FromKind.position, lat, lon}` in degrees. `fetchFile({path,
 * signal})` hands back `{kind: FetchKind.fetched, buffer}` with an
 * ArrayBuffer, or `{kind: FetchKind.failed, reason}`, and sees nothing but
 * paths the manifest names.
 *
 * Found journeys arrive by the earliest arrival plus WINDOW_SECONDS, fewest
 * changes first, each with its arrival, its changes, whether it is the
 * earliest, and its legs by identifier; `loaded` counts the chunks and the
 * bytes fetched.
 */
export async function routeJourneys({manifest, serviceDate, departureS, from, toStopId, fetchFile}) {
  if (manifest.formatVersion !== FORMAT_VERSION) {
    return failed({reason: FailureReason.unsupportedVersion, path: ""})
  }

  const entry = manifest.snapshots.find(function isServiceDate(candidate) {
    return candidate.serviceDate === serviceDate
  })

  if (entry === undefined) {
    return failed({reason: FailureReason.unknownServiceDate, path: ""})
  }

  if (entry.connectionChunks.length > CHUNK_COUNT_MAX) {
    return failed({reason: FailureReason.tooManyChunks, path: ""})
  }

  const loadedTables = await loadTables({entry, fetchFile})

  if (loadedTables.kind === JourneysKind.failed) {
    return loadedTables
  }

  const {tables} = loadedTables
  const stopIndex = stopIndexOf(tables.stops)
  const target = stopIndex.get(toStopId)

  if (target === undefined) {
    return {kind: JourneysKind.unknownStop, stopId: toStopId}
  }

  const origin = originOf({from, stopIndex, tables, entry})
  const isOrigin = origin.kind === OriginKind.stop || origin.kind === OriginKind.starts

  if (!isOrigin) {
    return origin
  }

  const query = {origin, target, departureS}
  const scanned = await scanByWindow({entry, tables, query, fetchFile})

  if (scanned.kind === JourneysKind.failed) {
    return scanned
  }

  const loaded = {chunkCount: scanned.chunkCount, byteCount: tables.byteCount + scanned.byteCount}

  if (scanned.scan.frontier.length === 0) {
    return {kind: JourneysKind.none, loaded}
  }

  const journeys = journeysOf({scan: scanned.scan, tables})
  return {kind: JourneysKind.found, journeys, loaded}
}
