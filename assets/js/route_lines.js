import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {currentTheme} from "./color_theme"
import {EMPHASIS_EVENT_NAME} from "./route_emphasis"
import {attachRouteList} from "./route_hover"
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
import {CasingKind, mapColors} from "./theme"

const LAYER_NAME = "route-lines"
const EMPHASIS_LAYER_NAME = "route-lines-emphasis"
const CASING_LAYER_NAME = "route-lines-casing"
const EMPHASIS_CASING_LAYER_NAME = "route-lines-emphasis-casing"
const LINE_WIDTH_PIXELS = 2
const LINE_OPACITY = 0.6
const LINE_OPACITY_DIMMED = 0.2
const EMPHASIS_WIDTH_PIXELS = 5
const EMPHASIS_OPACITY = 1
// A casing is as much wider than its line as it shows on both sides.
const CASING_WIDTH_EXTRA_PIXELS = 3
const lineLayout = {"line-cap": "round", "line-join": "round"}
// The layers of every line, with a casing, and of the emphasized line.
const lineLayerNames = [CASING_LAYER_NAME, LAYER_NAME]
const emphasisLayerNames = [EMPHASIS_CASING_LAYER_NAME, EMPHASIS_LAYER_NAME]

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

// The layers of `layerNames` that the style holds: a casing is drawn in
// one theme only.
function presentLayerNames(map, layerNames) {
  return layerNames.filter((layerName) => map.getLayer(layerName) !== undefined)
}

// Draws the line of `routeId` emphasized and every other line dimmed, or
// every line as it is without emphasis for null, and announces the route on
// the window so the vehicle markers dim the other routes' vehicles. It sets
// a filter and paint and leaves the source as it is.
function emphasizeRoute(map, routeId) {
  window.dispatchEvent(new CustomEvent(EMPHASIS_EVENT_NAME, {detail: {routeId}}))

  const emphasisLayers = presentLayerNames(map, emphasisLayerNames)
  const lineLayers = presentLayerNames(map, lineLayerNames)

  if (routeId === null) {
    for (const layerName of emphasisLayers) {
      map.setLayoutProperty(layerName, "visibility", "none")
    }

    for (const layerName of lineLayers) {
      map.setPaintProperty(layerName, "line-opacity", LINE_OPACITY)
    }
  } else {
    for (const layerName of emphasisLayers) {
      map.setFilter(layerName, ["==", ["get", "routeId"], routeId])
      map.setLayoutProperty(layerName, "visibility", "visible")
    }

    for (const layerName of lineLayers) {
      map.setPaintProperty(layerName, "line-opacity", LINE_OPACITY_DIMMED)
    }
  }
}

// A layer of the route lines in `color`, an expression, `widthPixels` wide.
function lineLayer({id, color, widthPixels, opacity, layout, filterProperties: layerFilter}) {
  return {
    id,
    type: "line",
    source: SOURCE_NAME,
    "source-layer": ROUTE_LAYER_NAME,
    ...layerFilter,
    layout,
    paint: {"line-color": color, "line-width": widthPixels, "line-opacity": opacity}
  }
}

// Adds the layer of every line and the layer of the emphasized one, each
// over its casing where `casing` gives the lines one, with the routes the
// page's filter keeps.
function addLineLayers(map, casing) {
  const keptFilter = filterProperties(routeFilter())
  const hiddenLayout = {...lineLayout, visibility: "none"}
  const routeColor = ["get", "color"]

  if (casing.kind === CasingKind.casing) {
    addLayerUnderSymbols(map, lineLayer({
      id: CASING_LAYER_NAME,
      color: casing.color,
      widthPixels: LINE_WIDTH_PIXELS + CASING_WIDTH_EXTRA_PIXELS,
      opacity: LINE_OPACITY,
      layout: lineLayout,
      filterProperties: keptFilter
    }))
  }

  addLayerUnderSymbols(map, lineLayer({
    id: LAYER_NAME,
    color: routeColor,
    widthPixels: LINE_WIDTH_PIXELS,
    opacity: LINE_OPACITY,
    layout: lineLayout,
    filterProperties: keptFilter
  }))

  // The same lines again, above the layers of every line, of which a filter
  // shows the one route that is emphasized.
  if (casing.kind === CasingKind.casing) {
    addLayerUnderSymbols(map, lineLayer({
      id: EMPHASIS_CASING_LAYER_NAME,
      color: casing.color,
      widthPixels: EMPHASIS_WIDTH_PIXELS + CASING_WIDTH_EXTRA_PIXELS,
      opacity: EMPHASIS_OPACITY,
      layout: hiddenLayout,
      filterProperties: {}
    }))
  }

  addLayerUnderSymbols(map, lineLayer({
    id: EMPHASIS_LAYER_NAME,
    color: routeColor,
    widthPixels: EMPHASIS_WIDTH_PIXELS,
    opacity: EMPHASIS_OPACITY,
    layout: hiddenLayout,
    filterProperties: {}
  }))
}

// The hook of the element beside the map. It draws the routes layer of the
// route and stop tile archive on each map the basemap announces, so a map
// drawn anew for another archive shows them too, draws them again in the
// theme of a map whose style is set anew, and keeps the lines to the routes
// the page's filter keeps.
export const RouteLines = {
  mounted() {
    this.map = null
    this.maplibre = null
    this.attached = false
    this.hoverAttached = false

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.attached = false
      this.hoverAttached = false
      // The list of the map left behind can no longer clear its emphasis.
      window.dispatchEvent(new CustomEvent(EMPHASIS_EVENT_NAME, {detail: {routeId: null}}))
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
        const layerFilter = routeFilter()

        for (const layerName of presentLayerNames(this.map, lineLayerNames)) {
          setLayerFilter({map: this.map, layerName, layerFilter})
        }
      } else {
        this.attach()
      }
    }

    // A style set anew holds none of the layers, nor the source.
    this.onRestyled = (event) => {
      if (event.detail.map === this.map) {
        this.attached = false
        this.attach()
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
  },

  // Adds the layers, once the page has an archive to draw them from, and
  // the list of the routes under the pointer, once for each map.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    const colors = mapColors(currentTheme())
    addLineLayers(map, colors.routeCasing)

    if (!this.hoverAttached) {
      attachRouteList({
        map,
        maplibre: this.maplibre,
        layerName: LAYER_NAME,
        emphasize: (routeId) => { emphasizeRoute(map, routeId) },
        routeDrawn: routeKept
      })
      this.hoverAttached = true
    }

    this.attached = true
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.dispatchEvent(new CustomEvent(EMPHASIS_EVENT_NAME, {detail: {routeId: null}}))
  }
}
