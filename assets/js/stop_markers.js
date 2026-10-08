import {readyEventName} from "./basemap"

const sourceName = "stop-markers"
// The layer a stop's marker is drawn in.
export const markerLayerName = "stop-markers"
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
const arrivalsHeading = "Arrivals"
const arrivalsWaiting = "Waiting for this stop's arrivals"
const arrivalsNone = "No arrivals soon"
const arrivalsRefused = "No arrivals for this stop"
const arrivalsBusy = "Too many stops open; close one to see this stop's arrivals"
const arrivalNow = "now"
const arrivalScheduledNote = " (scheduled)"
const arrivalUnnamed = "Arrival"

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
    appendParagraph(content, line)
  }

  return content
}

function appendParagraph(element, text) {
  const paragraph = document.createElement("p")
  paragraph.textContent = text
  element.appendChild(paragraph)
}

// One arrival as a line: where it goes, and how soon. A time that is the
// schedule and no prediction says so.
function arrivalText({route, headsign, minutes, predicted}) {
  const names = []

  if (typeof route === "string") {
    names.push(route)
  }

  if (typeof headsign === "string") {
    names.push(`to ${headsign}`)
  }

  const name = names.length === 0 ? arrivalUnnamed : names.join(" ")
  const time = minutes === 0 ? arrivalNow : `${minutes} min`
  const note = predicted ? "" : arrivalScheduledNote

  return `${name}: ${time}${note}`
}

// The heading of a stop's arrivals, with the age of the fetch they come
// from once it is a minute old.
function arrivalsHeadingText(ageMinutes) {
  if (ageMinutes >= 1) {
    return `${arrivalsHeading} (as of ${ageMinutes} min ago)`
  } else {
    return arrivalsHeading
  }
}

// The lines a popup shows for what the server says of its stop's arrivals.
function arrivalsLines({status, age_minutes: ageMinutes, arrivals}) {
  switch (status) {
    case "waiting":
      return [arrivalsWaiting]
    case "refused":
      return [arrivalsRefused]
    case "busy":
      return [arrivalsBusy]
    case "arrivals":
      if (arrivals.length === 0) {
        return [arrivalsHeadingText(ageMinutes), arrivalsNone]
      } else {
        return [arrivalsHeadingText(ageMinutes), ...arrivals.map(arrivalText)]
      }
    default:
      throw new Error(`unknown arrivals status: ${status}`)
  }
}

// Writes a stop's arrivals into its popup as text nodes: the names come
// from outside the application and are never parsed as HTML.
function writeArrivals(element, shown) {
  element.replaceChildren()

  for (const line of arrivalsLines(shown)) {
    appendParagraph(element, line)
  }
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
    // The popup that is open for each stop, with the element its arrivals
    // are written into.
    this.openPopups = new Map()

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null

      // A popup belongs to the map it was opened on.
      for (const {popup} of [...this.openPopups.values()]) {
        popup.remove()
      }

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

    // Arrivals of a stop whose popup has closed are dropped.
    this.handleEvent("stop-arrivals:arrivals", (shown) => {
      const open = this.openPopups.get(shown.stop_id)

      if (open !== undefined) {
        writeArrivals(open.arrivalsElement, shown)
      }
    })

    this.pushEvent("stop-markers:ready", {})
  },

  // The page that connects again knows nothing of what this hook holds: it
  // answers with every stop after a reset, and is told again which stops
  // are open.
  reconnected() {
    this.pushEvent("stop-markers:ready", {})

    for (const stopId of this.openPopups.keys()) {
      this.pushEvent("stop-arrivals:open", {stop_id: stopId})
    }
  },

  // Opens a stop's popup and tells the page, which answers with the stop's
  // arrivals and sends them again whenever they change, until the popup
  // closes.
  openPopup(map, maplibre, feature) {
    const stopId = feature.properties.stopId
    const content = popupContent(feature.properties)
    const arrivalsElement = document.createElement("div")
    writeArrivals(arrivalsElement, {status: "waiting"})
    content.appendChild(arrivalsElement)

    const popup = new maplibre.Popup()
      .setLngLat(feature.geometry.coordinates)
      .setDOMContent(content)
    const open = {popup, arrivalsElement}

    // A popup opened anew for a stop takes the stop's place before the
    // earlier one closes, and the earlier one's closing then changes
    // nothing.
    popup.on("close", () => {
      if (this.openPopups.get(stopId) === open) {
        this.openPopups.delete(stopId)
        this.pushEvent("stop-arrivals:close", {stop_id: stopId})
      }
    })

    this.openPopups.set(stopId, open)
    popup.addTo(map)
    this.pushEvent("stop-arrivals:open", {stop_id: stopId})
  },

  attach(map, maplibre) {
    map.addSource(sourceName, {type: "geojson", data: featureCollection(this.stopsById)})

    map.addLayer({
      id: markerLayerName,
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

    map.on("click", markerLayerName, (event) => {
      const [feature] = event.features
      this.openPopup(map, maplibre, feature)
    })

    map.on("mouseenter", markerLayerName, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", markerLayerName, () => { map.getCanvas().style.cursor = "" })

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
