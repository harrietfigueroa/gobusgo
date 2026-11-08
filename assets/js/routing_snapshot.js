// Reads the packed files of a routing snapshot, format version 1, as
// Gobusgo.Routing.SnapshotFormat writes them. Everything here is pure: each
// function takes an ArrayBuffer and returns a result keyed by `kind`, either
// the decoded records, the connections and transfers as typed arrays a
// connection scan reads by index, or the reason the file was refused. Every
// number is little-endian.

const FORMAT_MAGIC = "GBRT"
const FORMAT_VERSION = 1
const HEADER_BYTES = 16
const MAGIC_BYTES = 4
const VERSION_OFFSET = 4
const KIND_OFFSET = 6
const COUNT_OFFSET = 8
const STRING_LENGTH_BYTES = 2
const SERVICE_DAY_OFFSET_BYTES = 1

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
const BOARDING_BIT = 1
const ALIGHTING_BIT = 2

const FILE_KINDS = Object.freeze({stops: 1, trips: 2, transfers: 3, connections: 4})

/** The kinds of a decoding result. */
export const DecodeKind = Object.freeze({decoded: "decoded", refused: "refused"})

/** Why a file was refused. */
export const RefusalReason = Object.freeze({
  invalidHeader: "invalidHeader",
  unsupportedVersion: "unsupportedVersion",
  invalidLength: "invalidLength",
  invalidText: "invalidText",
})

const textDecoder = new TextDecoder("utf-8", {fatal: true})

function refused(reason) {
  return {kind: DecodeKind.refused, reason}
}

function decoded(records) {
  return {kind: DecodeKind.decoded, records}
}

function readMagic(buffer) {
  const bytes = new Uint8Array(buffer, 0, MAGIC_BYTES)
  let magic = ""

  for (const byte of bytes) {
    magic += String.fromCharCode(byte)
  }

  return magic
}

// The header's record count, or the reason the header is refused.
function readHeader({buffer, kind}) {
  if (buffer.byteLength < HEADER_BYTES) {
    return refused(RefusalReason.invalidHeader)
  }

  const view = new DataView(buffer)

  if (readMagic(buffer) !== FORMAT_MAGIC) {
    return refused(RefusalReason.invalidHeader)
  }

  if (view.getUint16(VERSION_OFFSET, true) !== FORMAT_VERSION) {
    return refused(RefusalReason.unsupportedVersion)
  }

  if (view.getUint16(KIND_OFFSET, true) !== FILE_KINDS[kind]) {
    return refused(RefusalReason.invalidHeader)
  }

  return decoded({view, count: view.getUint32(COUNT_OFFSET, true)})
}

// The string at `offset` and the offset after it, or the reason it is refused.
function readString({buffer, view, offset}) {
  const textStart = offset + STRING_LENGTH_BYTES

  if (textStart > buffer.byteLength) {
    return refused(RefusalReason.invalidLength)
  }

  const textEnd = textStart + view.getUint16(offset, true)

  if (textEnd > buffer.byteLength) {
    return refused(RefusalReason.invalidLength)
  }

  try {
    const text = textDecoder.decode(new Uint8Array(buffer, textStart, textEnd - textStart))
    return decoded({text, next: textEnd})
  } catch (error) {
    if (error instanceof TypeError) {
      return refused(RefusalReason.invalidText)
    }

    throw error
  }
}

/** The stop identifiers of a stops file, a stop's index being its position. */
export function decodeStops(buffer) {
  const header = readHeader({buffer, kind: "stops"})

  if (header.kind === DecodeKind.refused) {
    return header
  }

  const {view, count} = header.records
  const stopIds = new Array(count)
  let offset = HEADER_BYTES

  for (let index = 0; index < count; index++) {
    const string = readString({buffer, view, offset})

    if (string.kind === DecodeKind.refused) {
      return string
    }

    stopIds[index] = string.records.text
    offset = string.records.next
  }

  if (offset !== buffer.byteLength) {
    return refused(RefusalReason.invalidLength)
  }

  return decoded(stopIds)
}

/** The trips of a trips file: identifier, route, and service day offset. */
export function decodeTrips(buffer) {
  const header = readHeader({buffer, kind: "trips"})

  if (header.kind === DecodeKind.refused) {
    return header
  }

  const {view, count} = header.records
  const trips = new Array(count)
  let offset = HEADER_BYTES

  for (let index = 0; index < count; index++) {
    const id = readString({buffer, view, offset})

    if (id.kind === DecodeKind.refused) {
      return id
    }

    const routeId = readString({buffer, view, offset: id.records.next})

    if (routeId.kind === DecodeKind.refused) {
      return routeId
    }

    const offsetEnd = routeId.records.next + SERVICE_DAY_OFFSET_BYTES

    if (offsetEnd > buffer.byteLength) {
      return refused(RefusalReason.invalidLength)
    }

    trips[index] = {
      id: id.records.text,
      routeId: routeId.records.text,
      serviceDayOffset: view.getUint8(routeId.records.next),
    }

    offset = offsetEnd
  }

  if (offset !== buffer.byteLength) {
    return refused(RefusalReason.invalidLength)
  }

  return decoded(trips)
}

/** The walking links of a transfers file, as typed arrays by column. */
export function decodeTransfers(buffer) {
  const header = readHeader({buffer, kind: "transfers"})

  if (header.kind === DecodeKind.refused) {
    return header
  }

  const {view, count} = header.records

  if (HEADER_BYTES + count * TRANSFER_BYTES !== buffer.byteLength) {
    return refused(RefusalReason.invalidLength)
  }

  const transfers = {
    fromStop: new Uint32Array(count),
    toStop: new Uint32Array(count),
    durationS: new Uint32Array(count),
  }

  for (let index = 0; index < count; index++) {
    const offset = HEADER_BYTES + index * TRANSFER_BYTES
    transfers.fromStop[index] = view.getUint32(offset, true)
    transfers.toStop[index] = view.getUint32(offset + TRANSFER_TO_STOP_OFFSET, true)
    transfers.durationS[index] = view.getUint32(offset + TRANSFER_DURATION_OFFSET, true)
  }

  return decoded(transfers)
}

function flagSet(flags, bit) {
  if ((flags & bit) === 0) {
    return 0
  }

  return 1
}

/** The connections of a connections file, in departure order, as typed arrays by column. */
export function decodeConnections(buffer) {
  const header = readHeader({buffer, kind: "connections"})

  if (header.kind === DecodeKind.refused) {
    return header
  }

  const {view, count} = header.records

  if (HEADER_BYTES + count * CONNECTION_BYTES !== buffer.byteLength) {
    return refused(RefusalReason.invalidLength)
  }

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
    const offset = HEADER_BYTES + index * CONNECTION_BYTES
    const flags = view.getUint8(offset + CONNECTION_FLAGS_OFFSET)
    connections.departureS[index] = view.getInt32(offset, true)
    connections.arrivalS[index] = view.getInt32(offset + CONNECTION_ARRIVAL_OFFSET, true)
    connections.departureStop[index] = view.getUint32(offset + CONNECTION_DEPARTURE_STOP_OFFSET, true)
    connections.arrivalStop[index] = view.getUint32(offset + CONNECTION_ARRIVAL_STOP_OFFSET, true)
    connections.trip[index] = view.getUint32(offset + CONNECTION_TRIP_OFFSET, true)
    connections.sequence[index] = view.getUint16(offset + CONNECTION_SEQUENCE_OFFSET, true)
    connections.boarding[index] = flagSet(flags, BOARDING_BIT)
    connections.alighting[index] = flagSet(flags, ALIGHTING_BIT)
  }

  return decoded(connections)
}
