// The files the Trip tab's "Where to?" search reads, fetched and decoded in
// the browser so what a rider types never leaves the device: the places
// file, the address and intersection indexes and the shards a text names,
// and the stops of a routing snapshot. The places file and the two indexes
// load once the search box takes focus, a shard on the first text that
// needs it, and the session keeps the decoded shards of each kind in a
// bounded cache.
//
// Offline, the routing manifest and the snapshot files come from the saved
// offline bundle through the service worker, and the places file from the
// bundle where the saved index names one; the address and intersection
// files are not saved, so their searches need a connection.

import {loadAddressIndex, loadAddressShard} from "./address_file.js"
import {LookupKind, mergedResults, searchAddress, shardFor} from "./address_lookup.js"
import {loadIntersectionIndex, loadIntersectionShard} from "./intersection_file.js"
import {IntersectionLookupKind, planIntersection, searchIntersection} from "./intersection_lookup.js"
import {IndexKind} from "./core/offline_bundle.js"
import {savedRouteChip} from "./core/offline_answers.js"
import {readSavedIndex} from "./offline_schedules.js"
import {PackedOutcome} from "./core/packed_container.js"
import {loadPlaceFile} from "./place_file.js"
import {buildPlaceIndex, searchPlaces} from "./place_search.js"
import {DecodeKind, decodePositions, decodeStops, decodeTrips} from "./core/routing_snapshot.js"
import {headsignsByTrip} from "./journey_timeline.js"
import {decodeNames} from "./core/routing_names.js"
import {expandNames} from "./names_stream.js"
import {ServiceDateKind, serviceDateAt} from "./core/routing_journeys.js"
import {GROUP_COUNT_MAX, GroupKind, SHARD_CACHE_COUNT_MAX, ShardCacheKind, buildStopIndex, createShardCache, endPosition, placeDetailAt, searchStops} from "./where_to.js"

const PLACES_MANIFEST_PATH = "/places/manifest.json"
const ADDRESS_MANIFEST_PATH = "/api/addresses/manifest"
const INTERSECTION_MANIFEST_PATH = "/api/intersections/manifest"
const FETCH_TIMEOUT_MS = 20 * 1000
const MICRODEGREES_PER_DEGREE = 1_000_000
const PATH_SEPARATOR = "/"

/** The kinds of a source's load. */
export const SourceKind = Object.freeze({idle: "idle", loading: "loading", ready: "ready", failed: "failed"})

/** The kinds of a read of a snapshot's stops. */
export const StopsKind = Object.freeze({found: "found", failed: "failed"})

const IDLE = Object.freeze({kind: SourceKind.idle})
const FAILED = Object.freeze({kind: SourceKind.failed})
const NO_RESULTS = Object.freeze([])

// A manifest's path as an address on this origin: the places manifest
// names its file by its stored destination, with no leading slash.
function absolutePath(path) {
  if (path.startsWith(PATH_SEPARATOR)) {
    return path
  }

  return PATH_SEPARATOR + path
}

function directoryOf(path) {
  return path.slice(0, path.lastIndexOf(PATH_SEPARATOR) + 1)
}

async function fetchJson({origin, path, cache}) {
  const response = await fetch(origin + path, {cache, credentials: "same-origin", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS), headers: {accept: "application/json"}})

  if (!response.ok) {
    throw new Error(`${path} answered ${response.status}`)
  }

  return await response.json()
}

// The bytes of a file whose address holds one content, as the browser
// caches it.
async function fetchBytes({origin, path}) {
  const response = await fetch(origin + path, {cache: "default", credentials: "same-origin", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)})

  if (!response.ok) {
    throw new Error(`${path} answered ${response.status}`)
  }

  const buffer = await response.arrayBuffer()
  return new Uint8Array(buffer)
}

function decodedTable({loaded, path}) {
  if (loaded.kind !== PackedOutcome.decoded) {
    throw new Error(`${path} was refused: ${loaded.reason}`)
  }

  return loaded.table
}

// The address of the places file: the one the places manifest names, or,
// with no manifest to read, as offline, the one the saved offline bundle
// holds.
async function placesFilePath({origin}) {
  try {
    const manifest = await fetchJson({origin, path: PLACES_MANIFEST_PATH, cache: "no-cache"})
    return absolutePath(manifest.file.path)
  } catch (error) {
    const saved = await readSavedIndex()
    const isFound = saved.kind === IndexKind.found
    const hasPlacesPath = isFound && typeof saved.index.placesPath === "string"
    const hasPlaces = hasPlacesPath && saved.index.placesPath !== ""

    if (hasPlaces) {
      return saved.index.placesPath
    }

    throw error
  }
}

async function loadPlaces({origin}) {
  const path = await placesFilePath({origin})
  const bytes = await fetchBytes({origin, path})
  const loaded = await loadPlaceFile(bytes)
  const table = decodedTable({loaded, path})
  return {kind: SourceKind.ready, table, index: buildPlaceIndex(table)}
}

async function loadIndex({origin, manifestPath, load}) {
  const manifest = await fetchJson({origin, path: manifestPath, cache: "no-cache"})
  const path = manifest.index.path
  const bytes = await fetchBytes({origin, path})
  const loaded = await load(bytes)
  return {kind: SourceKind.ready, index: decodedTable({loaded, path}), directory: directoryOf(path), shards: createShardCache({countMax: SHARD_CACHE_COUNT_MAX})}
}

async function loadCountyIndex({origin, county}) {
  const path = county.index.path
  const bytes = await fetchBytes({origin, path})
  const loaded = await loadAddressIndex(bytes)
  return {county: county.county, index: decodedTable({loaded, path}), directory: directoryOf(path)}
}

// The address manifest names each county's build, and each county's index
// is loaded; a county whose index fails to load is left out, so the others
// still answer, and the source fails only when every county's does.
async function loadAddressIndexes({origin}) {
  const manifest = await fetchJson({origin, path: ADDRESS_MANIFEST_PATH, cache: "no-cache"})
  const pending = Array.from(manifest.counties, (county) => loadCountyIndex({origin, county}))
  const settled = await Promise.allSettled(pending)
  const counties = []

  for (const outcome of settled) {
    if (outcome.status === "fulfilled") {
      counties.push(outcome.value)
    } else {
      console.warn("Address index not loaded", outcome.reason)
    }
  }

  if (counties.length === 0) {
    throw new Error("No county's address index loaded")
  }

  return {kind: SourceKind.ready, counties, shards: createShardCache({countMax: SHARD_CACHE_COUNT_MAX})}
}

async function loadShard({origin, source, name, load}) {
  const path = source.directory + name
  return await loadShardAt({origin, source, path, load})
}

async function loadShardAt({origin, source, path, load}) {
  const cached = source.shards.get(path)

  if (cached.kind === ShardCacheKind.cached) {
    return cached.table
  }

  const bytes = await fetchBytes({origin, path})
  const loaded = await load(bytes)
  const table = decodedTable({loaded, path})
  source.shards.put({path, table})
  return table
}

async function fetchTable({origin, path, decode}) {
  const bytes = await fetchBytes({origin, path})
  const decoded = decode(bytes.buffer)

  if (decoded.kind === DecodeKind.refused) {
    throw new Error(`${path} was refused: ${decoded.reason}`)
  }

  return decoded.records
}

// The stop identifiers and positions of `entry`, fetched together; a
// failure of either rejects with it, once both have settled.
async function loadSnapshotStops({origin, entry}) {
  const pending = [fetchTable({origin, path: entry.files.stops.path, decode: decodeStops}), fetchTable({origin, path: entry.files.positions.path, decode: decodePositions})]
  const settled = await Promise.allSettled(pending)
  const failure = settled.find(isRejected)

  if (failure !== undefined) {
    throw failure.reason
  }

  return Array.from(settled, settledValue)
}

function isRejected(outcome) {
  return outcome.status === "rejected"
}

function settledValue(outcome) {
  return outcome.value
}

async function loadJourneyNames({origin, entry}) {
  const trips = await fetchTable({origin, path: entry.files.trips.path, decode: decodeTrips})
  const stopIds = await fetchTable({origin, path: entry.files.stops.path, decode: decodeStops})
  const names = await decodedNames({origin, entry, stopCount: stopIds.length})
  const headsigns = headsignsByTrip({trips, tripHeadsigns: names.tripHeadsigns})
  const stops = {}

  for (const [index, stopId] of stopIds.entries()) {
    const name = names.stopNames[index]

    if (typeof name === "string") {
      stops[stopId] = {name, code: names.stopCodes[index]}
    }
  }

  const routes = {}

  for (const [routeId, route] of Object.entries(names.routes)) {
    routes[routeId] = savedRouteChip({route, routeId})
  }

  return {headsigns, stops, routes}
}

async function decodedNames({origin, entry, stopCount}) {
  const bytes = await fetchBytes({origin, path: entry.files.names.path})
  const expanded = await expandNames(bytes.buffer)

  if (expanded.kind === DecodeKind.refused) {
    throw new Error(`${entry.files.names.path} was refused: ${expanded.reason}`)
  }

  const decoded = decodeNames({buffer: expanded.records, stopCount, tripCount: entry.tripCount})

  if (decoded.kind === DecodeKind.refused) {
    throw new Error(`${entry.files.names.path} was refused: ${decoded.reason}`)
  }

  return decoded.records
}

// The snapshot whose stops the search lists: the one a departure now is
// routed in, or else the first.
function searchEntry(manifest) {
  const dated = serviceDateAt({manifest, departureMs: Date.now()})
  let serviceDate = manifest.snapshots[0].serviceDate

  if (dated.kind === ServiceDateKind.found) {
    serviceDate = dated.serviceDate
  }

  return manifest.snapshots.find((entry) => entry.serviceDate === serviceDate)
}

function placeResult({table, match, rider}) {
  const lat = table.latitudeMicrodegrees[match.placeIndex] / MICRODEGREES_PER_DEGREE
  const lon = table.longitudeMicrodegrees[match.placeIndex] / MICRODEGREES_PER_DEGREE
  const detail = placeDetailAt({
    categoryName: table.categoryNames[match.category],
    locality: table.localities[match.placeIndex],
    rider,
    lat,
    lon,
  })
  return {name: match.name, detail, lat, lon}
}

/**
 * The search files of one page, fetched from `origin`, the scheme and
 * host in front of each file's path, or "" for the page's own, loaded as
 * its warm method and the searches ask: warm, with the routing manifest's address, starts the loads
 * of the places file, the two indexes, and the stops, once; pendingLoads
 * gives the loads still running; search, with a text and a point near
 * which to rank, `{lat, lon}` in degrees, and the rider's position, the
 * only point a place's distance is measured from, `{lat, lon}` or null
 * where it is unknown and no distance is shown, resolves on the results of
 * each source for the text, each source that is not ready, or whose shard
 * fails, giving none; endPosition, with a resolved end and the rider's
 * position, gives the end's position once the stops are loaded; and snapshotStops, with a manifest entry, resolves
 * on the entry's stop identifiers and positions, which the stops of a
 * point end are found in.
 */
export function createSearchFiles({origin}) {
  const sources = {places: IDLE, addresses: IDLE, intersections: IDLE, stops: IDLE}
  const snapshots = new Map()
  const journeyNames = new Map()

  // Starts `load` for the source `name` once, and keeps what it gives.
  function start({name, load}) {
    if (sources[name].kind !== SourceKind.idle) {
      return
    }

    const promise = load().then((ready) => {
      sources[name] = ready
    }, (error) => {
      console.warn("Search file not loaded", name, error)
      sources[name] = FAILED
    })

    sources[name] = {kind: SourceKind.loading, promise}
  }

  function snapshotStops({entry}) {
    const path = entry.files.positions.path

    if (!snapshots.has(path)) {
      const loading = loadSnapshotStops({origin, entry})
      snapshots.set(path, loading)
      loading.catch(() => { snapshots.delete(path) })
    }

    return snapshots.get(path)
  }

  async function loadStops(routingManifestUrl) {
    const manifest = await fetchJson({origin, path: routingManifestUrl, cache: "no-cache"})
    const entry = searchEntry(manifest)
    const [stopIds, positions] = await snapshotStops({entry})
    const names = await decodedNames({origin, entry, stopCount: stopIds.length})
    const index = buildStopIndex({stopIds, names: names.stopNames, codes: names.stopCodes, latMicrodegrees: positions.latMicrodegrees, lonMicrodegrees: positions.lonMicrodegrees})
    return {kind: SourceKind.ready, index}
  }

  async function addressResults({text, near}) {
    const source = sources.addresses
    const pending = []

    for (const county of source.counties) {
      const shard = shardFor({index: county.index, text})

      if (shard.kind === LookupKind.found) {
        const path = county.directory + shard.path
        pending.push(countyOutcome({source, path, text, near}))
      }
    }

    const settled = await Promise.allSettled(pending)
    const outcomes = []

    for (const outcome of settled) {
      if (outcome.status === "fulfilled") {
        outcomes.push(outcome.value)
      } else {
        console.warn("Address shard not loaded", outcome.reason)
      }
    }

    return mergedResults(outcomes)
  }

  async function countyOutcome({source, path, text, near}) {
    const table = await loadShardAt({origin, source, path, load: loadAddressShard})
    return searchAddress({text, table, near: [near.lon, near.lat]})
  }

  async function intersectionResults({text, near}) {
    const source = sources.intersections
    const plan = planIntersection({text, index: source.index})

    if (plan.kind !== IntersectionLookupKind.plan) {
      return NO_RESULTS
    }

    const shard = await loadShard({origin, source, name: plan.path, load: loadIntersectionShard})
    const found = searchIntersection({query: plan.query, shard, near})

    if (found.kind !== IntersectionLookupKind.found) {
      return NO_RESULTS
    }

    return found.results
  }

  // The results of a source whose search fetches a shard, or none where
  // the source is not ready or the shard is not read.
  async function shardResults({name, search, text, near}) {
    if (sources[name].kind !== SourceKind.ready) {
      return NO_RESULTS
    }

    try {
      return await search({text, near})
    } catch (error) {
      console.warn("Search shard not read", name, error)
      return NO_RESULTS
    }
  }

  function placeResults({text, near, rider}) {
    const source = sources.places

    if (source.kind !== SourceKind.ready) {
      return NO_RESULTS
    }

    const matches = searchPlaces({index: source.index, query: text, center: {latitude: near.lat, longitude: near.lon}, resultCountMax: GROUP_COUNT_MAX[GroupKind.places]})
    return Array.from(matches, (match) => placeResult({table: source.table, match, rider}))
  }

  function stopResults({text, near}) {
    const source = sources.stops

    if (source.kind !== SourceKind.ready) {
      return NO_RESULTS
    }

    return searchStops({index: source.index, text, near, countMax: GROUP_COUNT_MAX[GroupKind.stops]})
  }

  return Object.freeze({
    warm({routingManifestUrl}) {
      start({name: "places", load: () => loadPlaces({origin})})
      start({name: "addresses", load: () => loadAddressIndexes({origin})})
      start({name: "intersections", load: () => loadIndex({origin, manifestPath: INTERSECTION_MANIFEST_PATH, load: loadIntersectionIndex})})
      start({name: "stops", load: () => loadStops(routingManifestUrl)})
    },

    /** The loads still running, so a search can answer again once they have ended. */
    pendingLoads() {
      const pending = []

      for (const source of Object.values(sources)) {
        if (source.kind === SourceKind.loading) {
          pending.push(source.promise)
        }
      }

      return pending
    },

    async search({text, near, rider}) {
      const pending = [
        shardResults({name: "addresses", search: addressResults, text, near}),
        shardResults({name: "intersections", search: intersectionResults, text, near}),
      ]
      const settled = await Promise.allSettled(pending)
      const [addresses, intersections] = Array.from(settled, settledValue)
      return {places: placeResults({text, near, rider}), addresses, intersections, stops: stopResults({text, near})}
    },

    /**
     * The position of the resolved end `end`, as `endPosition` reads it
     * with the stops this page has loaded: a stop's is unknown until they
     * are.
     */
    endPosition({end, rider}) {
      const source = sources.stops

      if (source.kind !== SourceKind.ready) {
        return endPosition({end, rider, stopIndex: null})
      }

      return endPosition({end, rider, stopIndex: source.index})
    },

    snapshotStops,

    /**
     * Resolves on the names of a manifest entry's journeys, read from its
     * stops, trips, and names files once per entry: `headsigns`, as
     * `headsignsByTrip` keys them, and `stops`, each stop's name and code
     * by identifier, in the shape the page's names answer has.
     */
    journeyNames({entry}) {
      const path = entry.files.trips.path

      if (!journeyNames.has(path)) {
        const loading = loadJourneyNames({origin, entry})
        journeyNames.set(path, loading)
        loading.catch(() => { journeyNames.delete(path) })
      }

      return journeyNames.get(path)
    },
  })
}
