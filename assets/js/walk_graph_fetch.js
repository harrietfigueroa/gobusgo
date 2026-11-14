// The fetches of the walk graph files: the manifest, revalidated by the
// browser, and the index and shards it names, each fetched from an origin,
// the index checked against the size the manifest names, expanded within a
// bound, and decoded. Each answers with an outcome value, a fetched table or
// the reason it failed, and none throws.

import {PackedOutcome} from "./core/packed_container.js"
import {
  ManifestKind,
  WALK_GRAPH_INDEX_EXPANDED_BYTES_MAX,
  WALK_GRAPH_SHARD_EXPANDED_BYTES_MAX,
  acceptWalkManifest,
  decodeWalkGraphIndex,
  decodeWalkGraphShard
} from "./core/walk_graph_file.js"
import {expandStream} from "./packed_stream.js"

const FETCH_TIMEOUT_MS = 20 * 1000

/** The kinds of the answer to a fetch. */
export const FetchKind = Object.freeze({fetched: "fetched", failed: "failed"})

/** Why a fetch failed. */
export const FetchFailure = Object.freeze({
  fetch: "fetch",
  timeout: "timeout",
  manifest: "manifest",
  sizeMismatch: "sizeMismatch",
  expand: "expand",
  decode: "decode"
})

function failed(reason) {
  return {kind: FetchKind.failed, reason}
}

// Whether `error` is one a fetch or its body raises: a refused or aborted
// request (`TypeError`, `DOMException`) or a body that is not JSON
// (`SyntaxError`). Any other error, an `AssertionError` of a decoder among
// them, is a programmer error, which a catch clause throws on.
function isFetchError(error) {
  const isDomException = error instanceof DOMException
  const isNetworkError = error instanceof TypeError
  const isBadBody = error instanceof SyntaxError
  const isRequestFailure = isDomException || isNetworkError
  return isRequestFailure || isBadBody
}

function failureOfError(error) {
  const isDomException = error instanceof DOMException
  const isTimeout = isDomException && error.name === "TimeoutError"

  if (isTimeout) {
    return failed(FetchFailure.timeout)
  }

  return failed(FetchFailure.fetch)
}

/**
 * The manifest at `path` on `origin`, revalidated with the browser's own
 * conditional request. The answer is `{kind: "fetched", accepted}` with
 * `acceptWalkManifest`'s accepted result, or a failure.
 */
export async function fetchWalkManifest({origin, path}) {
  const signal = AbortSignal.timeout(FETCH_TIMEOUT_MS)

  try {
    const response = await fetch(origin + path, {signal, cache: "no-cache", credentials: "same-origin", headers: {accept: "application/json"}})

    if (!response.ok) {
      return failed(FetchFailure.fetch)
    }

    const manifest = await response.json()
    const accepted = acceptWalkManifest(manifest)

    if (accepted.kind === ManifestKind.refused) {
      return failed(FetchFailure.manifest)
    }

    return {kind: FetchKind.fetched, accepted}
  } catch (error) {
    if (!isFetchError(error)) {
      throw error
    }

    return failureOfError(error)
  }
}

// The decoded table of the gzip stream at `path`, or the failure.
async function fetchTable({origin, path, byteSize, expandedByteSizeMax, decode}) {
  const signal = AbortSignal.timeout(FETCH_TIMEOUT_MS)

  try {
    const response = await fetch(origin + path, {signal, cache: "default", credentials: "same-origin"})

    if (!response.ok) {
      return failed(FetchFailure.fetch)
    }

    const buffer = await response.arrayBuffer()
    const isSizeKnown = byteSize !== null
    const isSizeSame = buffer.byteLength === byteSize
    const isSizeWrong = isSizeKnown && !isSizeSame

    if (isSizeWrong) {
      return failed(FetchFailure.sizeMismatch)
    }

    const expanded = await expandStream(new Uint8Array(buffer), {expandedByteSizeMax})

    if (expanded.kind === PackedOutcome.refused) {
      return failed(FetchFailure.expand)
    }

    const decoded = decode(expanded.bytes)

    if (decoded.kind === PackedOutcome.refused) {
      return failed(FetchFailure.decode)
    }

    return {kind: FetchKind.fetched, table: decoded.table}
  } catch (error) {
    if (!isFetchError(error)) {
      throw error
    }

    return failureOfError(error)
  }
}

/** The index at `path`, of the `byteSize` its manifest names, as `{kind: "fetched", table}` or a failure. */
export async function fetchWalkIndex({origin, path, byteSize}) {
  return await fetchTable({origin, path, byteSize, expandedByteSizeMax: WALK_GRAPH_INDEX_EXPANDED_BYTES_MAX, decode: decodeWalkGraphIndex})
}

/** The shard at `path`, as `{kind: "fetched", table}` or a failure; the index names no size for it. */
export async function fetchWalkShard({origin, path}) {
  return await fetchTable({origin, path, byteSize: null, expandedByteSizeMax: WALK_GRAPH_SHARD_EXPANDED_BYTES_MAX, decode: decodeWalkGraphShard})
}
