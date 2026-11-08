// Turns a hand-written fixture timetable into the snapshot files of format
// version 1, as Gobusgo.Routing.SnapshotFormat writes them, so both engines
// load a fixture the way they load a published snapshot. Everything here is
// pure.

const MAGIC = [0x47, 0x42, 0x52, 0x54]
const FORMAT_VERSION = 1
const HEADER_BYTES = 16
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const COUNT_OFFSET = 8
const STRING_LENGTH_BYTES = 2
const KIND_STOPS = 1
const KIND_TRANSFERS = 3
const KIND_CONNECTIONS = 4
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
const MINUTE_SECONDS = 60
const HOUR_MINUTES = 60
const CLOCK_DIGITS = 2
const BOARDING_BIT = 1
const ALIGHTING_BIT = 2

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
    view.setUint16(offset, bytes.length, true)
    new Uint8Array(buffer, offset + STRING_LENGTH_BYTES, bytes.length).set(bytes)
    offset += STRING_LENGTH_BYTES + bytes.length
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

  for (let sequence = 0; sequence + 1 < trip.stopTimes.length; sequence++) {
    const from = trip.stopTimes[sequence]
    const to = trip.stopTimes[sequence + 1]
    const departureClock = from[from.length - 1]

    result.push({
      departureS: seconds(departureClock),
      arrivalS: seconds(to[1]),
      departureStop: stopIndex.get(from[0]),
      arrivalStop: stopIndex.get(to[0]),
      trip: tripIndex,
      sequence,
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

/** The snapshot files of `fixture`, and the names the readable legs need. */
export function snapshotOf(fixture) {
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

  return {
    files: {stops: stopsFile(stopIds), transfers: transfersFile(links), connectionChunks: [connectionsFile(connections)]},
    stopIds,
    stopIndex,
    tripIds: Array.from(fixture.trips, tripId),
    connections,
  }
}
