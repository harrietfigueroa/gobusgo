import {readyEventName} from "./basemap"

const sourceName = "stop-markers"
const layerName = "stop-markers"
// The zoom from which a street's stops stand apart; below it the stops of a
// region cover its routes.
const zoomMin = 14
const markerRadiusPixels = 4
const markerColor = "#ffffff"
const markerStrokeColor = "#334155"
const markerStrokeWidthPixels = 1.5
const routeSeparator = ", "
const notSupplied = "Not supplied"
const drawDelayMs = 50

// Every stop as one GeoJSON collection, a point per stop with the texts its
// popup shows. A feature's properties hold no list, so the routes are one
// text.
function featureCollection(stopsById) {
  const features = []

  for (const stop of stopsById.values()) {
    features.push({
      type: "Feature",
      geometry: {type: "Point", coordinates: [stop.lon, stop.lat]},
      properties: {
        stopId: stop.id,
        name: stop.name,
        code: stop.code,
        direction: stop.direction,
        routes: stop.routes.join(routeSeparator)
      }
    })
  }

  return {type: "FeatureCollection", features}
}

function suppliedText(value) {
  if (typeof value === "string" && value !== "") {
    return value
  } else {
    return notSupplied
  }
}

// A popup's content is built as text nodes: a stop's texts come from
// outside the application and are never parsed as HTML.
function popupContent(properties) {
  const lines = [
    properties.name,
    `Stop code: ${suppliedText(properties.code)}`,
    `Direction: ${suppliedText(properties.direction)}`,
    `Routes: ${suppliedText(properties.routes)}`
  ]
  const content = document.createElement("div")

  for (const line of lines) {
    const paragraph = document.createElement("p")
    paragraph.textContent = line
    content.appendChild(paragraph)
  }

  return content
}

// The hook of the element beside the map. It holds every stop as the server
// last sent it and draws the stops on each map the basemap announces, so a
// map drawn anew for another archive shows them too. Its element stands
// before the vehicle markers' element, so its layer is added first and the
// vehicles are drawn over the stops.
export const StopMarkers = {
  mounted() {
    this.stopsById = new Map()
    this.map = null
    this.drawTimer = null

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => { this.attach(map, maplibre) })
    }

    window.addEventListener(readyEventName, this.onBasemapReady)

    this.handleEvent("stop-markers:stops", ({stops, removed, reset}) => {
      if (reset) {
        this.stopsById.clear()
      }

      for (const stopId of removed) {
        this.stopsById.delete(stopId)
      }

      for (const stop of stops) {
        this.stopsById.set(stop.id, stop)
      }

      this.scheduleDraw()
    })

    this.pushEvent("stop-markers:ready", {})
  },

  // The page that connects again knows nothing of what this hook holds, and
  // answers with every stop after a reset.
  reconnected() {
    this.pushEvent("stop-markers:ready", {})
  },

  attach(map, maplibre) {
    map.addSource(sourceName, {type: "geojson", data: featureCollection(this.stopsById)})

    map.addLayer({
      id: layerName,
      type: "circle",
      source: sourceName,
      minzoom: zoomMin,
      paint: {
        "circle-radius": markerRadiusPixels,
        "circle-color": markerColor,
        "circle-stroke-color": markerStrokeColor,
        "circle-stroke-width": markerStrokeWidthPixels
      }
    })

    map.on("click", layerName, (event) => {
      const [feature] = event.features

      new maplibre.Popup()
        .setLngLat(feature.geometry.coordinates)
        .setDOMContent(popupContent(feature.properties))
        .addTo(map)
    })

    map.on("mouseenter", layerName, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", layerName, () => { map.getCanvas().style.cursor = "" })

    this.map = map
  },

  // Several events arrive in a row when a page opens; one draw covers them.
  scheduleDraw() {
    if (this.drawTimer === null) {
      this.drawTimer = window.setTimeout(() => {
        this.drawTimer = null
        this.draw()
      }, drawDelayMs)
    }
  },

  draw() {
    if (this.map !== null) {
      this.map.getSource(sourceName).setData(featureCollection(this.stopsById))
    }
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
    window.clearTimeout(this.drawTimer)
  }
}
