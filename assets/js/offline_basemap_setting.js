// Saves the basemap's offline extract for offline use whole, in a Cache API
// store of its own apart from the saved schedules, reads what that store
// holds, deletes it, and announces each change of what is saved on the
// window, which the Basemap hook reads to choose the archive it draws.
//
// A save fetches the one file at low priority. The Cache API stores a
// response whole or not at all, so a save that stops part way stores
// nothing.

import {
  CHANGE_EVENT_NAME,
  OFFLINE_BASEMAP_CACHE_NAME,
  SettingKind,
  savedBasemapOf,
  stalePaths,
  statusMessage
} from "./offline_basemap"

function isSupported() {
  return "caches" in window
}

function pathOf(request) {
  return new URL(request.url).pathname
}

/**
 * A read of the saved map for the extract at `url`, which reads the
 * browser's store alone and so answers offline. A match with a cache name
 * opens no cache, so a read never makes the store the setting deleted.
 */
export async function readSavedBasemap(url) {
  if (!isSupported()) {
    return savedBasemapOf({url, isStored: false})
  }

  const response = await caches.match(url, {cacheName: OFFLINE_BASEMAP_CACHE_NAME})
  return savedBasemapOf({url, isStored: response !== undefined})
}

/** Announces `saved`, a read of the saved map, on the window. */
export function announceSavedBasemap(saved) {
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {saved}}))
}

// Stores the extract at `url` unless the store holds it, then deletes every
// other copy, an earlier build's extract.
async function save({url, signal}) {
  const cache = await caches.open(OFFLINE_BASEMAP_CACHE_NAME)
  const stored = await cache.match(url)

  if (stored === undefined) {
    const response = await fetch(url, {signal, priority: "low"})

    if (!response.ok) {
      console.warn("Offline map not saved", url, response.status)
      return
    }

    await cache.put(url, response)
  }

  const requests = await cache.keys()
  const storedPaths = Array.from(requests, pathOf)
  const stale = stalePaths({keptPath: url, storedPaths})

  for (const path of stale) {
    await cache.delete(path)
  }
}

/**
 * Saves the extract at `url` in the store, logging a save that fails; a
 * save `signal` aborts ends quietly.
 */
export async function saveBasemap({url, signal}) {
  try {
    await save({url, signal})
  } catch (error) {
    if (error.name !== "AbortError") {
      console.warn("Offline map not saved", error)
    }
  }
}

/** Deletes the store of the saved map and every copy in it. */
export async function deleteSavedBasemap() {
  await caches.delete(OFFLINE_BASEMAP_CACHE_NAME)
}

async function storedBytes(url) {
  const response = await caches.match(url, {cacheName: OFFLINE_BASEMAP_CACHE_NAME})

  if (response === undefined) {
    return 0
  }

  const blob = await response.blob()
  return blob.size
}

/**
 * The status line of the saved map for the extract at `url` while the
 * setting is on: whether it is saved, its size, and `persistence`, the
 * browser's answer to keeping the page's storage.
 */
export async function describeBasemap({url, persistence}) {
  const saved = await readSavedBasemap(url)
  const bytes = await storedBytes(url)
  return statusMessage({kind: SettingKind.on, saved, bytes, persistence})
}
