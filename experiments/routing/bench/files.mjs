// Reads one snapshot of the benchmark data from disk, for the node runners:
// the manifest in the data directory, and the stops, transfers, and
// connection chunk files of one service date.

import {readFileSync} from "node:fs"

export const root = new URL("../", import.meta.url)
export const SERVICE_DATE = "2026-11-08"

function arrayBuffer(bytes) {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

function fileOf(path) {
  const location = new URL("data" + path, root)
  return readFileSync(location)
}

function chunkFile(chunk) {
  return fileOf(chunk.path)
}

/** The snapshot of `serviceDate`: its entry, its files as ArrayBuffers, and their bytes. */
export function snapshot(serviceDate = SERVICE_DATE) {
  const manifestText = readFileSync(new URL("data/manifest.json", root), "utf-8")
  const manifest = JSON.parse(manifestText)
  const entry = manifest.snapshots.find(candidate => candidate.serviceDate === serviceDate)
  const stops = fileOf(entry.files.stops.path)
  const transfers = fileOf(entry.files.transfers.path)
  const chunks = Array.from(entry.connectionChunks, chunkFile)

  return {
    entry,
    bytes: [stops, transfers, ...chunks],
    files: {stops: arrayBuffer(stops), transfers: arrayBuffer(transfers), connectionChunks: Array.from(chunks, arrayBuffer)},
  }
}
