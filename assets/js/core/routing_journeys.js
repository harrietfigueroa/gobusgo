// Decides a journey query over the files of one or two routing snapshots,
// and fetches none of them. A query is a `startQuery` call and then
// `resumeQuery` calls, each returning the query's state, a plain value, and
// its next step: the files it needs, or its answer. The caller fetches the
// files, holds their bytes for the query, and hands every file it holds to
// each resume, so nothing here keeps a byte between calls and the same code
// answers from the network, the offline store, or files held in memory. The
// rider's position never reaches the caller's fetch: a start from a position
// is decided here, from the snapshot's positions file.
//
// A query asks for the stops, trips, transfers, and positions files at once,
// then for the connection chunks from the hour of its departure onward, one
// at a time, routing over every chunk it holds after each. It stops before
// the first chunk that departs after the cutoff, the earliest arrival found
// plus WINDOW_SECONDS, and keeps the frontier journeys that arrive by the
// cutoff. The scan reads connections from the departure onward and stops at
// the best arrival, so every journey that arrives by the cutoff uses only
// connections that depart before it, which the held chunks hold: the answer
// is the whole snapshot's frontier cut at the cutoff.
//
// A departure belongs to the latest snapshot whose service day has started
// by then. That snapshot holds its own date's trips and the trips of the
// date before that run past its start, so every trip running at the
// departure is in it. Where it has no journey, or its earliest arrives
// after its last connection departs, the query goes on into the next
// date's snapshot, whose trips that one lacks, with the departure moved
// into that date's seconds. The two frontiers meet on one timeline, and the
// window counts from the earliest arrival of either.
//
// A query that arrives by a time mirrors this: it asks for the chunks from
// the one holding its arrival backward, stops before the first chunk
// departing wholly before the latest departure found less WINDOW_SECONDS,
// and keeps the frontier journeys that leave at or after that. Where its
// date has no journey, or its latest leaves before the date's first
// connection, it goes back into the previous date's snapshot, whose trips
// before midnight that one lacks.

import {assertCondition, unreachable} from "./assert.js"
import {LegKind, OriginKind, createEngine, route, routeArrivingBy} from "./routing_engine.js"
import {DecodeKind, FORMAT_VERSION, POSITION_UNKNOWN_MICRODEGREES, decodeConnections, decodePositions, decodeStops, decodeTransfers, decodeTrips} from "./routing_snapshot.js"
import {startsNear} from "./routing_walk.js"

/** How long past the earliest arrival a journey with fewer changes is still shown. */
export const WINDOW_SECONDS = 45 * 60

/** How long a caller waits for one file before the fetch is a failure. */
export const FETCH_TIMEOUT_MS = 20 * 1000

const CHUNK_COUNT_MAX = 48
// A query routes in its own service date and at most one more.
const PART_COUNT_MAX = 2
// A part asks for its tables in one round and each chunk in a round of its own.
const PART_ROUND_COUNT_MAX = 1 + CHUNK_COUNT_MAX

/** The most times a query is resumed before it answers. */
export const ROUND_COUNT_MAX = PART_COUNT_MAX * PART_ROUND_COUNT_MAX

const SECOND_MS = 1000
const MICRODEGREES_PER_DEGREE = 1000000
// A sequence below every hop's, which a trip's first hop, at 0, follows.
const SEQUENCE_BEFORE_FIRST = -1
const NO_ARRIVAL_S = Number.POSITIVE_INFINITY
const NO_DEPARTURE_S = Number.NEGATIVE_INFINITY
// The index before the first chunk, where a backward load starts with none to read.
const NO_CHUNK_INDEX = -1
const RoutedKind = Object.freeze({routed: "routed"})
// What one part of a query needs next: files, or nothing more.
const PartStepKind = Object.freeze({needFiles: "needFiles"})
// Whether the first part of a query has been routed.
const FirstPartKind = Object.freeze({pending: "pending", routed: "routed"})
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

/** The kinds of a query's time: it leaves at a time, or arrives by one. */
export const TimeKind = Object.freeze({leaving: "leaving", arrivingBy: "arrivingBy"})

/** The kinds of a query's start: a stop by identifier, or a position in degrees. */
export const FromKind = Object.freeze({stop: "stop", position: "position"})

/** The kinds of what a file fetch hands back. */
export const FetchKind = Object.freeze({fetched: "fetched", failed: "failed"})

/** The kinds of the service date a departure belongs to. */
export const ServiceDateKind = Object.freeze({found: "found", none: "none"})

/** The kinds of a query's next step: the files it needs, or its answer. */
export const StepKind = Object.freeze({needFiles: "needFiles", done: "done"})

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
  notSaved: "notSaved",
  timedOut: "timedOut",
  sizeMismatch: "sizeMismatch",
  refused: "refused",
  positionsMismatch: "positionsMismatch",
})

function failed({reason, path}) {
  return {kind: JourneysKind.failed, reason, path}
}

function done(answer) {
  return {kind: StepKind.done, answer}
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

/**
 * `outcome`, what a fetch of `file`, an entry of the manifest, handed back,
 * checked against the size the manifest gives the file:
 * `{kind: FetchKind.fetched, buffer}`, or the failure naming the file.
 */
export function checkedOutcome({outcome, file}) {
  const isFetched = outcome.kind === FetchKind.fetched
  const isFailed = outcome.kind === FetchKind.failed
  const isKnown = isFetched || isFailed
  assertCondition(isKnown, "routing journeys: a fetch handed back an outcome of unknown kind " + outcome.kind)

  if (isFailed) {
    return failed({reason: outcome.reason, path: file.path})
  }

  if (outcome.buffer.byteLength !== file.byteSize) {
    return failed({reason: FailureReason.sizeMismatch, path: file.path})
  }

  return outcome
}

/** `fetched`, the content of the file at `path`, decoded by `decode`, or the failure naming the file where it is refused. */
export function decodedOrFailed({fetched, decode, path}) {
  const result = decode(fetched.buffer)

  if (result.kind === DecodeKind.refused) {
    return failed({reason: FailureReason.refused, path})
  }

  return {kind: DecodeKind.decoded, records: result.records, byteCount: fetched.buffer.byteLength}
}

const TABLE_DECODERS = Object.freeze({stops: decodeStops, trips: decodeTrips, transfers: decodeTransfers, positions: decodePositions})

function tableFilesOf(entry) {
  const names = Object.keys(TABLE_DECODERS)
  return Array.from(names, function fileOf(name) {
    return entry.files[name]
  })
}

// The four tables of `entry`, decoded from the held files.
function decodeTables({entry, files}) {
  const tables = {byteCount: 0}

  for (const [name, decode] of Object.entries(TABLE_DECODERS)) {
    const file = entry.files[name]
    const buffer = files.get(file.path)
    assertCondition(buffer !== undefined, "routing journeys: a table is not held: " + file.path)
    const table = decodedOrFailed({fetched: {buffer}, decode, path: file.path})

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

  function routeArrivingByQuery(query) {
    return routeArrivingBy(engine, query)
  }

  return {route: routeQuery, routeArrivingBy: routeArrivingByQuery}
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

// The frontier over the held chunks.
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

// The index of the chunk a query leaving at a time asks for next, after
// the held ones, or the chunk count where it needs none: from the
// departure onward until the next one departs after the cutoff.
function nextChunkLeaving({chunks, frontier, part}) {
  let index = firstChunkIndex({chunks, departureS: part.seconds})

  if (part.loadedIndexes.length > 0) {
    index = part.loadedIndexes[part.loadedIndexes.length - 1] + 1
  }

  if (index >= chunks.length) {
    return chunks.length
  }

  const startS = windowStartS({frontier, boundS: part.boundS})
  const isReached = startS < NO_ARRIVAL_S
  const cutoffS = startS + WINDOW_SECONDS
  const isPastCutoff = chunks[index].departureSMin > cutoffS
  const isPastWindow = isReached && isPastCutoff

  if (isPastWindow) {
    return chunks.length
  }

  return index
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
    const candidate = {serviceDate, arrivalS: journey.arrivalS, changes: journey.changes, legs, stopPositions}

    // A journey arriving by a time leaves at the time its scan found, which
    // a journey leaving at a time does not carry.
    if (journey.departureS !== undefined) {
      candidate.departureS = journey.departureS
    }

    candidates.push(candidate)
  }

  return candidates
}

// The held chunks of `part`, decoded in departure order, with their bytes,
// or the failure naming a refused one.
function decodeHeldChunks({entry, part, files}) {
  const records = []
  let byteCount = 0

  for (const index of part.loadedIndexes) {
    const file = entry.connectionChunks[index]
    const buffer = files.get(file.path)
    assertCondition(buffer !== undefined, "routing journeys: a chunk is not held: " + file.path)
    const chunk = decodedOrFailed({fetched: {buffer}, decode: decodeConnections, path: file.path})

    if (chunk.kind === JourneysKind.failed) {
      return chunk
    }

    records.push(chunk.records)
    byteCount += chunk.byteCount
  }

  return {kind: DecodeKind.decoded, records, byteCount}
}

// The scan of one snapshot over its held chunks in the direction `timeKind`
// names, and the index of the chunk it asks for next, or NO_CHUNK_INDEX
// where it needs none.
function scanOf({entry, tables, timeKind, origin, target, part, chunks}) {
  const minimumTransferS = entry.transferRules.minimumTransferS
  const connectionChunks = entry.connectionChunks

  switch (timeKind) {
    case TimeKind.leaving: {
      const query = {origin, target, departureS: part.seconds}
      const scan = routeLoaded({tables, chunks, minimumTransferS, query})
      const index = nextChunkLeaving({chunks: connectionChunks, frontier: scan.frontier, part})
      let nextIndex = index

      if (index === connectionChunks.length) {
        nextIndex = NO_CHUNK_INDEX
      }

      return {scan, nextIndex}
    }
    case TimeKind.arrivingBy: {
      const query = {origin, target, arrivalS: part.seconds}
      const scan = routeLoadedBack({tables, chunks, minimumTransferS, query})
      const nextIndex = nextChunkArrivingBy({chunks: connectionChunks, frontier: scan.frontier, part})
      return {scan, nextIndex}
    }
    default:
      return unreachable(timeKind, "routing journeys: a time of unknown kind")
  }
}

// One step of routing in one snapshot: its tables, the origin and target
// resolved in its stop numbering, and its chunks by window, leaving at a
// time or arriving by one as `timeKind` says. `part.boundS`, in this
// snapshot's seconds, is a time already found elsewhere, which the window
// counts from where it is better than this snapshot's own. The step is the
// files it needs next, the routed candidates, or why it cannot route.
function partStepOf({entry, timeKind, from, toStopId, part, files}) {
  if (entry.connectionChunks.length > CHUNK_COUNT_MAX) {
    return failed({reason: FailureReason.tooManyChunks, path: ""})
  }

  const tableFiles = tableFilesOf(entry)

  function isHeld(file) {
    return files.has(file.path)
  }

  const isTablesHeld = tableFiles.every(isHeld)

  if (!isTablesHeld) {
    return {kind: PartStepKind.needFiles, files: tableFiles, chunkIndex: NO_CHUNK_INDEX}
  }

  const decodedTables = decodeTables({entry, files})

  if (decodedTables.kind === JourneysKind.failed) {
    return decodedTables
  }

  const {tables} = decodedTables
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

  const heldChunks = decodeHeldChunks({entry, part, files})

  if (heldChunks.kind === JourneysKind.failed) {
    return heldChunks
  }

  const {scan, nextIndex} = scanOf({entry, tables, timeKind, origin, target, part, chunks: heldChunks.records})

  if (nextIndex !== NO_CHUNK_INDEX) {
    return {kind: PartStepKind.needFiles, files: [entry.connectionChunks[nextIndex]], chunkIndex: nextIndex}
  }

  const candidates = candidatesOf({scan, tables, stopIndex, serviceDate: entry.serviceDate})
  const loaded = {chunkCount: part.loadedIndexes.length, byteCount: tables.byteCount + heldChunks.byteCount}
  return {kind: RoutedKind.routed, candidates, loaded}
}

function firstDepartureS(entry) {
  let firstS = NO_ARRIVAL_S

  for (const chunk of entry.connectionChunks) {
    firstS = Math.min(firstS, chunk.departureSMin)
  }

  return firstS
}

// The index of the last chunk with a connection departing at or before
// `arrivalS`, or NO_CHUNK_INDEX where none has.
function lastChunkIndex({chunks, arrivalS}) {
  for (let index = chunks.length - 1; index >= 0; index--) {
    if (chunks[index].departureSMin <= arrivalS) {
      return index
    }
  }

  return NO_CHUNK_INDEX
}

function latestDepartureS(frontier) {
  const latest = frontier[frontier.length - 1]
  return latest.departureS
}

// The frontier arriving by a time over the held chunks.
function routeLoadedBack({tables, chunks, minimumTransferS, query}) {
  const connections = joinChunks(chunks)
  const engine = createEngine({stopCount: tables.stops.length, connections, transfers: tables.transfers, minimumTransferS})
  const frontier = routeArrivingBy(engine, query)
  return {frontier, connections}
}

// The latest departure the window counts back from: this scan's own, or
// `boundS` where that is later.
function windowEndS({frontier, boundS}) {
  if (frontier.length === 0) {
    return boundS
  }

  return Math.max(latestDepartureS(frontier), boundS)
}

// The index of the chunk a query arriving by a time asks for next, before
// the held ones, or NO_CHUNK_INDEX where it needs none: from the arrival
// backward until the next one departs wholly before the cutoff, the latest
// departure less the window.
function nextChunkArrivingBy({chunks, frontier, part}) {
  let index = lastChunkIndex({chunks, arrivalS: part.seconds})

  if (part.loadedIndexes.length > 0) {
    index = part.loadedIndexes[0] - 1
  }

  if (index < 0) {
    return NO_CHUNK_INDEX
  }

  const endS = windowEndS({frontier, boundS: part.boundS})
  const isLeft = endS > NO_DEPARTURE_S
  const cutoffS = endS - WINDOW_SECONDS
  const isBeforeCutoff = chunks[index].departureSMax < cutoffS
  const isPastWindow = isLeft && isBeforeCutoff

  if (isPastWindow) {
    return NO_CHUNK_INDEX
  }

  return index
}

function latestCandidateS(candidates) {
  let latestS = NO_DEPARTURE_S

  for (const candidate of candidates) {
    latestS = Math.max(latestS, candidate.departureS)
  }

  return latestS
}

// The snapshot whose day starts last before `entry`'s.
function previousEntryOf({manifest, entry}) {
  let previous = {kind: ServiceDateKind.none}

  for (const candidate of manifest.snapshots) {
    const isEarlier = candidate.serviceDayStartMs < entry.serviceDayStartMs
    const isLater = previous.kind === ServiceDateKind.none || candidate.serviceDayStartMs > previous.entry.serviceDayStartMs
    const isPrevious = isEarlier && isLater

    if (isPrevious) {
      previous = {kind: ServiceDateKind.found, entry: candidate}
    }
  }

  return previous
}

function byChangesThenDeparture(left, right) {
  if (left.changes !== right.changes) {
    return left.changes - right.changes
  }

  if (left.absoluteS !== right.absoluteS) {
    return right.absoluteS - left.absoluteS
  }

  return left.partIndex - right.partIndex
}

// The answer arriving by a time from the candidates of one or two
// snapshots, each part with the seconds its day starts after the first's:
// their frontier on one timeline, cut at the latest departure less the
// window, the latest marked.
function answerArrivingByOf(parts) {
  const timed = []
  const loaded = {chunkCount: 0, byteCount: 0}

  for (const [partIndex, part] of parts.entries()) {
    loaded.chunkCount += part.routed.loaded.chunkCount
    loaded.byteCount += part.routed.loaded.byteCount

    for (const candidate of part.routed.candidates) {
      timed.push({candidate, absoluteS: candidate.departureS + part.shiftS, changes: candidate.changes, partIndex})
    }
  }

  timed.sort(byChangesThenDeparture)
  const kept = []
  let bestS = NO_DEPARTURE_S

  for (const entry of timed) {
    if (entry.absoluteS > bestS) {
      bestS = entry.absoluteS
      kept.push(entry)
    }
  }

  if (kept.length === 0) {
    return {kind: JourneysKind.none, loaded}
  }

  const cutoffS = bestS - WINDOW_SECONDS
  const journeys = []

  for (const entry of kept) {
    if (entry.absoluteS >= cutoffS) {
      journeys.push({...entry.candidate, isLatest: entry.absoluteS === bestS})
    }
  }

  return {kind: JourneysKind.found, journeys, loaded}
}

// Whether a query arriving by a time in `entry` goes back into the previous
// service date: it found no journey, or its latest leaves before the date's
// first connection departs.
function isContinuingBack({routed, entry}) {
  const latestS = latestCandidateS(routed.candidates)
  return latestS < firstDepartureS(entry)
}

// The manifest entry of `serviceDate`, or why a query cannot use it.
function entryOf({manifest, serviceDate}) {
  if (manifest.formatVersion !== FORMAT_VERSION) {
    return failed({reason: FailureReason.unsupportedVersion, path: ""})
  }

  const entry = manifest.snapshots.find(function isServiceDate(candidate) {
    return candidate.serviceDate === serviceDate
  })

  if (entry === undefined) {
    return failed({reason: FailureReason.unknownServiceDate, path: ""})
  }

  return {kind: ServiceDateKind.found, entry}
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
function answerLeavingOf(parts) {
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

function answerOf({timeKind, parts}) {
  switch (timeKind) {
    case TimeKind.leaving:
      return answerLeavingOf(parts)
    case TimeKind.arrivingBy:
      return answerArrivingByOf(parts)
    default:
      return unreachable(timeKind, "routing journeys: a time of unknown kind")
  }
}

function partOf({serviceDate, seconds, boundS, shiftS}) {
  return {serviceDate, seconds, boundS, shiftS, loadedIndexes: [], requested: [], chunkIndex: NO_CHUNK_INDEX}
}

// The second part of a query whose first part, routed in `entry`, found
// nothing or nothing before the date's edge, or none where the query ends
// with the first: the next date for a query leaving at a time, the previous
// one for a query arriving by one, with the time moved into that date's
// seconds and the window's bound from the first part's answer.
function secondPartOf({manifest, entry, request, routed}) {
  switch (request.kind) {
    case TimeKind.leaving: {
      const next = nextEntryOf({manifest, entry})
      const isNext = next.kind === ServiceDateKind.found
      const isContinued = isNext && isContinuing({routed, entry})

      if (!isContinued) {
        return {kind: ServiceDateKind.none}
      }

      const shiftS = (next.entry.serviceDayStartMs - entry.serviceDayStartMs) / SECOND_MS
      assertCondition(Number.isInteger(shiftS), "routing journeys: the next service day starts a fraction of a second later: " + shiftS)
      const boundS = earliestCandidateS(routed.candidates) - shiftS
      const part = partOf({serviceDate: next.entry.serviceDate, seconds: request.seconds - shiftS, boundS, shiftS})
      return {kind: ServiceDateKind.found, part}
    }
    case TimeKind.arrivingBy: {
      const previous = previousEntryOf({manifest, entry})
      const isPrevious = previous.kind === ServiceDateKind.found
      const isContinued = isPrevious && isContinuingBack({routed, entry})

      if (!isContinued) {
        return {kind: ServiceDateKind.none}
      }

      const shiftS = (entry.serviceDayStartMs - previous.entry.serviceDayStartMs) / SECOND_MS
      assertCondition(Number.isInteger(shiftS), "routing journeys: the service day starts a fraction of a second after the previous: " + shiftS)
      const boundS = latestCandidateS(routed.candidates) + shiftS
      const part = partOf({serviceDate: previous.entry.serviceDate, seconds: request.seconds + shiftS, boundS, shiftS: -shiftS})
      return {kind: ServiceDateKind.found, part}
    }
    default:
      return unreachable(request.kind, "routing journeys: a time of unknown kind")
  }
}

function heldEntry({manifest, serviceDate}) {
  const found = entryOf({manifest, serviceDate})
  assertCondition(found.kind === ServiceDateKind.found, "routing journeys: a query's service date left the manifest: " + serviceDate)
  return found.entry
}

// Routes the query as far as the held files take it: at most one step of
// each part, stopping at the first file it lacks or at its answer.
function advance({manifest, state, files}) {
  let current = state

  for (let partIndex = 0; partIndex < PART_COUNT_MAX; partIndex++) {
    const {request, part} = current
    const entry = heldEntry({manifest, serviceDate: part.serviceDate})
    const partStep = partStepOf({entry, timeKind: request.kind, from: request.from, toStopId: request.toStopId, part, files})
    const isFirstPart = current.first.kind === FirstPartKind.pending

    if (partStep.kind === PartStepKind.needFiles) {
      const asking = {...part, requested: partStep.files, chunkIndex: partStep.chunkIndex}
      return {state: {...current, part: asking}, step: {kind: StepKind.needFiles, files: partStep.files}}
    }

    if (partStep.kind !== RoutedKind.routed) {
      const isSecondFailed = !isFirstPart && partStep.kind === JourneysKind.failed

      if (isFirstPart || isSecondFailed) {
        return {state: current, step: done(partStep)}
      }

      const answer = answerOf({timeKind: request.kind, parts: [{routed: current.first.routed, shiftS: 0}]})
      return {state: current, step: done(answer)}
    }

    if (!isFirstPart) {
      const parts = [{routed: current.first.routed, shiftS: 0}, {routed: partStep, shiftS: part.shiftS}]
      return {state: current, step: done(answerOf({timeKind: request.kind, parts}))}
    }

    const second = secondPartOf({manifest, entry, request, routed: partStep})

    if (second.kind === ServiceDateKind.none) {
      const answer = answerOf({timeKind: request.kind, parts: [{routed: partStep, shiftS: 0}]})
      return {state: current, step: done(answer)}
    }

    current = {...current, first: {kind: FirstPartKind.routed, routed: partStep}, part: second.part}
  }

  return unreachable(current.part, "routing journeys: a query routed past its second service date")
}

/**
 * Starts the journey query `request`: `{kind, serviceDate, seconds, from,
 * toStopId}`, leaving at or after `seconds` for `TimeKind.leaving` and
 * arriving at or before it for `TimeKind.arrivingBy`, seconds from the start
 * of `serviceDate` in `manifest`, from `from` to the stop `toStopId`. `from`
 * is `{kind: FromKind.stop, stopId}` or `{kind: FromKind.position, lat,
 * lon}` in degrees.
 *
 * Returns `{state, step}`: the state to resume with, and either
 * `{kind: StepKind.needFiles, files}`, the manifest entries of the files to
 * fetch, or `{kind: StepKind.done, answer}`.
 *
 * A found answer leaving at a time holds the journeys arriving by the
 * earliest arrival plus WINDOW_SECONDS, fewest changes first, each with the
 * service date its times count from, its arrival, its changes, whether it is
 * the earliest, its legs by identifier, a ride's with every stop it passes
 * in `stopIds`, and in `stopPositions` the position in degrees of each stop
 * it names whose position the snapshot knows; one arriving by a time holds
 * the journeys leaving at or after the latest departure less WINDOW_SECONDS,
 * each with the time it leaves in `departureS` and whether it is the latest.
 * `loaded` counts the chunks and the bytes the query read.
 *
 * Where `serviceDate` has no journey, or its earliest arrives after the
 * date's last connection departs (its latest leaves before the date's first
 * connection, arriving by a time), the query goes on into the snapshot whose
 * day starts next (before), once and no further, and its journeys carry
 * that date.
 */
export function startQuery({manifest, request}) {
  const isLeaving = request.kind === TimeKind.leaving
  const isArrivingBy = request.kind === TimeKind.arrivingBy
  const isKnownTime = isLeaving || isArrivingBy
  assertCondition(isKnownTime, "routing journeys: a query of unknown time kind " + request.kind)
  const found = entryOf({manifest, serviceDate: request.serviceDate})

  if (found.kind === JourneysKind.failed) {
    return {state: {request, roundCount: 0}, step: done(found)}
  }

  let boundS = NO_DEPARTURE_S

  if (isLeaving) {
    boundS = NO_ARRIVAL_S
  }

  const part = partOf({serviceDate: request.serviceDate, seconds: request.seconds, boundS, shiftS: 0})
  const state = {request, roundCount: 0, part, first: {kind: FirstPartKind.pending}}
  return advance({manifest, state, files: new Map()})
}

/**
 * Resumes a query from `state`, the state its last step returned, with
 * `fetched`, what the fetch of each file that step asked for handed back,
 * in the order asked: `{kind: FetchKind.fetched, buffer}` with an
 * ArrayBuffer, or `{kind: FetchKind.failed, reason}`. `files` maps the path
 * of every file the caller holds for the query to its ArrayBuffer, those of
 * `fetched` among them. Returns `{state, step}` as `startQuery` does; a
 * failed fetch or a file of another size than the manifest's is a done step
 * whose answer names the file.
 */
export function resumeQuery({manifest, state, fetched, files}) {
  const {part} = state
  assertCondition(state.roundCount < ROUND_COUNT_MAX, "routing journeys: a query resumed past " + ROUND_COUNT_MAX + " rounds")
  assertCondition(fetched.length === part.requested.length, "routing journeys: " + fetched.length + " outcomes for " + part.requested.length + " files asked for")

  for (const [index, outcome] of fetched.entries()) {
    const checked = checkedOutcome({outcome, file: part.requested[index]})

    if (checked.kind === JourneysKind.failed) {
      return {state, step: done(checked)}
    }
  }

  const loadedIndexes = Array.from(part.loadedIndexes)

  if (part.chunkIndex !== NO_CHUNK_INDEX) {
    loadedIndexes.push(part.chunkIndex)
    loadedIndexes.sort(byIndex)
  }

  const resumed = {...part, loadedIndexes, requested: [], chunkIndex: NO_CHUNK_INDEX}
  const next = {...state, roundCount: state.roundCount + 1, part: resumed}
  return advance({manifest, state: next, files})
}

function byIndex(left, right) {
  return left - right
}
