// Expands a stored packed container, one gzip stream, under a bound, with
// the browser's DecompressionStream, so the pure reader of
// core/packed_container.js reads the expanded bytes.

import {assertCondition} from "./core/assert.js"
import {PackedOutcome, PackedRefusal} from "./core/packed_container.js"

const COMPRESSION_FORMAT = "gzip"

function refused(reason) {
  return {kind: PackedOutcome.refused, reason}
}

function isByteSource(source) {
  const isArray = source instanceof Uint8Array
  const isBuffer = source instanceof ArrayBuffer
  return isArray || isBuffer
}

// The chunks of `reader` joined into one array, read until the stream ends
// or passes `expandedByteSizeMax`.
async function readBounded({reader, expandedByteSizeMax}) {
  const chunks = []
  let byteCount = 0

  for (;;) {
    const read = await reader.read()

    if (read.done) {
      break
    }

    byteCount += read.value.byteLength

    if (byteCount > expandedByteSizeMax) {
      await reader.cancel()
      return refused(PackedRefusal.tooLarge)
    }

    chunks.push(read.value)
  }

  const bytes = new Uint8Array(byteCount)
  let offset = 0

  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }

  return {kind: PackedOutcome.expanded, bytes}
}

/**
 * The content of the gzip stream `source`, the bytes of a stored container
 * as fetched or a ReadableStream of them, expanded to at most
 * `expandedByteSizeMax` bytes: `{kind: "expanded", bytes}`, or
 * `{kind: "refused", reason}` with `tooLarge`, once the bound is passed and
 * reading stops, or `corrupt` for a stream that is not gzip or ends early.
 */
export async function expandStream(source, {expandedByteSizeMax}) {
  assertCondition(Number.isSafeInteger(expandedByteSizeMax), "the bound must be an integer")
  assertCondition(expandedByteSizeMax >= 1, "the bound must be at least 1 byte")
  const isStream = source instanceof ReadableStream
  const isSupported = isStream || isByteSource(source)
  assertCondition(isSupported, "the source must be bytes or a ReadableStream")

  let compressed = source

  if (!isStream) {
    compressed = new Blob([source]).stream()
  }

  const decompression = new DecompressionStream(COMPRESSION_FORMAT)
  const expanded = compressed.pipeThrough(decompression)
  const reader = expanded.getReader()

  try {
    return await readBounded({reader, expandedByteSizeMax})
  } catch {
    // A stream that is not gzip, or ends early, rejects the read; no other
    // failure comes from reading it.
    return refused(PackedRefusal.corrupt)
  }
}
