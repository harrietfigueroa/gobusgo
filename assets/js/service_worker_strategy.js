// How the service worker answers a request, and which caches it owns.
// Everything here is pure: it decides from a request's method, address, and
// mode, and from the names of caches, and touches no cache and no network.
//
// The worker owns the caches whose names start with one of its prefixes:
// one per release, which holds the files stored when the worker installs and
// the copies kept of the network-first paths, and one per content of the
// basemap's fonts and sprites, which outlives a release while the archive is
// the same. Any other cache belongs to another part of the page and is
// never deleted here; the offline schedules' cache is read, never written.

import {BUNDLE_MANIFEST_PATH} from "./offline_bundle.js"

const RELEASE_CACHE_PREFIX = "gobusgo-release-"
const BASEMAP_ASSETS_CACHE_PREFIX = "gobusgo-basemap-assets-"
const BASEMAP_ASSETS_PATH_PREFIX = "/vendor/basemaps-assets/"
const SAVED_FILE_PATH_PREFIXES = Object.freeze(["/tiles/", "/routing/"])
const SOCKET_PATH = "/live"
const MANIFEST_PATH = "/api/routing/manifest"
const OWNED_CACHE_PREFIXES = Object.freeze([RELEASE_CACHE_PREFIX, BASEMAP_ASSETS_CACHE_PREFIX])

/**
 * The kinds of answer: from the release's cache, falling back to the
 * network; from the basemap assets' cache, stored on first use; from the
 * offline schedules' cache, falling back to the network; from the network,
 * falling back to the stored copies; a page from the network, falling back
 * to the offline screen; or no answer, which leaves the request to the
 * browser.
 */
export const StrategyKind = Object.freeze({
  precached: "precached",
  basemapAsset: "basemapAsset",
  savedFile: "savedFile",
  networkFirst: "networkFirst",
  navigation: "navigation",
  untouched: "untouched"
})

/** The messages a page sends the worker: take over from the worker in use. */
export const MessageKind = Object.freeze({activate: "activate"})

/** The caches a stored copy is read from: the release's, or the offline schedules'. */
export const CacheRole = Object.freeze({release: "release", offlineSchedules: "offlineSchedules"})

// The routing manifest's stored copies, in the order they are tried without
// a network: the saved bundle's own, which names only files the bundle
// holds, then the latest one fetched.
const MANIFEST_FALLBACKS = Object.freeze([
  Object.freeze({cache: CacheRole.offlineSchedules, path: BUNDLE_MANIFEST_PATH}),
  Object.freeze({cache: CacheRole.release, path: MANIFEST_PATH})
])

/** The names of the caches of `release` and of the basemap assets `basemapAssetsId`. */
export function cacheNames({release, basemapAssetsId}) {
  return {
    release: RELEASE_CACHE_PREFIX + release,
    basemapAssets: BASEMAP_ASSETS_CACHE_PREFIX + basemapAssetsId
  }
}

function isSocketPath(pathname) {
  return pathname === SOCKET_PATH || pathname.startsWith(SOCKET_PATH + "/")
}

function isSavedFilePath(pathname) {
  for (const prefix of SAVED_FILE_PATH_PREFIXES) {
    if (pathname.startsWith(prefix)) {
      return true
    }
  }

  return false
}

/**
 * How the worker of origin `origin`, which stores `precachePaths` when it
 * installs, answers a request of `method` for `url` in `mode`. A kind that
 * reads a cache carries the `path` it is stored under: the address without
 * its query, since a digested asset's query adds nothing to its name. The
 * network-first kind also carries the stored copies it falls back to, in
 * order. The routing snapshot and tile files are answered from the saved
 * bundle first online too, since each file's address holds one content.
 */
export function requestStrategy({method, url, mode, origin, precachePaths}) {
  const target = new URL(url)
  const path = target.pathname

  if (method !== "GET") {
    return {kind: StrategyKind.untouched}
  }

  if (target.origin !== origin) {
    return {kind: StrategyKind.untouched}
  }

  if (isSocketPath(path)) {
    return {kind: StrategyKind.untouched}
  }

  if (precachePaths.includes(path)) {
    return {kind: StrategyKind.precached, path}
  }

  if (path.startsWith(BASEMAP_ASSETS_PATH_PREFIX)) {
    return {kind: StrategyKind.basemapAsset, path}
  }

  if (isSavedFilePath(path)) {
    return {kind: StrategyKind.savedFile, path}
  }

  if (path === MANIFEST_PATH) {
    return {kind: StrategyKind.networkFirst, path, fallbacks: MANIFEST_FALLBACKS}
  }

  if (mode === "navigate") {
    return {kind: StrategyKind.navigation}
  }

  return {kind: StrategyKind.untouched}
}

function isOwned(name) {
  for (const prefix of OWNED_CACHE_PREFIXES) {
    if (name.startsWith(prefix)) {
      return true
    }
  }

  return false
}

/**
 * The caches among `names` to delete when the worker whose caches are
 * `current` activates: those it owns that are not its own.
 */
export function staleCacheNames({names, current}) {
  const kept = Object.values(current)
  const stale = []

  for (const name of names) {
    const isCurrent = kept.includes(name)

    if (isCurrent) {
      continue
    }

    if (isOwned(name)) {
      stale.push(name)
    }
  }

  return stale
}
