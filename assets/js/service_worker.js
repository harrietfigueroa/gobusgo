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

const NETWORK_TIMEOUT_MS = 15 * 1000
const THEME_SETTING_KEY = "gobusgo:theme"
const OFFLINE_STATUS = 503

const build = SERVICE_WORKER_BUILD
assertCondition(typeof build.release === "string", "the build must name a release, got: " + String(build.release))
assertCondition(Array.isArray(build.precachePaths), "the build must name the paths to store")

const names = cacheNames({release: build.release, basemapAssetsId: build.basemapAssetsId})

// The screen of a page the worker cannot fetch. It is drawn in the rider's
// theme: the stored setting where the page has stored one, and the system's
// preference otherwise.
const offlineScreen = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Gobusgo is offline</title>
<script>
try {
  var setting = localStorage.getItem("${THEME_SETTING_KEY}");
  if (setting === "light" || setting === "dark") {
    document.documentElement.dataset.theme = setting;
  }
} catch (error) {}
</script>
<style>
:root { color-scheme: light; --fill: #ffffff; --text: #0f172a; --accent: #16a34a; --surface: #f0f9ff; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { color-scheme: dark; --fill: #0f172a; --text: #e2e8f0; --accent: #22c55e; --surface: #0f1a24; }
}
:root[data-theme="dark"] { color-scheme: dark; --fill: #0f172a; --text: #e2e8f0; --accent: #22c55e; --surface: #0f1a24; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: var(--fill); color: var(--text); font: 16px/1.5 system-ui, sans-serif; }
main { max-width: 28rem; margin: 16px; padding: 24px; background: var(--surface); border: 1px solid var(--accent); border-radius: 8px; }
h1 { margin: 0 0 12px; font-size: 1.25rem; }
button { margin-top: 8px; padding: 6px 16px; font: inherit; font-weight: 600; color: inherit; background: transparent; border: 1px solid var(--accent); border-radius: 8px; }
</style>
</head>
<body>
<main>
<h1>Gobusgo is offline</h1>
<p>Gobusgo needs a network to show vehicles, stops, and arrivals, and this device has none right now.</p>
<p>Schedules saved for offline use stay saved on this device. The map opens again once you are back online.</p>
<button type="button" onclick="location.reload()">Try again</button>
</main>
</body>
</html>
`

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
    return new Response(offlineScreen, {status: OFFLINE_STATUS, headers})
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
