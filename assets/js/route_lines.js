import {readyEventName} from "./basemap"
import {attachRouteHover} from "./route_hover"
import {
  addSource,
  changeEventName,
  filterProperties,
  routeFilter,
  routeKept,
  routeLayerName,
  sourceName
} from "./route_stop_tiles"

const layerName = "route-lines"
const emphasisLayerName = "route-lines-emphasis"
const lineWidthPixels = 2
const lineOpacity = 0.6
const lineOpacityDimmed = 0.2
const emphasisWidthPixels = 5
const emphasisOpacity = 1

// The first layer of the style that draws text or icons. The lines go under
// it, so the basemap's labels and everything added later stay readable.
function firstSymbolLayerName(map) {
  const layer = map.getStyle().layers.find(({type}) => type === "symbol")

  if (layer === undefined) {
    return undefined
  } else {
    return layer.id
  }
}

// Draws the line of `routeId` emphasized and every other line dimmed, or
// every line as it is without emphasis for null. It sets a filter and paint
// and leaves the source as it is.
function emphasizeRoute(map, routeId) {
  if (routeId === null) {
    map.setLayoutProperty(emphasisLayerName, "visibility", "none")
    map.setPaintProperty(layerName, "line-opacity", lineOpacity)
  } else {
    map.setFilter(emphasisLayerName, ["==", ["get", "routeId"], routeId])
    map.setLayoutProperty(emphasisLayerName, "visibility", "visible")
    map.setPaintProperty(layerName, "line-opacity", lineOpacityDimmed)
  }
}

// The hook of the element beside the map. It draws the routes layer of the
// route and stop tile archive on each map the basemap announces, so a map
// drawn anew for another archive shows them too, and keeps the lines to the
// routes the page's filter keeps.
export const RouteLines = {
  mounted() {
    this.map = null
    this.maplibre = null
    this.attached = false

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.attached = false
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => {
        this.map = map
        this.maplibre = maplibre
        this.attach()
      })
    }

    this.onChange = () => {
      if (this.map === null) {
        return
      } else if (this.attached) {
        this.map.setFilter(layerName, routeFilter())
      } else {
        this.attach()
      }
    }

    window.addEventListener(readyEventName, this.onBasemapReady)
    window.addEventListener(changeEventName, this.onChange)
  },

  // Adds the layers, once the page has an archive to draw them from.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    map.addLayer({
      id: layerName,
      type: "line",
      source: sourceName,
      "source-layer": routeLayerName,
      ...filterProperties(routeFilter()),
      layout: {"line-cap": "round", "line-join": "round"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": lineWidthPixels,
        "line-opacity": lineOpacity
      }
    }, firstSymbolLayerName(map))

    // The same lines again, above the layer of every line, of which a filter
    // shows the one route that is emphasized.
    map.addLayer({
      id: emphasisLayerName,
      type: "line",
      source: sourceName,
      "source-layer": routeLayerName,
      layout: {"line-cap": "round", "line-join": "round", visibility: "none"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": emphasisWidthPixels,
        "line-opacity": emphasisOpacity
      }
    }, firstSymbolLayerName(map))

    attachRouteHover({
      map,
      maplibre: this.maplibre,
      layerName,
      emphasize: (routeId) => { emphasizeRoute(map, routeId) },
      routeDrawn: routeKept
    })
    this.attached = true
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
    window.removeEventListener(changeEventName, this.onChange)
  }
}
