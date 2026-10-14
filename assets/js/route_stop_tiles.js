import {readyEventName} from "./basemap"

// The source the route lines and the stops are drawn from: one vector source
// over the route and stop tile archive, which the basemap's protocol reads
// with range requests. The archive's address and the routes the page's
// filter keeps are data attributes of one element, which the server renders
// with the page and patches.

const protocolName = "pmtiles"
const elementId = "route-stop-tiles"

export const sourceName = "route-stops"
export const routeLayerName = "routes"
export const stopLayerName = "stops"
export const changeEventName = "route-stop-tiles:change"

function element() {
  return document.getElementById(elementId)
}

function absoluteUrl(path) {
  return new URL(path, window.location.href).href
}

function sourceUrl(archiveUrl) {
  return `${protocolName}://${absoluteUrl(archiveUrl)}`
}

// The address of the current archive, or null while there is none.
function archiveUrl() {
  const found = element()

  if (found === null || found.dataset.archiveUrl === undefined) {
    return null
  } else {
    return found.dataset.archiveUrl
  }
}

// The routes the filter keeps, or null for a page with no filter, which
// draws every route of the archive.
export function keptRouteIds() {
  const found = element()

  if (found === null || found.dataset.routeIds === undefined) {
    return null
  } else {
    return JSON.parse(found.dataset.routeIds)
  }
}

// Whether the page's filter keeps the route.
export function routeKept(routeId) {
  const kept = keptRouteIds()
  return kept === null || kept.includes(routeId)
}

// The filter of a layer of route lines: the kept routes by identifier.
export function routeFilter() {
  const kept = keptRouteIds()

  if (kept === null) {
    return null
  } else {
    return ["in", ["get", "routeId"], ["literal", kept]]
  }
}

// The filter of a layer of stops: a stop one of whose routes is kept. A
// stop's `routeIds` holds its routes with a comma before, between, and after
// them, and `in` on a text tests for a substring, so ",<id>," matches one
// whole identifier.
// https://maplibre.org/maplibre-style-spec/expressions/#in — checked 2026-10-14
export function stopFilter() {
  const kept = keptRouteIds()

  if (kept === null) {
    return null
  } else {
    return ["any", ...kept.map((routeId) => ["in", `,${routeId},`, ["get", "routeIds"]])]
  }
}

// The filter of a layer as the properties of the layer, none for no filter:
// a style refuses a layer whose filter is null.
export function filterProperties(filter) {
  if (filter === null) {
    return {}
  } else {
    return {filter}
  }
}

// Adds the source to `map` unless it is there or there is no archive, and
// says whether the map has it.
export function addSource(map) {
  if (map.getSource(sourceName) !== undefined) {
    return true
  }

  const url = archiveUrl()

  if (url === null) {
    return false
  } else {
    map.addSource(sourceName, {type: "vector", url: sourceUrl(url)})
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
    this.archiveUrl = archiveUrl()
    this.routeIds = this.el.dataset.routeIds

    this.onBasemapReady = (event) => {
      this.map = event.detail.map
    }

    window.addEventListener(readyEventName, this.onBasemapReady)
  },

  updated() {
    const url = archiveUrl()
    const routeIds = this.el.dataset.routeIds

    if (url !== this.archiveUrl) {
      const source = this.map === null ? undefined : this.map.getSource(sourceName)

      // A map with no source yet adds it with the new address when a hook
      // adds its layers.
      if (source !== undefined && url !== null) {
        source.setUrl(sourceUrl(url))
      }
    }

    if (url !== this.archiveUrl || routeIds !== this.routeIds) {
      this.archiveUrl = url
      this.routeIds = routeIds
      window.dispatchEvent(new CustomEvent(changeEventName))
    }
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
  }
}
