import {READY_EVENT_NAME} from "./basemap"
import {KeptKind} from "./scheduled_service"

// The source the route lines and the stops are drawn from: one vector source
// over the route and stop tile archive, which the basemap's protocol reads
// with range requests. The archive's address and the routes the page's
// filter keeps are data attributes of one element, which the server renders
// with the page and patches. While the page is offline, a trip's filter is
// held here instead, in place of the routes the element carries, since no
// server patches the element then.

const PROTOCOL_NAME = "pmtiles"
const ELEMENT_ID = "route-stop-tiles"

export const SOURCE_NAME = "route-stops"
export const ROUTE_LAYER_NAME = "routes"
export const STOP_LAYER_NAME = "stops"
export const CHANGE_EVENT_NAME = "route-stop-tiles:change"

// The kinds of a read of the current archive.
const ArchiveKind = Object.freeze({found: "found", none: "none"})

export {KeptKind}

/** The kinds of a layer's filter: none, which draws everything, or a filter. */
export const FilterKind = Object.freeze({none: "none", filter: "filter"})

// Whether the page shows routes of its own in place of the element's.
const LocalKind = Object.freeze({none: "none", kept: "kept"})

// The routes the page shows for itself while offline, or none while the
// element's routes stand.
let local = {kind: LocalKind.none}

function element() {
  return document.getElementById(ELEMENT_ID)
}

function absoluteUrl(path) {
  return new URL(path, window.location.href).href
}

function sourceUrl(archiveUrl) {
  return `${PROTOCOL_NAME}://${absoluteUrl(archiveUrl)}`
}

// The address of the current archive, or none while there is none.
function currentArchive() {
  const found = element()

  if (found === null) {
    return {kind: ArchiveKind.none}
  }

  const url = found.dataset.archiveUrl

  if (url === undefined) {
    return {kind: ArchiveKind.none}
  } else {
    return {kind: ArchiveKind.found, url}
  }
}

function archiveChanged(previous, current) {
  if (previous.kind !== current.kind) {
    return true
  } else if (current.kind === ArchiveKind.found) {
    return previous.url !== current.url
  } else {
    return false
  }
}

/**
 * The routes the page shows, a trip's filter shown offline included: every
 * route for a page with no filter, which draws every route of the archive,
 * or the list the filter keeps.
 */
export function keptRoutes() {
  if (local.kind === LocalKind.kept) {
    return local.kept
  }

  return elementRouteIds()
}

function showLocal(kept) {
  local = {kind: LocalKind.kept, kept}
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME))
}

/** Shows the routes of `routeIds` in place of the element's, until `endLocalRoutes`. */
export function showLocalRoutes(routeIds) {
  showLocal({kind: KeptKind.routes, routeIds: Array.from(routeIds)})
}

/** Shows every route in place of the element's routes, until `endLocalRoutes`. */
export function showLocalEveryRoute() {
  showLocal({kind: KeptKind.every})
}

/** The routes the element carries, whatever the page shows for itself: every route, or the list it holds. */
export function elementRouteIds() {
  const found = element()

  if (found === null) {
    return {kind: KeptKind.every}
  }

  const routeIds = found.dataset.routeIds

  if (routeIds === undefined) {
    return {kind: KeptKind.every}
  } else {
    return {kind: KeptKind.routes, routeIds: JSON.parse(routeIds)}
  }
}

/** Brings back the routes the element carries, where `showLocalRoutes` replaced them. */
export function endLocalRoutes() {
  if (local.kind === LocalKind.none) {
    return
  }

  local = {kind: LocalKind.none}
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME))
}

// Whether the page's filter keeps the route.
export function routeKept(routeId) {
  const kept = keptRoutes()

  if (kept.kind === KeptKind.every) {
    return true
  } else {
    return kept.routeIds.includes(routeId)
  }
}

// The filter of a layer of route lines: the kept routes by identifier.
export function routeFilter() {
  const kept = keptRoutes()

  if (kept.kind === KeptKind.every) {
    return {kind: FilterKind.none}
  } else {
    return {kind: FilterKind.filter, filter: ["in", ["get", "routeId"], ["literal", kept.routeIds]]}
  }
}

// The filter of a layer of stops: a stop one of whose routes is kept. A
// stop's `routeIds` holds its routes with a comma before, between, and after
// them, and `in` on a text tests for a substring, so ",<id>," matches one
// whole identifier.
// https://maplibre.org/maplibre-style-spec/expressions/#in — checked 2026-10-14
export function stopFilter() {
  const kept = keptRoutes()

  if (kept.kind === KeptKind.every) {
    return {kind: FilterKind.none}
  }

  const filter = ["any"]

  for (const routeId of kept.routeIds) {
    filter.push(["in", `,${routeId},`, ["get", "routeIds"]])
  }

  return {kind: FilterKind.filter, filter}
}

// The filter of a layer as the properties of the layer, none for no filter:
// a style refuses a layer whose filter is null.
export function filterProperties(layerFilter) {
  if (layerFilter.kind === FilterKind.none) {
    return {}
  } else {
    return {filter: layerFilter.filter}
  }
}

// Sets the filter of the layer `layerName` of `map`. MapLibre takes null
// for a layer that has no filter.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#setfilter — checked 2026-11-08
export function setLayerFilter({map, layerName, layerFilter}) {
  if (layerFilter.kind === FilterKind.none) {
    map.setFilter(layerName, null)
  } else {
    map.setFilter(layerName, layerFilter.filter)
  }
}

// Adds the source to `map` unless it is there or there is no archive, and
// says whether the map has it.
export function addSource(map) {
  if (map.getSource(SOURCE_NAME) !== undefined) {
    return true
  }

  const archive = currentArchive()

  if (archive.kind === ArchiveKind.none) {
    return false
  } else {
    map.addSource(SOURCE_NAME, {type: "vector", url: sourceUrl(archive.url)})
    return true
  }
}

// The hook of the element that carries the archive's address and the kept
// routes. A patch that changes the address points the map's source at the
// new archive. A patch that changes either is announced on the window with
// the "route-stop-tiles:change" event, which the hooks that draw the layers
// answer: by adding them, for a page that had no archive, or by applying
// the kept routes.
export const RouteStopTiles = {
  mounted() {
    this.map = null
    this.archive = currentArchive()
    this.routeIds = this.el.dataset.routeIds

    this.onBasemapReady = (event) => {
      this.map = event.detail.map
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
  },

  updated() {
    const archive = currentArchive()
    const routeIds = this.el.dataset.routeIds
    const isArchiveChanged = archiveChanged(this.archive, archive)
    const isSourceMovable = isArchiveChanged && this.map !== null

    if (isSourceMovable) {
      this.moveSource(archive)
    }

    const isChanged = isArchiveChanged || routeIds !== this.routeIds

    if (isChanged) {
      this.archive = archive
      this.routeIds = routeIds
      window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME))
    }
  },

  moveSource(archive) {
    const source = this.map.getSource(SOURCE_NAME)
    // A map with no source yet adds it with the new address when a hook
    // adds its layers.
    const hasSourceAndArchive = source !== undefined && archive.kind === ArchiveKind.found

    if (hasSourceAndArchive) {
      source.setUrl(sourceUrl(archive.url))
    }
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
  }
}
