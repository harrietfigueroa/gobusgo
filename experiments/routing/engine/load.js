// Builds the engine of the routing experiment from snapshot files: a stops
// file, a transfers file, and the connection chunks in departure order, each
// an ArrayBuffer. Loading is measured apart from routing, so it lives here
// and the engine receives what it builds.

import {DecodeKind, decodeConnections, decodeStops, decodeTransfers} from "../../../assets/js/routing_snapshot.js"
import {createEngine, route} from "./csa.js"

const CONNECTION_COLUMNS = ["departureS", "arrivalS", "departureStop", "arrivalStop", "trip", "sequence", "boarding", "alighting"]

function records(result, name) {
  if (result.kind === DecodeKind.refused) {
    throw new Error("routing experiment: the " + name + " file was refused: " + result.reason)
  }

  return result.records
}

// The chunks' columns joined into one set, in chunk order.
function joinChunks(chunks) {
  const decoded = []
  let count = 0

  for (const chunk of chunks) {
    const columns = records(decodeConnections(chunk), "connections")
    decoded.push(columns)
    count += columns.departureS.length
  }

  const joined = {}

  for (const name of CONNECTION_COLUMNS) {
    const Column = decoded[0][name].constructor
    const column = new Column(count)
    let offset = 0

    for (const columns of decoded) {
      column.set(columns[name], offset)
      offset += columns[name].length
    }

    joined[name] = column
  }

  return joined
}

/** The engine over `files`, with its `route` bound. */
export function loadEngine({files, minimumTransferS}) {
  const stopIds = records(decodeStops(files.stops), "stops")
  const transfers = records(decodeTransfers(files.transfers), "transfers")
  const connections = joinChunks(files.connectionChunks)
  const engine = createEngine({stopCount: stopIds.length, connections, transfers, minimumTransferS})

  function routeQuery(query) {
    return route(engine, query)
  }

  return {route: routeQuery}
}
