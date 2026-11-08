// Reads the packed files of a routing snapshot, format version 1, as
// Gobusgo.Routing.SnapshotFormat writes them. Everything here is pure: each
// function takes an ArrayBuffer and returns its records, the connections and
// transfers as typed arrays a connection scan reads by index. Every number is
// little-endian. A file of another magic, version, or kind, or one whose
// records do not fill it, throws.

const formatMagic = "GBRT"
const formatVersion = 1
const headerBytes = 16
const connectionBytes = 24
const transferBytes = 12
const fileKinds = {stops: 1, trips: 2, transfers: 3, connections: 4}
const boardingBit = 1
const alightingBit = 2

const textDecoder = new TextDecoder("utf-8", {fatal: true})

function readHeader(buffer, kind) {
  const view = new DataView(buffer)
  const isLongEnough = buffer.byteLength >= headerBytes

  if (!isLongEnough) {
    throw new Error("routing snapshot: the file is shorter than its header")
  }

  const magic = String.fromCharCode(...new Uint8Array(buffer, 0, formatMagic.length))
  const version = view.getUint16(4, true)
  const fileKind = view.getUint16(6, true)

  if (magic !== formatMagic) {
    throw new Error("routing snapshot: the file does not start with " + formatMagic)
  }

  if (version !== formatVersion) {
    throw new Error("routing snapshot: unsupported format version " + version)
  }

  if (fileKind !== fileKinds[kind]) {
    throw new Error("routing snapshot: expected a file of kind " + kind)
  }

  return {view, count: view.getUint32(8, true)}
}

function assertFilled(buffer, offset) {
  if (offset !== buffer.byteLength) {
    throw new Error("routing snapshot: the records do not fill the file")
  }
}

function readString(buffer, view, offset) {
  const length = view.getUint16(offset, true)
  const start = offset + 2
  const text = textDecoder.decode(new Uint8Array(buffer, start, length))
  return {text, next: start + length}
}

/** The stop identifiers of a stops file, a stop's index being its position. */
export function decodeStops(buffer) {
  const {view, count} = readHeader(buffer, "stops")
  const stopIds = new Array(count)
  let offset = headerBytes

  for (let index = 0; index < count; index++) {
    const {text, next} = readString(buffer, view, offset)
    stopIds[index] = text
    offset = next
  }

  assertFilled(buffer, offset)
  return stopIds
}

/** The trips of a trips file: identifier, route, and service day offset. */
export function decodeTrips(buffer) {
  const {view, count} = readHeader(buffer, "trips")
  const trips = new Array(count)
  let offset = headerBytes

  for (let index = 0; index < count; index++) {
    const id = readString(buffer, view, offset)
    const routeId = readString(buffer, view, id.next)
    trips[index] = {id: id.text, routeId: routeId.text, serviceDayOffset: view.getUint8(routeId.next)}
    offset = routeId.next + 1
  }

  assertFilled(buffer, offset)
  return trips
}

/** The walking links of a transfers file, as typed arrays by column. */
export function decodeTransfers(buffer) {
  const {view, count} = readHeader(buffer, "transfers")
  assertFilled(buffer, headerBytes + count * transferBytes)
  const transfers = {fromStop: new Uint32Array(count), toStop: new Uint32Array(count), durationS: new Uint32Array(count)}

  for (let index = 0; index < count; index++) {
    const offset = headerBytes + index * transferBytes
    transfers.fromStop[index] = view.getUint32(offset, true)
    transfers.toStop[index] = view.getUint32(offset + 4, true)
    transfers.durationS[index] = view.getUint32(offset + 8, true)
  }

  return transfers
}

/** The connections of a connections file, in departure order, as typed arrays by column. */
export function decodeConnections(buffer) {
  const {view, count} = readHeader(buffer, "connections")
  assertFilled(buffer, headerBytes + count * connectionBytes)

  const connections = {
    departureS: new Int32Array(count),
    arrivalS: new Int32Array(count),
    departureStop: new Uint32Array(count),
    arrivalStop: new Uint32Array(count),
    trip: new Uint32Array(count),
    sequence: new Uint16Array(count),
    boarding: new Uint8Array(count),
    alighting: new Uint8Array(count),
  }

  for (let index = 0; index < count; index++) {
    const offset = headerBytes + index * connectionBytes
    const flags = view.getUint8(offset + 22)
    connections.departureS[index] = view.getInt32(offset, true)
    connections.arrivalS[index] = view.getInt32(offset + 4, true)
    connections.departureStop[index] = view.getUint32(offset + 8, true)
    connections.arrivalStop[index] = view.getUint32(offset + 12, true)
    connections.trip[index] = view.getUint32(offset + 16, true)
    connections.sequence[index] = view.getUint16(offset + 20, true)
    connections.boarding[index] = flags & boardingBit ? 1 : 0
    connections.alighting[index] = flags & alightingBit ? 1 : 0
  }

  return connections
}
