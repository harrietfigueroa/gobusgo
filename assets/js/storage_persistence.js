// Asks the browser to keep the page's storage, so what the page saved for
// offline use is not evicted when the device runs short of space.

import {PersistenceKind} from "#core/offline_bundle.js"

/**
 * Reads whether the browser keeps the page's storage, without asking, and
 * resolves to a `PersistenceKind`: storage not kept yet reads as not
 * granted.
 */
export async function readPersistence() {
  const storage = navigator.storage
  const isReadable = storage !== undefined && typeof storage.persisted === "function"

  if (!isReadable) {
    return PersistenceKind.unknown
  }

  try {
    const persisted = await storage.persisted()

    if (persisted) {
      return PersistenceKind.granted
    }

    return PersistenceKind.notGranted
  } catch (error) {
    console.warn("Persistent storage not read", error)
    return PersistenceKind.unknown
  }
}

/**
 * Asks the browser to keep the page's storage and resolves to its answer, a
 * `PersistenceKind`. WebKit grants it by heuristics that favor a page opened
 * as a Home Screen web app.
 * https://webkit.org/?p=14403 — checked 2026-11-08
 */
export async function requestPersistence() {
  const storage = navigator.storage
  const isAskable = storage !== undefined && typeof storage.persist === "function"

  if (!isAskable) {
    return PersistenceKind.unknown
  }

  try {
    const persisted = await storage.persisted()

    if (persisted) {
      return PersistenceKind.granted
    }

    const granted = await storage.persist()

    if (granted) {
      return PersistenceKind.granted
    }

    return PersistenceKind.notGranted
  } catch (error) {
    console.warn("Persistent storage not requested", error)
    return PersistenceKind.unknown
  }
}
