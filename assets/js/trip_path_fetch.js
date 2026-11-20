// The fetches of the trip path files: the routing manifest, revalidated by
// its etag, and the index and route shards it names, each fetched from an
// origin, checked against the size the manifest or the index names, and
// expanded within a bound. Each answers with an outcome value and none
// throws.

import {PackedOutcome} from "./core/packed_container"
import {
  FILE_FETCH_TIMEOUT_MS,
  FileFailure,
  FileKind,
  FileOutcomeKind,
  INDEX_EXPANDED_BYTES_MAX,
  ManifestOutcomeKind,
  SHARD_EXPANDED_BYTES_MAX,
  hasExpectedSize
} from "./core/trip_path_files"
import {expandStream} from "./packed_stream.js"

function failureOfError(error) {
  const isDomException = error instanceof DOMException
  const isTimeout = isDomException && error.name === "TimeoutError"

  if (isTimeout) {
    return {kind: FileOutcomeKind.failed, reason: FileFailure.timeout}
  }

  return {kind: FileOutcomeKind.failed, reason: FileFailure.fetch}
}

/**
 * The manifest at `url`, revalidated with the browser's own conditional
 * request: a body whose etag is `etag` is `unchanged`, so the rules keep what
 * they hold. The answer is a ManifestOutcomeKind member with the manifest and
 * its etag where it changed.
 */
export async function fetchManifestOutcome({url, etag}) {
  const signal = AbortSignal.timeout(FILE_FETCH_TIMEOUT_MS)

  try {
    const response = await fetch(url, {signal, cache: "no-cache", credentials: "same-origin", headers: {accept: "application/json"}})

    if (!response.ok) {
      return {kind: ManifestOutcomeKind.failed}
    }

    const manifest = await response.json()
    const received = response.headers.get("etag")

    const isHeldEtag = received !== null && received === etag

    if (isHeldEtag) {
      return {kind: ManifestOutcomeKind.unchanged}
    }

    return {kind: ManifestOutcomeKind.changed, manifest, etag: received}
  } catch {
    // A refused or timed-out fetch and a body that is not JSON are the same
    // outcome to the rules: the manifest is not held.
    return {kind: ManifestOutcomeKind.failed}
  }
}

/**
 * One index or shard the manifest or the index names, fetched from `origin`
 * as the browser caches it, of the size `file` names, and expanded within its
 * bound. The answer is a FileOutcomeKind member with the expanded bytes where
 * the file arrived.
 */
export async function fetchTripPathFile({origin, file}) {
  const signal = AbortSignal.timeout(FILE_FETCH_TIMEOUT_MS)

  try {
    const url = origin + file.path
    const response = await fetch(url, {signal, cache: "default", credentials: "same-origin"})

    if (!response.ok) {
      return {kind: FileOutcomeKind.failed, reason: FileFailure.fetch}
    }

    const buffer = await response.arrayBuffer()

    if (!hasExpectedSize({fetch: file, byteLength: buffer.byteLength})) {
      return {kind: FileOutcomeKind.failed, reason: FileFailure.sizeMismatch}
    }

    let expandedByteSizeMax = SHARD_EXPANDED_BYTES_MAX

    if (file.kind === FileKind.index) {
      expandedByteSizeMax = INDEX_EXPANDED_BYTES_MAX
    }

    const expanded = await expandStream(new Uint8Array(buffer), {expandedByteSizeMax})

    if (expanded.kind === PackedOutcome.refused) {
      return {kind: FileOutcomeKind.failed, reason: FileFailure.decode}
    }

    return {kind: FileOutcomeKind.expanded, bytes: expanded.bytes}
  } catch (error) {
    return failureOfError(error)
  }
}
