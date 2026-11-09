// Turns a hand-written fixture timetable into the snapshot files of format
// version 2, as Gobusgo.Routing.SnapshotFormat writes them, with the
// manifest entry that names them, so a check loads a fixture the way the
// browser loads a published snapshot. Connections are cut into chunks by the
// hour of their departure, as Gobusgo.Routing.Snapshot cuts them. Everything
// here is pure.

const MAGIC = [0x47, 0x42, 0x52, 0x54]
const FORMAT_VERSION = 2
const HEADER_BYTES = 16
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const COUNT_OFFSET = 8
const STRING_LENGTH_BYTES = 2
const SERVICE_DAY_OFFSET_BYTES = 1
const KIND_STOPS = 1
const KIND_TRIPS = 2
const KIND_TRANSFERS = 3
const KIND_CONNECTIONS = 4
const KIND_POSITIONS = 5
const TRANSFER_BYTES = 12
const TRANSFER_TO_STOP_OFFSET = 4
const TRANSFER_DURATION_OFFSET = 8
const CONNECTION_BYTES = 24
const CONNECTION_ARRIVAL_OFFSET = 4
const CONNECTION_DEPARTURE_STOP_OFFSET = 8
const CONNECTION_ARRIVAL_STOP_OFFSET = 12
const CONNECTION_TRIP_OFFSET = 16
const CONNECTION_SEQUENCE_OFFSET = 20
const CONNECTION_FLAGS_OFFSET = 22
const POSITION_BYTES = 8
const POSITION_LON_OFFSET = 4
const POSITION_UNKNOWN_MICRODEGREES = -2147483648
const MINUTE_SECONDS = 60
const HOUR_MINUTES = 60
const CHUNK_SECONDS = 60 * 60
const CLOCK_DIGITS = 2
const BOARDING_BIT = 1
const ALIGHTING_BIT = 2

/** The transfer rules of every fixture snapshot, those Gobusgo.Routing.Transfers states. */
export const TRANSFER_RULES = Object.freeze({minimumTransferS: 120, walkRadiusM: 400, walkSpeedMPerS: 1.2, walkLinkCountPerStopMax: 64})

const textEncoder = new TextEncoder()

/** Seconds from the start of the service day of `HH:MM`, past 24:00 after midnight. */
export function seconds(clockText) {
  const [hours, minutes] = clockText.split(":")
  return (Number(hours) * HOUR_MINUTES + Number(minutes)) * MINUTE_SECONDS
}

/** `HH:MM` of `secondsOfDay`. */
export function clock(secondsOfDay) {
  const minutes = Math.floor(secondsOfDay / MINUTE_SECONDS)
  const hours = String(Math.floor(minutes / HOUR_MINUTES)).padStart(CLOCK_DIGITS, "0")
  return hours + ":" + String(minutes % HOUR_MINUTES).padStart(CLOCK_DIGITS, "0")
}

// The value of an optional fixture field, or an empty list where the case
// leaves it out.
function listed(value) {
  if (value === undefined) {
    return []
  }

  return value
}

function header({view, kind, count}) {
  for (const [index, byte] of MAGIC.entries()) {
    view.setUint8(index, byte)
  }

  view.setUint16(VERSION_OFFSET, FORMAT_VERSION, true)
  view.setUint16(KIND_OFFSET, kind, true)
  view.setUint32(COUNT_OFFSET, count, true)
}

function encodeText(text) {
  return textEncoder.encode(text)
}

function writeString({view, buffer, offset, bytes}) {
  view.setUint16(offset, bytes.length, true)
  new Uint8Array(buffer, offset + STRING_LENGTH_BYTES, bytes.length).set(bytes)
  return offset + STRING_LENGTH_BYTES + bytes.length
}

function stopsFile(stopIds) {
  const encoded = Array.from(stopIds, encodeText)
  let length = HEADER_BYTES

  for (const bytes of encoded) {
    length += STRING_LENGTH_BYTES + bytes.length
  }

  const buffer = new ArrayBuffer(length)
  const view = new DataView(buffer)
  header({view, kind: KIND_STOPS, count: encoded.length})
  let offset = HEADER_BYTES

  for (const bytes of encoded) {
    offset = writeString({view, buffer, offset, bytes})
  }

  return buffer
}

function tripsFile(trips) {
  const encoded = []
  let length = HEADER_BYTES

  for (const trip of trips) {
    const id = encodeText(trip.id)
    const routeId = encodeText(trip.routeId)
    encoded.push({id, routeId})
    length += STRING_LENGTH_BYTES + id.length + STRING_LENGTH_BYTES + routeId.length + SERVICE_DAY_OFFSET_BYTES
  }

  const buffer = new ArrayBuffer(length)
  const view = new DataView(buffer)
  header({view, kind: KIND_TRIPS, count: encoded.length})
  let offset = HEADER_BYTES

  for (const [index, {id, routeId}] of encoded.entries()) {
    offset = writeString({view, buffer, offset, bytes: id})
    offset = writeString({view, buffer, offset, bytes: routeId})
    view.setUint8(offset, trips[index].serviceDayOffset)
    offset += SERVICE_DAY_OFFSET_BYTES
  }

  return buffer
}

function transfersFile(links) {
  const buffer = new ArrayBuffer(HEADER_BYTES + links.length * TRANSFER_BYTES)
  const view = new DataView(buffer)
  header({view, kind: KIND_TRANSFERS, count: links.length})

  for (const [index, link] of links.entries()) {
    const offset = HEADER_BYTES + index * TRANSFER_BYTES
    view.setUint32(offset, link.fromStop, true)
    view.setUint32(offset + TRANSFER_TO_STOP_OFFSET, link.toStop, true)
    view.setUint32(offset + TRANSFER_DURATION_OFFSET, link.durationS, true)
  }

  return buffer
}

// The positions of `stopIds` from the fixture's microdegrees by stop, the
// unknown position for a stop it leaves out.
function positionsFile({stopIds, positions}) {
  const buffer = new ArrayBuffer(HEADER_BYTES + stopIds.length * POSITION_BYTES)
  const view = new DataView(buffer)
  header({view, kind: KIND_POSITIONS, count: stopIds.length})

  for (const [index, stopId] of stopIds.entries()) {
    const offset = HEADER_BYTES + index * POSITION_BYTES
    let position = [POSITION_UNKNOWN_MICRODEGREES, POSITION_UNKNOWN_MICRODEGREES]

    if (Object.hasOwn(positions, stopId)) {
      position = positions[stopId]
    }

    view.setInt32(offset, position[0], true)
    view.setInt32(offset + POSITION_LON_OFFSET, position[1], true)
  }

  return buffer
}

function flagsOf(connection) {
  let flags = 0

  if (connection.boarding) {
    flags |= BOARDING_BIT
  }

  if (connection.alighting) {
    flags |= ALIGHTING_BIT
  }

  return flags
}

function connectionsFile(connections) {
  const buffer = new ArrayBuffer(HEADER_BYTES + connections.length * CONNECTION_BYTES)
  const view = new DataView(buffer)
  header({view, kind: KIND_CONNECTIONS, count: connections.length})

  for (const [index, connection] of connections.entries()) {
    const offset = HEADER_BYTES + index * CONNECTION_BYTES
    view.setInt32(offset, connection.departureS, true)
    view.setInt32(offset + CONNECTION_ARRIVAL_OFFSET, connection.arrivalS, true)
    view.setUint32(offset + CONNECTION_DEPARTURE_STOP_OFFSET, connection.departureStop, true)
    view.setUint32(offset + CONNECTION_ARRIVAL_STOP_OFFSET, connection.arrivalStop, true)
    view.setUint32(offset + CONNECTION_TRIP_OFFSET, connection.trip, true)
    view.setUint16(offset + CONNECTION_SEQUENCE_OFFSET, connection.sequence, true)
    view.setUint8(offset + CONNECTION_FLAGS_OFFSET, flagsOf(connection))
  }

  return buffer
}

function stopIdsOf(fixture) {
  const named = new Set(listed(fixture.stops))

  for (const trip of fixture.trips) {
    for (const stopTime of trip.stopTimes) {
      named.add(stopTime[0])
    }
  }

  for (const [fromStop, toStop] of listed(fixture.walks)) {
    named.add(fromStop)
    named.add(toStop)
  }

  return Array.from(named).sort()
}

function hops({trip, tripIndex, stopIndex}) {
  const result = []
  const noBoarding = new Set(listed(trip.noBoarding))
  const noAlighting = new Set(listed(trip.noAlighting))

  for (let stopIndexInTrip = 0; stopIndexInTrip + 1 < trip.stopTimes.length; stopIndexInTrip++) {
    const from = trip.stopTimes[stopIndexInTrip]
    const to = trip.stopTimes[stopIndexInTrip + 1]
    const departureClock = from[from.length - 1]

    result.push({
      departureS: seconds(departureClock),
      arrivalS: seconds(to[1]),
      departureStop: stopIndex.get(from[0]),
      arrivalStop: stopIndex.get(to[0]),
      trip: tripIndex,
      sequence: firstSequenceOf(trip) + stopIndexInTrip,
      boarding: !noBoarding.has(from[0]),
      alighting: !noAlighting.has(to[0]),
    })
  }

  return result
}

function compareConnections(left, right) {
  const keys = ["departureS", "arrivalS", "trip", "sequence"]

  for (const key of keys) {
    if (left[key] !== right[key]) {
      return left[key] - right[key]
    }
  }

  return 0
}

function compareLinks(left, right) {
  if (left.fromStop !== right.fromStop) {
    return left.fromStop - right.fromStop
  }

  return left.toStop - right.toStop
}

function tripId(trip) {
  return trip.id
}

// A previous date's trip in a snapshot keeps only its connections departing
// after the date starts, so its first one need not have sequence 0.
function firstSequenceOf(trip) {
  if (trip.firstSequence === undefined) {
    return 0
  }

  return trip.firstSequence
}

// A trip runs on the snapshot's own date unless the fixture says it is the
// previous date's.
function serviceDayOffsetOf(trip) {
  if (trip.serviceDayOffset === undefined) {
    return 0
  }

  return trip.serviceDayOffset
}

// A trip's route is the fixture's where it names one, and a route of its
// own otherwise.
function tripRecord(trip) {
  const serviceDayOffset = serviceDayOffsetOf(trip)

  if (trip.route === undefined) {
    return {id: trip.id, routeId: "route " + trip.id, serviceDayOffset}
  }

  return {id: trip.id, routeId: trip.route, serviceDayOffset}
}

// The connections, in departure order, cut where the hour of departure
// changes.
function chunksOf(connections) {
  const chunks = []

  for (const connection of connections) {
    const hour = Math.floor(connection.departureS / CHUNK_SECONDS)
    const last = chunks[chunks.length - 1]
    const isSameHour = last !== undefined && last.hour === hour

    if (isSameHour) {
      last.connections.push(connection)
    } else {
      chunks.push({hour, connections: [connection]})
    }
  }

  return chunks
}

function fileEntry({path, buffer}) {
  return {path, byteSize: buffer.byteLength, sha256: ""}
}

/**
 * The snapshot files of `fixture`, keyed by the path its manifest entry
 * names them at under `pathPrefix`, that entry, and the names the readable
 * legs need. `files` holds the same buffers as the engine loader takes
 * them.
 */
export function snapshotOf(fixture, pathPrefix = "/fixture") {
  const stopIds = stopIdsOf(fixture)
  const stopIndex = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    stopIndex.set(stopId, index)
  }

  const connections = []

  for (const [tripIndex, trip] of fixture.trips.entries()) {
    for (const hop of hops({trip, tripIndex, stopIndex})) {
      connections.push(hop)
    }
  }

  connections.sort(compareConnections)
  const links = []

  for (const [fromStop, toStop, durationS] of listed(fixture.walks)) {
    links.push({fromStop: stopIndex.get(fromStop), toStop: stopIndex.get(toStop), durationS})
  }

  links.sort(compareLinks)
  let positions = {}

  if (fixture.positions !== undefined) {
    positions = fixture.positions
  }

  const tripRecords = Array.from(fixture.trips, tripRecord)

  const tables = {
    stops: stopsFile(stopIds),
    trips: tripsFile(tripRecords),
    transfers: transfersFile(links),
    positions: positionsFile({stopIds, positions}),
  }

  const filesByPath = new Map()
  const entryFiles = {}

  for (const [name, buffer] of Object.entries(tables)) {
    const path = pathPrefix + "/" + name + ".bin"
    filesByPath.set(path, buffer)
    entryFiles[name] = fileEntry({path, buffer})
  }

  const connectionChunks = []
  const chunkBuffers = []

  for (const chunk of chunksOf(connections)) {
    const buffer = connectionsFile(chunk.connections)
    const path = pathPrefix + "/connections-" + chunk.hour + ".bin"
    const first = chunk.connections[0]
    const last = chunk.connections[chunk.connections.length - 1]
    filesByPath.set(path, buffer)
    chunkBuffers.push(buffer)
    connectionChunks.push({...fileEntry({path, buffer}), departureSMin: first.departureS, departureSMax: last.departureS, count: chunk.connections.length})
  }

  const entry = {
    serviceDate: fixture.serviceDate,
    serviceDayStartMs: fixture.serviceDayStartMs,
    stopCount: stopIds.length,
    transferRules: TRANSFER_RULES,
    files: entryFiles,
    connectionChunks,
  }

  return {
    files: {stops: tables.stops, transfers: tables.transfers, connectionChunks: chunkBuffers},
    filesByPath,
    entry,
    stopIds,
    stopIndex,
    tripIds: Array.from(fixture.trips, tripId),
    connections,
  }
}
