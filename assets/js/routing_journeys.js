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
// departure is in it. Where it has no journey, or its earliest arrives
// after its last connection departs, the query goes on into the next
// date's snapshot, whose trips that one lacks, with the departure moved
// into that date's seconds. The two frontiers meet on one timeline, and the
// window counts from the earliest arrival of either.

import {assertCondition, unreachable} from "./assert.js"
import {LegKind, OriginKind, createEngine, route} from "./routing_engine.js"
import {DecodeKind, FORMAT_VERSION, POSITION_UNKNOWN_MICRODEGREES, decodeConnections, decodePositions, decodeStops, decodeTransfers, decodeTrips} from "./routing_snapshot.js"
import {startsNear} from "./routing_walk.js"

/** How long past the earliest arrival a journey with fewer changes is still shown. */
export const WINDOW_SECONDS = 45 * 60

const FETCH_TIMEOUT_MS = 20 * 1000
const CHUNK_COUNT_MAX = 48
const SECOND_MS = 1000
const MICRODEGREES_PER_DEGREE = 1000000
// A sequence below every hop's, which a trip's first hop, at 0, follows.
const SEQUENCE_BEFORE_FIRST = -1
const NO_ARRIVAL_S = Number.POSITIVE_INFINITY
const RoutedKind = Object.freeze({routed: "routed"})
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

// The earliest arrival the window counts from: this scan's own, or `boundS`
// where that is earlier.
function windowStartS({frontier, boundS}) {
  if (frontier.length === 0) {
    return boundS
  }

  return Math.min(earliestArrivalS(frontier), boundS)
}

// Loads chunks from the departure onward until the next one departs after
// the cutoff, routing after each.
async function scanByWindow({entry, tables, query, fetchFile, boundS}) {
  const chunks = entry.connectionChunks
  const transferSMin = entry.transferRules.minimumTransferS
  const loaded = []
  let byteCount = 0
  let scan = routeLoaded({tables, chunks: loaded, minimumTransferS: transferSMin, query})

  for (let index = firstChunkIndex({chunks, departureS: query.departureS}); index < chunks.length; index++) {
    const startS = windowStartS({frontier: scan.frontier, boundS})
    const isReached = startS < NO_ARRIVAL_S

    if (isReached) {
      const cutoffS = startS + WINDOW_SECONDS

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

// The stops a ride passes, by index, from the one it boards at to the one
// it leaves at. The connections are in departure order, and a trip's
// connections depart in its stops' order, so the ride's are the trip's
// connections from its boarding connection to its alighting one.
function rideStops({leg, connections}) {
  const trip = connections.trip[leg.boardConnection]
  const stops = [connections.departureStop[leg.boardConnection]]
  let sequence = SEQUENCE_BEFORE_FIRST

  for (let index = leg.boardConnection; index <= leg.alightConnection; index++) {
    if (connections.trip[index] === trip) {
      assertCondition(connections.sequence[index] > sequence, "routing journeys: a ride's connections are out of sequence at " + index)
      sequence = connections.sequence[index]
      stops.push(connections.arrivalStop[index])
    }
  }

  return stops
}

function journeyLeg({leg, connections, tables}) {
  switch (leg.kind) {
    case LegKind.ride: {
      const trip = tables.trips[connections.trip[leg.boardConnection]]
      const stops = rideStops({leg, connections})
      const stopIds = Array.from(stops, function stopIdOf(stop) {
        return tables.stops[stop]
      })

      return {
        stopIds,
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

// The identifiers of every stop `legs` name, a ride's passed stops among them.
function legStopIds(legs) {
  const stopIds = new Set()

  for (const leg of legs) {
    if (leg.kind === LegKind.ride) {
      for (const stopId of leg.stopIds) {
        stopIds.add(stopId)
      }
    } else if (leg.kind === LegKind.walk) {
      stopIds.add(leg.fromStopId)
      stopIds.add(leg.toStopId)
    } else {
      stopIds.add(leg.toStopId)
    }
  }

  return stopIds
}

// The position in degrees of each stop of `stopIds` whose position the
// snapshot knows, by identifier.
function stopPositionsOf({stopIds, stopIndex, tables}) {
  const positions = {}

  for (const stopId of stopIds) {
    const stop = stopIndex.get(stopId)
    const latMicrodegrees = tables.positions.latMicrodegrees[stop]

    if (latMicrodegrees !== POSITION_UNKNOWN_MICRODEGREES) {
      const lat = latMicrodegrees / MICRODEGREES_PER_DEGREE
      const lon = tables.positions.lonMicrodegrees[stop] / MICRODEGREES_PER_DEGREE
      positions[stopId] = {lat, lon}
    }
  }

  return positions
}

// Every frontier journey of one snapshot, as identifiers, with the service
// date its times count from and the positions of the stops it names.
function candidatesOf({scan, tables, stopIndex, serviceDate}) {
  const {frontier, connections} = scan
  const candidates = []

  for (const journey of frontier) {
    const legs = []

    for (const leg of journey.legs) {
      const converted = journeyLeg({leg, connections, tables})
      legs.push(converted)
    }

    const stopPositions = stopPositionsOf({stopIds: legStopIds(legs), stopIndex, tables})
    candidates.push({serviceDate, arrivalS: journey.arrivalS, changes: journey.changes, legs, stopPositions})
  }

  return candidates
}

// Routes in one snapshot: its tables, the origin and target resolved in its
// stop numbering, and its chunks by window. `boundS`, in this snapshot's
// seconds, is an arrival already found elsewhere, which the window counts
// from where it is earlier than this snapshot's own.
async function routeSnapshot({entry, departureS, from, toStopId, fetchFile, boundS}) {
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
  const scanned = await scanByWindow({entry, tables, query, fetchFile, boundS})

  if (scanned.kind === JourneysKind.failed) {
    return scanned
  }

  const candidates = candidatesOf({scan: scanned.scan, tables, stopIndex, serviceDate: entry.serviceDate})
  const loaded = {chunkCount: scanned.chunkCount, byteCount: tables.byteCount + scanned.byteCount}
  return {kind: RoutedKind.routed, candidates, loaded}
}

function earliestCandidateS(candidates) {
  let earliestS = NO_ARRIVAL_S

  for (const candidate of candidates) {
    earliestS = Math.min(earliestS, candidate.arrivalS)
  }

  return earliestS
}

// Whether a query routed in `entry` goes on into the next service date: it
// found no journey, or its earliest arrives after the date's last connection
// departs, by which time every chunk of the date is loaded.
function isContinuing({routed, entry}) {
  const earliestS = earliestCandidateS(routed.candidates)
  return earliestS > lastDepartureS(entry)
}

// The snapshot whose day starts next after `entry`'s.
function nextEntryOf({manifest, entry}) {
  let next = {kind: ServiceDateKind.none}

  for (const candidate of manifest.snapshots) {
    const isLater = candidate.serviceDayStartMs > entry.serviceDayStartMs
    const isSooner = next.kind === ServiceDateKind.none || candidate.serviceDayStartMs < next.entry.serviceDayStartMs
    const isNext = isLater && isSooner

    if (isNext) {
      next = {kind: ServiceDateKind.found, entry: candidate}
    }
  }

  return next
}

function byChangesThenArrival(left, right) {
  if (left.changes !== right.changes) {
    return left.changes - right.changes
  }

  if (left.absoluteS !== right.absoluteS) {
    return left.absoluteS - right.absoluteS
  }

  return left.partIndex - right.partIndex
}

// The answer from the candidates of one or two snapshots, each part with
// the seconds its day starts after the first's: their frontier on one
// timeline, cut at the earliest arrival plus the window, the earliest marked.
function answerOf(parts) {
  const timed = []
  const loaded = {chunkCount: 0, byteCount: 0}

  for (const [partIndex, part] of parts.entries()) {
    loaded.chunkCount += part.routed.loaded.chunkCount
    loaded.byteCount += part.routed.loaded.byteCount

    for (const candidate of part.routed.candidates) {
      timed.push({candidate, absoluteS: candidate.arrivalS + part.shiftS, changes: candidate.changes, partIndex})
    }
  }

  timed.sort(byChangesThenArrival)
  const kept = []
  let bestS = NO_ARRIVAL_S

  for (const entry of timed) {
    if (entry.absoluteS < bestS) {
      bestS = entry.absoluteS
      kept.push(entry)
    }
  }

  if (kept.length === 0) {
    return {kind: JourneysKind.none, loaded}
  }

  const cutoffS = bestS + WINDOW_SECONDS
  const journeys = []

  for (const entry of kept) {
    if (entry.absoluteS <= cutoffS) {
      journeys.push({...entry.candidate, isEarliest: entry.absoluteS === bestS})
    }
  }

  return {kind: JourneysKind.found, journeys, loaded}
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
 * changes first, each with the service date its times count from, its
 * arrival, its changes, whether it is the earliest, its legs by
 * identifier, a ride's with every stop it passes in `stopIds`, and in
 * `stopPositions` the position in degrees of each stop it names whose
 * position the snapshot knows; `loaded` counts the chunks and the bytes
 * fetched.
 *
 * Where `serviceDate` has no journey, or its earliest arrives after the
 * date's last connection departs, the query goes on into the snapshot whose
 * day starts next, once and no further, and its journeys carry that date.
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

  const first = await routeSnapshot({entry, departureS, from, toStopId, fetchFile, boundS: NO_ARRIVAL_S})

  if (first.kind !== RoutedKind.routed) {
    return first
  }

  const firstPart = {routed: first, shiftS: 0}
  const next = nextEntryOf({manifest, entry})
  const isNext = next.kind === ServiceDateKind.found
  const isContinued = isNext && isContinuing({routed: first, entry})

  if (!isContinued) {
    return answerOf([firstPart])
  }

  const shiftS = (next.entry.serviceDayStartMs - entry.serviceDayStartMs) / SECOND_MS
  assertCondition(Number.isInteger(shiftS), "routing journeys: the next service day starts a fraction of a second later: " + shiftS)
  const boundS = earliestCandidateS(first.candidates) - shiftS
  const second = await routeSnapshot({entry: next.entry, departureS: departureS - shiftS, from, toStopId, fetchFile, boundS})

  if (second.kind === JourneysKind.failed) {
    return second
  }

  if (second.kind !== RoutedKind.routed) {
    return answerOf([firstPart])
  }

  return answerOf([firstPart, {routed: second, shiftS}])
}
