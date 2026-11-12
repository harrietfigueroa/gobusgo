// How the service worker answers a request from stored copies: a routing
// snapshot or tile file from the saved offline bundle first, sliced to the
// byte range asked for, and the routing manifest from the network first.
// The caches and the network are functions this module is handed, so it
// reads no cache and fetches nothing of its own.
//
// A Range request is answered from the stored 200 itself, because the Cache
// API refuses to store a 206 and a PMTiles reader refuses a 200 longer than
// the range it asked for.
// https://w3c.github.io/ServiceWorker/#cache-put — checked 2026-11-08

import {assertCondition} from "./core/assert.js"
import {rangeAnswer, requestedRange} from "./byte_range.js"
import {NOT_SAVED_HEADER} from "./core/offline_bundle.js"

const NOT_SAVED_STATUS = 503
const NOT_SAVED_TEXT = "Not saved for offline use."
const DEFAULT_CONTENT_TYPE = "application/octet-stream"

/** The kinds of a read of a saved file: its stored body, or none. */
export const SavedKind = Object.freeze({found: "found", missing: "missing"})

const MISSING = Object.freeze({kind: SavedKind.missing})

/** The kinds of a read of a store: the response it holds, or none. */
export const StoredKind = Object.freeze({found: "found", missing: "missing"})

const NOT_STORED = Object.freeze({kind: StoredKind.missing})

/** A read of a store from `response`, a Cache API match, which is undefined where the store holds nothing. */
export function storedOf(response) {
  if (response === undefined) {
    return NOT_STORED
  }

  return {kind: StoredKind.found, response}
}

/**
 * The answer for a file that no stored copy holds and no network gives: a
 * 503 the page tells apart by its `NOT_SAVED_HEADER`, so it can say the file
 * is not saved where it shows what the file holds.
 */
export function notSavedAnswer() {
  const headers = {"content-type": "text/plain; charset=utf-8", "cache-control": "no-store", [NOT_SAVED_HEADER.name]: NOT_SAVED_HEADER.value}
  return new Response(NOT_SAVED_TEXT, {status: NOT_SAVED_STATUS, headers})
}

async function savedOf(stored) {
  if (stored.kind === StoredKind.missing) {
    return MISSING
  }

  const {response} = stored
  const blob = await response.blob()
  const etag = response.headers.get("etag")
  let contentType = response.headers.get("content-type")

  if (contentType === null) {
    contentType = DEFAULT_CONTENT_TYPE
  }

  return {kind: SavedKind.found, blob, etag, contentType}
}

/**
 * A reader of saved files that holds the stored body of at most
 * `heldCountMax` paths, the most recently read, so that the many ranges a
 * map asks of one archive read the store once. `readStored(path)` resolves
 * to a read of the store, from `storedOf`. A path with no stored copy is
 * not held, so a file is found on the first request once it is saved.
 */
export function savedFileReader({readStored, heldCountMax}) {
  assertCondition(Number.isSafeInteger(heldCountMax), "saved files: the held count is not an integer: " + heldCountMax)
  assertCondition(heldCountMax > 0, "saved files: the held count is not positive: " + heldCountMax)
  // Map keeps its keys in insertion order, so the first is the least recently read.
  const held = new Map()

  async function load(path) {
    const stored = await readStored(path)
    return savedOf(stored)
  }

  async function read(path) {
    const isHeld = held.has(path)

    if (isHeld) {
      const pending = held.get(path)
      held.delete(path)
      held.set(path, pending)
      return pending
    }

    const pending = load(path)
    held.set(path, pending)

    if (held.size > heldCountMax) {
      const [oldest] = held.keys()
      held.delete(oldest)
    }

    function release() {
      const isStillHeld = held.get(path) === pending

      if (isStillHeld) {
        held.delete(path)
      }
    }

    try {
      const saved = await pending

      if (saved.kind === SavedKind.missing) {
        release()
      }

      return saved
    } catch (error) {
      release()
      throw error
    }
  }

  return {read}
}

function slicedAnswer({saved, rangeHeader}) {
  const total = saved.blob.size
  const range = requestedRange({header: rangeHeader, total})
  const answer = rangeAnswer({range, total, etag: saved.etag, contentType: saved.contentType})
  const body = saved.blob.slice(answer.sliceStart, answer.sliceEnd)
  assertCondition(body.size === answer.sliceEnd - answer.sliceStart, "saved files: a slice holds " + body.size + " bytes of " + total)
  return new Response(body, {status: answer.status, headers: answer.headers})
}

/**
 * The answer to a request for the saved file `path` with `rangeHeader`, its
 * Range header or null: the stored body or the part of it asked for, else
 * what `fetchNetwork()` answers, else the not-saved answer.
 */
export async function answerSavedFile({path, rangeHeader, reader, fetchNetwork}) {
  const saved = await reader.read(path)

  if (saved.kind === SavedKind.found) {
    return slicedAnswer({saved, rangeHeader})
  }

  try {
    return await fetchNetwork()
  } catch (error) {
    // A file the bundle lacks and the network cannot give is not saved.
    console.warn("Saved file not found offline", path, error)
    return notSavedAnswer()
  }
}

async function storedFallback({fallbacks, readStored}) {
  for (const fallback of fallbacks) {
    const stored = await readStored(fallback)

    if (stored.kind === StoredKind.found) {
      return stored.response
    }
  }

  return notSavedAnswer()
}

/**
 * The answer from `fetchNetwork()`, a success of which is handed to
 * `storeCopy` as a copy, or offline the first of `fallbacks` whose read
 * `readStored(fallback)`, from `storedOf`, finds a response, else the
 * not-saved answer. A network answer that is no success is passed on as it
 * is.
 */
export async function answerNetworkFirst({fetchNetwork, fallbacks, readStored, storeCopy}) {
  let response

  try {
    response = await fetchNetwork()
  } catch (error) {
    console.warn("Network answer not fetched, stored copy used", error)
    return await storedFallback({fallbacks, readStored})
  }

  if (response.ok) {
    const copy = response.clone()

    try {
      await storeCopy(copy)
    } catch (error) {
      console.warn("Network answer not stored", error)
    }
  }

  return response
}
