// Expands the names file of a routing snapshot, one gzip stream, with the
// browser's DecompressionStream, under the bound the file's reader names, so
// its JSON is read once expanded.

import {NAMES_EXPANDED_BYTES_MAX, NamesRefusalReason} from "./core/routing_names.js"
import {DecodeKind} from "./core/routing_snapshot.js"

const COMPRESSION_FORMAT = "gzip"

function refused(reason) {
  return {kind: DecodeKind.refused, reason}
}

function decoded(records) {
  return {kind: DecodeKind.decoded, records}
}

// The chunks of `reader` joined into one buffer, read until the stream ends
// or passes NAMES_EXPANDED_BYTES_MAX.
async function readBounded(reader) {
  const chunks = []
  let byteCount = 0

  for (;;) {
    const read = await reader.read()

    if (read.done) {
      break
    }

    byteCount += read.value.byteLength

    if (byteCount > NAMES_EXPANDED_BYTES_MAX) {
      await reader.cancel()
      return refused(NamesRefusalReason.tooLarge)
    }

    chunks.push(read.value)
  }

  const bytes = new Uint8Array(byteCount)
  let offset = 0

  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }

  return decoded(bytes.buffer)
}

/** The content of the gzip stream `buffer`, a names file as fetched. */
export async function expandNames(buffer) {
  const compressed = new Blob([buffer]).stream()
  const expanded = compressed.pipeThrough(new DecompressionStream(COMPRESSION_FORMAT))
  const reader = expanded.getReader()

  try {
    return await readBounded(reader)
  } catch (error) {
    // A stream that is not gzip, or ends early, rejects the read with a TypeError.
    if (error instanceof TypeError) {
      return refused(NamesRefusalReason.invalidStream)
    }

    throw error
  }
}
