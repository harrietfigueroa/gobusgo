// The service worker. It stores the release's stylesheet, script, and map
// library when it installs, keeps the basemap's fonts and sprites as the
// page asks for them, answers the routing snapshot and tile files from the
// saved offline bundle first and the basemap's offline extract from the
// saved map first, keeps the latest copy of the network-first paths, and
// answers a page it cannot fetch with the offline screen.
//
// A new worker waits after it installs, so a page keeps the release it
// started with; it takes over when a page asks it to, which the page does
// when the rider takes the offer to reload. When it activates it deletes
// the caches of earlier releases.
//
// SERVICE_WORKER_BUILD is defined by the build: the release, the paths
// stored when the worker installs, and the content identifier of the
// basemap's fonts and sprites.

import {assertCondition, unreachable} from "./assert.js"
import {OFFLINE_BASEMAP_CACHE_NAME} from "./offline_basemap.js"
import {OFFLINE_SCHEDULES_CACHE_NAME} from "./offline_bundle.js"
import {answerNetworkFirst, answerSavedFile, savedFileReader, storedOf} from "./saved_files.js"
import {CacheRole, MessageKind, StrategyKind, cacheNames, requestStrategy, staleCacheNames} from "./service_worker_strategy.js"
import {OFFLINE_SCREEN} from "./offline_screen.js"

const NETWORK_TIMEOUT_MS = 15 * 1000
const OFFLINE_STATUS = 503
// The saved files whose stored bodies are held between requests: the tile
// archive, which a map reads in many ranges, and a few more.
const HELD_FILE_COUNT_MAX = 4
// The saved map holds one extract, which a map reads in many ranges.
const HELD_BASEMAP_COUNT_MAX = 1

const build = SERVICE_WORKER_BUILD
assertCondition(typeof build.release === "string", "the build must name a release, got: " + String(build.release))
assertCondition(Array.isArray(build.precachePaths), "the build must name the paths to store")

const names = cacheNames({release: build.release, basemapAssetsId: build.basemapAssetsId})

// CacheStorage's match with a cache name opens no cache, so a read never
// makes a store that the rider turned off.
function savedFileReaderOf({cacheName, heldCountMax}) {
  async function readStored(path) {
    const response = await caches.match(path, {cacheName})
    return storedOf(response)
  }

  return savedFileReader({readStored, heldCountMax})
}

const savedFiles = savedFileReaderOf({cacheName: OFFLINE_SCHEDULES_CACHE_NAME, heldCountMax: HELD_FILE_COUNT_MAX})
const savedBasemap = savedFileReaderOf({cacheName: OFFLINE_BASEMAP_CACHE_NAME, heldCountMax: HELD_BASEMAP_COUNT_MAX})

async function precache() {
  const cache = await caches.open(names.release)
  // Revalidated, so a build whose files keep their names never stores a
  // copy the browser's HTTP cache held from an earlier build.
  const requests = Array.from(build.precachePaths, revalidatedRequest)
  await cache.addAll(requests)
}

function revalidatedRequest(path) {
  return new Request(path, {cache: "no-cache"})
}

async function removeStaleCaches() {
  const present = await caches.keys()
  const stale = staleCacheNames({names: present, current: names})

  for (const name of stale) {
    await caches.delete(name)
  }

  await self.clients.claim()
}

function fetchWithTimeout(request) {
  const signal = AbortSignal.timeout(NETWORK_TIMEOUT_MS)
  return fetch(request, {signal})
}

async function storeResponse({cacheName, path, response}) {
  const cache = await caches.open(cacheName)
  await cache.put(path, response)
}

async function cacheFirst({cacheName, path, request}) {
  const cache = await caches.open(cacheName)
  const cached = await cache.match(path)

  if (cached !== undefined) {
    return cached
  }

  const response = await fetchWithTimeout(request)

  if (response.ok) {
    const copy = response.clone()
    await storeResponse({cacheName, path, response: copy})
  }

  return response
}

function cacheNameOf(role) {
  switch (role) {
    case CacheRole.release:
      return names.release
    case CacheRole.offlineSchedules:
      return OFFLINE_SCHEDULES_CACHE_NAME
    case CacheRole.offlineBasemap:
      return OFFLINE_BASEMAP_CACHE_NAME
    default:
      return unreachable(role, "cache role")
  }
}

function savedReaderOf(role) {
  switch (role) {
    case CacheRole.offlineSchedules:
      return savedFiles
    case CacheRole.offlineBasemap:
      return savedBasemap
    case CacheRole.release:
      return unreachable(role, "a saved file is never read from the release's cache")
    default:
      return unreachable(role, "cache role")
  }
}

async function readFallback(fallback) {
  const cacheName = cacheNameOf(fallback.cache)
  const response = await caches.match(fallback.path, {cacheName})
  return storedOf(response)
}

function networkFirst({path, fallbacks, request}) {
  function fetchNetwork() {
    return fetchWithTimeout(request)
  }

  function storeCopy(response) {
    return storeResponse({cacheName: names.release, path, response})
  }

  return answerNetworkFirst({fetchNetwork, fallbacks, readStored: readFallback, storeCopy})
}

function savedFile({path, cache, request}) {
  function fetchNetwork() {
    return fetchWithTimeout(request)
  }

  const rangeHeader = request.headers.get("range")
  const reader = savedReaderOf(cache)
  return answerSavedFile({path, rangeHeader, reader, fetchNetwork})
}

async function navigation(request) {
  try {
    return await fetchWithTimeout(request)
  } catch (error) {
    console.warn("Page not fetched, offline screen shown", error)
    const headers = {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"}
    return new Response(OFFLINE_SCREEN, {status: OFFLINE_STATUS, headers})
  }
}

function fetched(event) {
  const request = event.request
  const strategy = requestStrategy({
    method: request.method,
    url: request.url,
    mode: request.mode,
    origin: self.location.origin,
    precachePaths: build.precachePaths
  })

  switch (strategy.kind) {
    case StrategyKind.precached:
      event.respondWith(cacheFirst({cacheName: names.release, path: strategy.path, request}))
      break
    case StrategyKind.basemapAsset:
      event.respondWith(cacheFirst({cacheName: names.basemapAssets, path: strategy.path, request}))
      break
    case StrategyKind.savedFile:
      event.respondWith(savedFile({path: strategy.path, cache: strategy.cache, request}))
      break
    case StrategyKind.networkFirst:
      event.respondWith(networkFirst({path: strategy.path, fallbacks: strategy.fallbacks, request}))
      break
    case StrategyKind.navigation:
      event.respondWith(navigation(request))
      break
    case StrategyKind.untouched:
      break
    default:
      unreachable(strategy.kind, "request strategy")
  }
}

function messaged(event) {
  const data = event.data
  const isObject = typeof data === "object" && data !== null
  const isActivate = isObject && data.kind === MessageKind.activate

  if (isActivate) {
    self.skipWaiting()
  }
}

function installed(event) {
  event.waitUntil(precache())
}

function activated(event) {
  event.waitUntil(removeStaleCaches())
}

self.addEventListener("install", installed)
self.addEventListener("activate", activated)
self.addEventListener("fetch", fetched)
self.addEventListener("message", messaged)
