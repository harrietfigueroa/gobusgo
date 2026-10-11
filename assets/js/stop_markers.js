import {readyEventName} from "./basemap"

const sourceName = "stop-markers"
// The layer a stop's marker is drawn in.
export const markerLayerName = "stop-markers"
// The zoom from which a street's stops stand apart; below it the stops of a
// region cover its routes.
const zoomMin = 14
const markerRadiusPixels = 7
const markerColor = "#ffffff"
const markerStrokeColor = "#334155"
const markerStrokeWidthPixels = 2
const labelLayerName = "stop-markers-label"
const labelFont = ["Noto Sans Medium"]
const labelTextSizePixels = 11
const labelTextOffsetEms = [0, 1]
const labelTextWidthEmsMax = 12
const labelTextColor = "#334155"
const labelHaloColor = "#ffffff"
const labelHaloWidthPixels = 1.5
// A stop many routes serve names the first of them and counts the rest, so
// its routes stay on one line of the label.
const labelRouteCountMax = 4
const labelRouteSeparator = " "
const labelPartSeparator = " \u00b7 "
const hasLabel = ["!=", ["get", "label"], ""]
// The zoom from which a screen holds few enough stops that their popups
// stand apart.
const autoOpenZoomMin = 16
// The most stops on screen whose popups open by themselves, which is the
// most stops the server keeps open for one page.
const autoOpenStopCountMax = 5
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

// The routes a stop's label names: the first of them, and the count of the
// rest.
function labelRoutes(routes) {
  if (routes.length > labelRouteCountMax) {
    const shown = routes.slice(0, labelRouteCountMax).join(labelRouteSeparator)
    return `${shown} +${routes.length - labelRouteCountMax}`
  } else {
    return routes.join(labelRouteSeparator)
  }
}

// What a stop shows beside its marker while its popup is closed: its routes
// on one line, and its direction and the agencies of its routes on the
// next. A stop with none of them has an empty label.
export function labelText({routes, direction, agencies}) {
  const details = []

  if (typeof direction === "string" && direction !== "") {
    details.push(direction)
  }

  if (agencies.length > 0) {
    details.push(agencies.join(routeSeparator))
  }

  const lines = []

  if (routes.length > 0) {
    lines.push(labelRoutes(routes))
  }

  if (details.length > 0) {
    lines.push(details.join(labelPartSeparator))
  }

  return lines.join("\n")
}

// The identifiers of the stops inside `bounds`, the bounds of a map's view.
export function stopIdsWithin({stopsById, bounds}) {
  const stopIds = []

  for (const stop of stopsById.values()) {
    if (bounds.contains([stop.lon, stop.lat])) {
      stopIds.push(stop.id)
    }
  }

  return stopIds
}

// The stops whose popups are open by themselves in a view at `zoom` that
// shows the stops of `visibleStopIds`: all of them in a view zoomed in
// close that shows few, and none in any other view.
export function autoOpenStopIds({zoom, visibleStopIds}) {
  if (zoom >= autoOpenZoomMin && visibleStopIds.length <= autoOpenStopCountMax) {
    return visibleStopIds
  } else {
    return []
  }
}

// Every stop as one GeoJSON collection, a point per stop with the texts its
// label and its popup show. A feature's properties hold no list, so the
// routes are one text and the agencies another.
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
        routes: stop.routes.join(routeSeparator),
        agencies: stop.agencies.join(routeSeparator),
        label: labelText(stop)
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
    `Routes: ${suppliedText(properties.routes)}`,
    `Agencies: ${suppliedText(properties.agencies)}`
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
    this.maplibre = null
    // The popup that is open for each stop, with the element its arrivals
    // are written into and whether it opened by itself.
    this.openPopups = new Map()
    // The stops on screen whose popup the rider closed after it opened by
    // itself; such a popup stays closed until its stop leaves the screen.
    this.dismissedStopIds = new Set()
    this.zoom = null

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.maplibre = null
      this.zoom = null
      this.dismissedStopIds.clear()

      // A popup belongs to the map it was opened on.
      this.closePopups([...this.openPopups.keys()])

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
  // `auto` says the popup opens by itself, for a view that shows few stops;
  // such a popup stays through a click on the map, which closes a popup the
  // rider opened, and leaves the keyboard's focus where the rider has it.
  openPopup({stop, auto}) {
    const stopId = stop.id
    const content = popupContent({
      name: stop.name,
      code: stop.code,
      direction: stop.direction,
      routes: stop.routes.join(routeSeparator),
      agencies: stop.agencies.join(routeSeparator)
    })
    const arrivalsElement = document.createElement("div")
    writeArrivals(arrivalsElement, {status: "waiting"})
    content.appendChild(arrivalsElement)

    const byRider = auto === false
    const popup = new this.maplibre.Popup({closeOnClick: byRider, focusAfterOpen: byRider})
      .setLngLat([stop.lon, stop.lat])
      .setDOMContent(content)
    const open = {popup, arrivalsElement, auto, closedByRider: true}

    // A popup opened anew for a stop takes the stop's place before the
    // earlier one closes, and the earlier one's closing then changes
    // nothing.
    popup.on("close", () => {
      if (this.openPopups.get(stopId) === open) {
        this.openPopups.delete(stopId)
        this.pushEvent("stop-arrivals:close", {stop_id: stopId})

        if (open.auto && open.closedByRider) {
          this.dismissedStopIds.add(stopId)
        }
      }
    })

    this.openPopups.set(stopId, open)
    popup.addTo(this.map)
    this.pushEvent("stop-arrivals:open", {stop_id: stopId})
  },

  // Closes the popups of the stops of `stopIds` as the hook's own doing,
  // which dismisses none of them.
  closePopups(stopIds) {
    for (const stopId of stopIds) {
      const open = this.openPopups.get(stopId)

      if (open !== undefined) {
        open.closedByRider = false
        open.popup.remove()
      }
    }
  },

  // Brings the open popups in line with the map's view: a view zoomed out
  // from, to below the zoom where popups open by themselves, closes every
  // popup, and the popups that opened by themselves are those of the stops
  // the view opens now, less the ones the rider closed.
  followView() {
    if (this.map === null) {
      return
    }

    const zoom = this.map.getZoom()
    const zoomedOut = this.zoom !== null && zoom < this.zoom
    this.zoom = zoom

    if (zoomedOut && zoom < autoOpenZoomMin) {
      this.closePopups([...this.openPopups.keys()])
    }

    // Below the zoom that draws stops, none is on screen.
    const visibleStopIds = zoom >= zoomMin
      ? stopIdsWithin({stopsById: this.stopsById, bounds: this.map.getBounds()})
      : []
    const visible = new Set(visibleStopIds)
    const autoOpen = new Set(autoOpenStopIds({zoom, visibleStopIds}))

    for (const stopId of [...this.dismissedStopIds]) {
      if (visible.has(stopId) === false) {
        this.dismissedStopIds.delete(stopId)
      }
    }

    // The closings go first, so the page never holds more stops open than
    // the server keeps for it.
    const closing = []

    for (const [stopId, open] of this.openPopups) {
      if (open.auto && autoOpen.has(stopId) === false) {
        closing.push(stopId)
      }
    }

    this.closePopups(closing)

    for (const stopId of autoOpen) {
      if (this.openPopups.has(stopId) === false && this.dismissedStopIds.has(stopId) === false) {
        this.openPopup({stop: this.stopsById.get(stopId), auto: true})
      }
    }
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

    // A label is left out where it would cover another label, so a crowded
    // street shows the labels of some of its stops.
    map.addLayer({
      id: labelLayerName,
      type: "symbol",
      source: sourceName,
      minzoom: zoomMin,
      filter: hasLabel,
      layout: {
        "text-field": ["get", "label"],
        "text-font": labelFont,
        "text-size": labelTextSizePixels,
        "text-anchor": "top",
        "text-offset": labelTextOffsetEms,
        "text-max-width": labelTextWidthEmsMax,
        "text-allow-overlap": false
      },
      paint: {
        "text-color": labelTextColor,
        "text-halo-color": labelHaloColor,
        "text-halo-width": labelHaloWidthPixels
      }
    })

    // A click on a stop whose popup opened by itself leaves that popup as
    // it is. The feature may be a stop the server has since taken away.
    map.on("click", markerLayerName, (event) => {
      const [feature] = event.features
      const stopId = feature.properties.stopId
      const stop = this.stopsById.get(stopId)
      const open = this.openPopups.get(stopId)

      if (stop !== undefined && (open === undefined || open.auto === false)) {
        this.dismissedStopIds.delete(stopId)
        this.openPopup({stop, auto: false})
      }
    })

    map.on("mouseenter", markerLayerName, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", markerLayerName, () => { map.getCanvas().style.cursor = "" })
    map.on("moveend", () => { this.followView() })

    this.map = map
    this.maplibre = maplibre
    this.followView()
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
      this.followView()
    }
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
    window.clearTimeout(this.drawTimer)
  }
}
