import {READY_EVENT_NAME} from "./basemap"
import {attachRouteHover} from "./route_hover"
import {
  addSource,
  CHANGE_EVENT_NAME,
  filterProperties,
  routeFilter,
  routeKept,
  ROUTE_LAYER_NAME,
  SOURCE_NAME,
  setLayerFilter
} from "./route_stop_tiles"

const LAYER_NAME = "route-lines"
const EMPHASIS_LAYER_NAME = "route-lines-emphasis"
const LINE_WIDTH_PIXELS = 2
const LINE_OPACITY = 0.6
const LINE_OPACITY_DIMMED = 0.2
const EMPHASIS_WIDTH_PIXELS = 5
const EMPHASIS_OPACITY = 1

function isSymbolLayer({type}) {
  return type === "symbol"
}

// Adds `layer` under the first layer of the style that draws text or icons,
// so the basemap's labels and everything added later stay readable.
function addLayerUnderSymbols(map, layer) {
  const symbolLayer = map.getStyle().layers.find(isSymbolLayer)

  if (symbolLayer === undefined) {
    map.addLayer(layer)
  } else {
    map.addLayer(layer, symbolLayer.id)
  }
}

// Draws the line of `routeId` emphasized and every other line dimmed, or
// every line as it is without emphasis for null. It sets a filter and paint
// and leaves the source as it is.
function emphasizeRoute(map, routeId) {
  if (routeId === null) {
    map.setLayoutProperty(EMPHASIS_LAYER_NAME, "visibility", "none")
    map.setPaintProperty(LAYER_NAME, "line-opacity", LINE_OPACITY)
  } else {
    map.setFilter(EMPHASIS_LAYER_NAME, ["==", ["get", "routeId"], routeId])
    map.setLayoutProperty(EMPHASIS_LAYER_NAME, "visibility", "visible")
    map.setPaintProperty(LAYER_NAME, "line-opacity", LINE_OPACITY_DIMMED)
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
        setLayerFilter({map: this.map, layerName: LAYER_NAME, layerFilter: routeFilter()})
      } else {
        this.attach()
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)
  },

  // Adds the layers, once the page has an archive to draw them from.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    addLayerUnderSymbols(map, {
      id: LAYER_NAME,
      type: "line",
      source: SOURCE_NAME,
      "source-layer": ROUTE_LAYER_NAME,
      ...filterProperties(routeFilter()),
      layout: {"line-cap": "round", "line-join": "round"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": LINE_WIDTH_PIXELS,
        "line-opacity": LINE_OPACITY
      }
    })

    // The same lines again, above the layer of every line, of which a filter
    // shows the one route that is emphasized.
    addLayerUnderSymbols(map, {
      id: EMPHASIS_LAYER_NAME,
      type: "line",
      source: SOURCE_NAME,
      "source-layer": ROUTE_LAYER_NAME,
      layout: {"line-cap": "round", "line-join": "round", visibility: "none"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": EMPHASIS_WIDTH_PIXELS,
        "line-opacity": EMPHASIS_OPACITY
      }
    })

    attachRouteHover({
      map,
      maplibre: this.maplibre,
      layerName: LAYER_NAME,
      emphasize: (routeId) => { emphasizeRoute(map, routeId) },
      routeDrawn: routeKept
    })
    this.attached = true
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
  }
}
