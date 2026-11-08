// The service worker. It stores the release's stylesheet, script, and map
// library when it installs, keeps the basemap's fonts and sprites as the
// page asks for them, keeps the latest copy of the network-first paths, and
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
import {MessageKind, StrategyKind, cacheNames, requestStrategy, staleCacheNames} from "./service_worker_strategy.js"
import {OFFLINE_SCREEN} from "./offline_screen.js"

const NETWORK_TIMEOUT_MS = 15 * 1000
const OFFLINE_STATUS = 503

const build = SERVICE_WORKER_BUILD
assertCondition(typeof build.release === "string", "the build must name a release, got: " + String(build.release))
assertCondition(Array.isArray(build.precachePaths), "the build must name the paths to store")

const names = cacheNames({release: build.release, basemapAssetsId: build.basemapAssetsId})

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

async function networkFirst({path, request}) {
  try {
    const response = await fetchWithTimeout(request)

    if (response.ok) {
      const copy = response.clone()
      await storeResponse({cacheName: names.release, path, response: copy})
    }

    return response
  } catch (error) {
    const cache = await caches.open(names.release)
    const cached = await cache.match(path)

    if (cached === undefined) {
      throw error
    }

    return cached
  }
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
    case StrategyKind.networkFirst:
      event.respondWith(networkFirst({path: strategy.path, request}))
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
