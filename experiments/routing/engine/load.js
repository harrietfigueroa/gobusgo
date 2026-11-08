// Builds each engine of the routing experiment from the same snapshot files:
// a stops file, a transfers file, and the connection chunks in departure
// order, each an ArrayBuffer. Loading is measured apart from routing, so it
// lives here and the engines receive what it builds.

import {DecodeKind, decodeConnections, decodeStops, decodeTransfers} from "../../../assets/js/routing_snapshot.js"
import {LegKind, createEngine, route} from "./csa.js"

const CONNECTION_COLUMNS = ["departureS", "arrivalS", "departureStop", "arrivalStop", "trip", "sequence", "boarding", "alighting"]
const WASM_LEG_RIDE = 1
const WASM_VALUES_PER_LEG = 4
const WASM_VALUES_PER_JOURNEY = 3
const WASM_CHANGES_OFFSET = 1
const WASM_LEG_COUNT_OFFSET = 2

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

/** The JavaScript engine over `files`, with its `route` bound. */
export function loadJavaScriptEngine({files, minimumTransferS}) {
  const stopIds = records(decodeStops(files.stops), "stops")
  const transfers = records(decodeTransfers(files.transfers), "transfers")
  const connections = joinChunks(files.connectionChunks)
  const engine = createEngine({stopCount: stopIds.length, connections, transfers, minimumTransferS})
  return {route: query => route(engine, query)}
}

function copyIn({instance, file, add}) {
  const pointer = instance.exports.alloc(file.byteLength)
  new Uint8Array(instance.exports.memory.buffer, pointer, file.byteLength).set(new Uint8Array(file))
  const status = add(pointer, file.byteLength)
  instance.exports.dealloc(pointer, file.byteLength)

  if (status !== 0) {
    throw new Error("routing experiment: the WebAssembly engine refused a file, status " + status)
  }
}

// The frontier the WebAssembly engine encoded, in the JavaScript engine's shape.
function decodeFrontier(values) {
  const frontier = []
  let offset = 1

  for (let journey = 0; journey < values[0]; journey++) {
    const legCount = values[offset + WASM_LEG_COUNT_OFFSET]
    const legs = []
    let legOffset = offset + WASM_VALUES_PER_JOURNEY

    for (let leg = 0; leg < legCount; leg++) {
      const [kind, a, b, c] = values.subarray(legOffset, legOffset + WASM_VALUES_PER_LEG)

      if (kind === WASM_LEG_RIDE) {
        legs.push({kind: LegKind.ride, boardConnection: a, alightConnection: b})
      } else {
        legs.push({kind: LegKind.walk, fromStop: a, toStop: b, durationS: c})
      }

      legOffset += WASM_VALUES_PER_LEG
    }

    frontier.push({arrivalS: values[offset], changes: values[offset + WASM_CHANGES_OFFSET], legs})
    offset = legOffset
  }

  return frontier
}

/** The WebAssembly engine over `files`, instantiated from `module`, with its `route` bound. */
export async function loadWasmEngine({module, files, minimumTransferS}) {
  const instance = await WebAssembly.instantiate(module, {})
  const {exports} = instance
  exports.reset(minimumTransferS)
  copyIn({instance, file: files.stops, add: exports.add_stops})
  copyIn({instance, file: files.transfers, add: exports.add_transfers})

  for (const chunk of files.connectionChunks) {
    copyIn({instance, file: chunk, add: exports.add_connections})
  }

  exports.finish()

  function routeQuery(query) {
    const length = exports.query(query.source, query.target, query.departureS)
    const values = new Int32Array(exports.memory.buffer, exports.result_ptr(), length)
    return decodeFrontier(values.slice())
  }

  return {route: routeQuery, memory: exports.memory}
}
