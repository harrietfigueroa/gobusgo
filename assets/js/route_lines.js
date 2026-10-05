import {readyEventName} from "./basemap"

const sourceName = "route-lines"
const layerName = "route-lines"
const lineWidthPixels = 2
const lineOpacity = 0.6
const coordinatePrecision = 1e5
const chunkBits = 5
const chunkMask = 0x1f
const chunkContinues = 0x20
const characterOffset = 63
const linePointCountMin = 2
const drawDelayMs = 50

// One value of an encoded polyline, read from `index`: a signed difference
// in five-bit chunks, lowest first, each chunk but the last marked as
// continued. Returns the difference and the index after it.
// https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-10-05
function decodeDifference(points, index) {
  let result = 0
  let shift = 0
  let chunk = chunkContinues

  // A string that ends inside a value reads NaN, which ends the loop.
  while (chunk >= chunkContinues) {
    chunk = points.charCodeAt(index) - characterOffset
    result |= (chunk & chunkMask) << shift
    shift += chunkBits
    index += 1
  }

  // The lowest bit carries the sign.
  const difference = (result & 1) === 1 ? ~(result >> 1) : result >> 1
  return {difference, index}
}

// The coordinates of one encoded polyline, longitude first as GeoJSON
// takes them. Each point is stored as its difference from the one before.
export function decodePolyline(points) {
  const coordinates = []
  let index = 0
  let latitude = 0
  let longitude = 0

  while (index < points.length) {
    const latitudeStep = decodeDifference(points, index)
    const longitudeStep = decodeDifference(points, latitudeStep.index)
    latitude += latitudeStep.difference
    longitude += longitudeStep.difference
    index = longitudeStep.index
    coordinates.push([longitude / coordinatePrecision, latitude / coordinatePrecision])
  }

  return coordinates
}

// Every route's line as one GeoJSON collection: a multi-line per route, of
// the pieces that have at least two points, with the color it is drawn in.
function featureCollection(linesByRoute) {
  const features = []

  for (const [routeId, {color, polylines}] of linesByRoute) {
    const pieces = polylines
      .map(decodePolyline)
      .filter((coordinates) => coordinates.length >= linePointCountMin)

    if (pieces.length > 0) {
      features.push({
        type: "Feature",
        geometry: {type: "MultiLineString", coordinates: pieces},
        properties: {routeId, color}
      })
    }
  }

  return {type: "FeatureCollection", features}
}

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

// The hook of the element beside the map. It holds every route's line as
// the server last sent it, encoded, and draws the lines on each map the
// basemap announces, so a map drawn anew for another archive shows them too.
export const RouteLines = {
  mounted() {
    this.linesByRoute = new Map()
    this.map = null
    this.drawTimer = null

    this.onBasemapReady = (event) => {
      const {map} = event.detail
      this.map = null
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => { this.attach(map) })
    }

    window.addEventListener(readyEventName, this.onBasemapReady)

    this.handleEvent("route-lines:routes", ({lines, removed}) => {
      for (const routeId of removed) {
        this.linesByRoute.delete(routeId)
      }

      for (const {id, color, polylines} of lines) {
        this.linesByRoute.set(id, {color, polylines})
      }

      this.scheduleDraw()
    })

    this.pushEvent("route-lines:ready", {})
  },

  attach(map) {
    map.addSource(sourceName, {type: "geojson", data: featureCollection(this.linesByRoute)})

    map.addLayer({
      id: layerName,
      type: "line",
      source: sourceName,
      layout: {"line-cap": "round", "line-join": "round"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": lineWidthPixels,
        "line-opacity": lineOpacity
      }
    }, firstSymbolLayerName(map))

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
      this.map.getSource(sourceName).setData(featureCollection(this.linesByRoute))
    }
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
    window.clearTimeout(this.drawTimer)
  }
}
