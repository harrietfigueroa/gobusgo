import {readyEventName} from "./basemap"
import {placePopups} from "./popup_placement"
import {
  announceRiderPopupChange,
  riderPopupBoxes,
  riderPopupChangeEventName,
  riderPopupClassName
} from "./rider_popups"
import {alertLines} from "./service_alerts"
import {
  addSource,
  changeEventName,
  filterProperties,
  sourceName,
  stopFilter,
  stopLayerName
} from "./route_stop_tiles"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"

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
const hasLabel = ["!=", ["get", "label"], ""]
// The zoom from which a screen holds few enough stops that their popups
// stand apart.
const autoOpenZoomMin = 16
// The most stops on screen whose popups open by themselves, which is the
// most stops the server keeps open for one page.
const autoOpenStopCountMax = 5
// The room between two popups, and between a popup and a rider's.
const popupGapPixels = 4
// MapLibre names the edge of a popup that touches its point, which is the
// edge across from the side of the point the popup stands on.
const anchorBySide = {above: "bottom", below: "top", left: "right", right: "left"}
// The side a popup stands on while it is only measured.
const measuredSide = "above"
const notSupplied = "Not supplied"
const titleClassName = "popup-title"
const arrivalsHeading = "Arrivals"
const arrivalsWaiting = "Waiting for this stop's arrivals"
const arrivalsNone = "No arrivals soon"
const arrivalsRefused = "No arrivals for this stop"
const arrivalsBusy = "Too many stops open; close one to see this stop's arrivals"
const arrivalNow = "now"
const arrivalScheduledNote = " (scheduled)"
const arrivalUnnamed = "Arrival"

// A stop as its feature in the tile archive holds it: its position, and the
// texts its popup shows, the routes and the agencies each one text. A text
// the source does not supply is absent from the feature. The feature holds
// its routes' identifiers with a comma before, between, and after them.
function stopFromFeature({geometry, properties}) {
  const [lon, lat] = geometry.coordinates

  return {
    id: properties.stopId,
    lon,
    lat,
    name: properties.name,
    code: properties.code,
    direction: properties.direction,
    routes: properties.routes,
    agencies: properties.agencies,
    routeIds: (properties.routeIds ?? "").split(",").filter((routeId) => routeId !== "")
  }
}

// The stops drawn in the view of `map`, by identifier. A stop near a tile's
// edge is returned by each tile that holds it, and comes out once here.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#queryrenderedfeatures — checked 2026-10-14
function renderedStops(map) {
  const stopsById = new Map()

  for (const feature of map.queryRenderedFeatures({layers: [markerLayerName]})) {
    stopsById.set(feature.properties.stopId, stopFromFeature(feature))
  }

  return stopsById
}

// The first marker layer of the vehicles in the style, which the stops go
// under, or undefined while the vehicles have none.
function firstVehicleLayerName(map) {
  return vehicleMarkerLayerNames.find((layerName) => map.getLayer(layerName) !== undefined)
}

// The filter of the label layer: a stop with a label, of the kept routes.
function labelFilter() {
  const kept = stopFilter()

  if (kept === null) {
    return hasLabel
  } else {
    return ["all", hasLabel, kept]
  }
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

function suppliedText(value) {
  if (typeof value === "string" && value !== "") {
    return value
  } else {
    return notSupplied
  }
}

// A popup's content is built as text nodes: a stop's texts come from
// outside the application and are never parsed as HTML. The current alerts
// of the stop's routes, those of a route as a whole and those that name the
// stop, stand under its texts.
function popupContent(stop) {
  const lines = [
    stop.name,
    `Stop code: ${suppliedText(stop.code)}`,
    `Direction: ${suppliedText(stop.direction)}`,
    `Routes: ${suppliedText(stop.routes)}`,
    `Agencies: ${suppliedText(stop.agencies)}`
  ]
  const content = document.createElement("div")

  for (const line of lines) {
    appendParagraph(content, line)
  }

  content.append(...alertLines({routeIds: stop.routeIds, stopId: stop.id}))
  content.firstElementChild.className = titleClassName
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

// A popup's content with the element its stop's arrivals are written into,
// which says that it is waiting for them.
function popupElements(stop) {
  const content = popupContent(stop)
  const arrivalsElement = document.createElement("div")
  writeArrivals(arrivalsElement, {status: "waiting"})
  content.appendChild(arrivalsElement)

  return {content, arrivalsElement}
}

// The options of a stop's popup. One that opens by itself stands on the
// side it is given, stays through a click on the map, and leaves the
// keyboard's focus where the rider has it. One the rider opens is placed by
// MapLibre and closes on a click on the map.
function popupOptions({auto, side}) {
  if (auto) {
    return {anchor: anchorBySide[side], closeOnClick: false, focusAfterOpen: false}
  } else {
    return {className: riderPopupClassName, closeOnClick: true, focusAfterOpen: true}
  }
}

// The size of the box MapLibre draws around `content`, the content of a
// popup that is on a map.
function contentBoxSize(content) {
  const {width, height} = content.parentElement.getBoundingClientRect()
  return {width, height}
}

function largerSize(size, other) {
  return {width: Math.max(size.width, other.width), height: Math.max(size.height, other.height)}
}

// The hook of the element beside the map. It draws the stops layer of the
// route and stop tile archive on each map the basemap announces, so a map
// drawn anew for another archive shows them too, and keeps the stops to
// those of the routes the page's filter keeps. Its layers go under the
// vehicle markers' layers.
export const StopMarkers = {
  mounted() {
    // The stops drawn in the view as the map last came to rest.
    this.stopsById = new Map()
    this.map = null
    this.maplibre = null
    this.attached = false
    this.followTimer = null
    // The popup that is open for each stop, with its content, the element
    // its arrivals are written into, whether it opened by itself, and the
    // side of its stop it then stands on.
    this.openPopups = new Map()
    // The stops on screen whose popup the rider closed after it opened by
    // itself; such a popup stays closed until its stop leaves the screen.
    this.dismissedStopIds = new Set()
    // The largest size the popup of each stop on screen has had, which is
    // the room its stop is given. A popup grows when its arrivals come, and
    // a stop left closed for lack of that room stays closed while its popup
    // would open small and close again.
    this.popupSizes = new Map()
    this.tipLength = null
    this.zoom = null

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.maplibre = null
      this.attached = false
      this.zoom = null
      this.tipLength = null
      this.stopsById.clear()
      this.dismissedStopIds.clear()
      this.popupSizes.clear()

      // A popup belongs to the map it was opened on.
      this.closePopups([...this.openPopups.keys()])

      // The map takes sources and layers once its style has loaded.
      map.once("load", () => {
        this.map = map
        this.maplibre = maplibre
        map.on("idle", () => { this.followView() })
        this.attach()
      })
    }

    this.onChange = () => {
      if (this.map === null) {
        return
      } else if (this.attached) {
        this.map.setFilter(markerLayerName, stopFilter())
        this.map.setFilter(labelLayerName, labelFilter())
      } else {
        this.attach()
      }
    }

    this.onRiderPopupChange = () => { this.scheduleFollow() }

    window.addEventListener(readyEventName, this.onBasemapReady)
    window.addEventListener(changeEventName, this.onChange)
    window.addEventListener(riderPopupChangeEventName, this.onRiderPopupChange)

    // Arrivals of a stop whose popup has closed are dropped.
    this.handleEvent("stop-arrivals:arrivals", (shown) => {
      const open = this.openPopups.get(shown.stop_id)

      if (open !== undefined) {
        writeArrivals(open.arrivalsElement, shown)
        // The popup has another size with these lines.
        this.scheduleFollow()
      }
    })
  },

  // The page that connects again knows nothing of the stops this hook has
  // open, and is told them again.
  reconnected() {
    for (const stopId of this.openPopups.keys()) {
      this.pushEvent("stop-arrivals:open", {stop_id: stopId})
    }
  },

  // Opens a stop's popup and tells the page, which answers with the stop's
  // arrivals and sends them again whenever they change, until the popup
  // closes.
  // `auto` says the popup opens by itself, for a view that shows few stops,
  // and `side` is then the side of its stop it stands on; a popup the rider
  // opens has a null `side`.
  openPopup({stop, auto, side}) {
    const {content, arrivalsElement} = popupElements(stop)
    const open = {popup: null, content, arrivalsElement, auto, side, closedByRider: true}

    this.openPopups.set(stop.id, open)
    this.showPopup({stop, open})
    this.pushEvent("stop-arrivals:open", {stop_id: stop.id})

    if (auto === false) {
      announceRiderPopupChange()
    }
  },

  // Puts the popup of `open` on the map, on the side `open` names.
  showPopup({stop, open}) {
    const stopId = stop.id
    const popup = new this.maplibre.Popup(popupOptions(open))
      .setLngLat([stop.lon, stop.lat])
      .setDOMContent(open.content)

    // A popup opened anew for a stop, or put on another side of it, takes
    // the stop's place before the earlier one closes, and the earlier one's
    // closing then changes nothing.
    popup.on("close", () => {
      if (this.openPopups.get(stopId) === open && open.popup === popup) {
        this.openPopups.delete(stopId)
        this.pushEvent("stop-arrivals:close", {stop_id: stopId})

        if (open.auto) {
          if (open.closedByRider) {
            this.dismissedStopIds.add(stopId)
          }
        } else {
          announceRiderPopupChange()
        }
      }
    })

    open.popup = popup
    popup.addTo(this.map)
  },

  // Puts an open popup on another side of its stop. The stop stays open
  // for the page, and the popup keeps its content.
  movePopup({stop, open, side}) {
    const earlier = open.popup
    open.side = side
    this.showPopup({stop, open})
    earlier.remove()
  },

  // The size of the content box of a stop's popup and the length of a
  // popup's tip, read from a popup that is on the map only while it is
  // measured and that the page is told nothing of.
  measuredPopup(stop) {
    const {content} = popupElements(stop)
    const popup = new this.maplibre.Popup(popupOptions({auto: true, side: measuredSide}))
      .setLngLat([stop.lon, stop.lat])
      .setDOMContent(content)
      .addTo(this.map)
    const size = contentBoxSize(content)
    const tipLength = popup.getElement().getBoundingClientRect().height - size.height

    popup.remove()
    return {size, tipLength}
  },

  // The room a stop's popup is given: the largest size it has had since its
  // stop came on screen.
  popupSize(stop) {
    const open = this.openPopups.get(stop.id)
    const kept = this.popupSizes.get(stop.id)
    let size

    if (open !== undefined) {
      const shown = contentBoxSize(open.content)
      size = kept === undefined ? shown : largerSize(shown, kept)
    } else if (kept !== undefined) {
      size = kept
    } else {
      const measured = this.measuredPopup(stop)
      size = measured.size
      this.tipLength = measured.tipLength
    }

    this.popupSizes.set(stop.id, size)
    return size
  },

  // The side of its stop on which the popup of each stop of `stopIds`
  // stands, so that no two of them cross and none crosses a rider's popup.
  // A stop whose popup has no such side is left out.
  popupSides(stopIds) {
    if (stopIds.length === 0) {
      return new Map()
    }

    const popups = stopIds.map((stopId) => {
      const stop = this.stopsById.get(stopId)
      const point = this.map.project([stop.lon, stop.lat])

      // MapLibre draws a popup at a whole pixel.
      return {id: stopId, point: {x: Math.round(point.x), y: Math.round(point.y)}, size: this.popupSize(stop)}
    })
    const container = this.map.getContainer()

    if (this.tipLength === null) {
      throw new Error("a popup's size is known before the length of a popup's tip")
    }

    return placePopups({
      popups,
      obstacles: riderPopupBoxes(this.map),
      view: {width: container.clientWidth, height: container.clientHeight},
      tipLength: this.tipLength,
      gapPixels: popupGapPixels
    })
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
  // the view opens now, less the ones the rider closed, the ones the rider
  // opened, and the ones with no side of their stop to stand on.
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
    this.stopsById = this.attached && zoom >= zoomMin ? renderedStops(this.map) : new Map()
    const visibleStopIds = [...this.stopsById.keys()]
    const visible = new Set(visibleStopIds)

    for (const stopId of [...this.dismissedStopIds]) {
      if (visible.has(stopId) === false) {
        this.dismissedStopIds.delete(stopId)
      }
    }

    for (const stopId of [...this.popupSizes.keys()]) {
      if (visible.has(stopId) === false) {
        this.popupSizes.delete(stopId)
      }
    }

    const wanted = autoOpenStopIds({zoom, visibleStopIds}).filter((stopId) => this.opensByItself(stopId))
    const sidesByStop = this.popupSides(wanted)

    // The closings go first, so the page never holds more stops open than
    // the server keeps for it.
    const closing = []

    for (const [stopId, open] of this.openPopups) {
      if (open.auto && sidesByStop.has(stopId) === false) {
        closing.push(stopId)
      }
    }

    this.closePopups(closing)

    for (const [stopId, side] of sidesByStop) {
      const stop = this.stopsById.get(stopId)
      const open = this.openPopups.get(stopId)

      if (open === undefined) {
        this.openPopup({stop, auto: true, side})
      } else if (open.side !== side) {
        this.movePopup({stop, open, side})
      }
    }
  },

  // Whether a stop the view opens gets a popup that opens by itself: one
  // whose popup the rider neither closed nor opened.
  opensByItself(stopId) {
    const open = this.openPopups.get(stopId)
    const openedByRider = open !== undefined && open.auto === false

    return this.dismissedStopIds.has(stopId) === false && openedByRider === false
  },

  // Follows the view once the events that are being handled are done, so a
  // popup that closes inside `followView` starts no second run inside it.
  scheduleFollow() {
    if (this.followTimer === null) {
      this.followTimer = window.setTimeout(() => {
        this.followTimer = null
        this.followView()
      }, 0)
    }
  },

  // Adds the layers, once the page has an archive to draw them from.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    map.addLayer({
      id: markerLayerName,
      type: "circle",
      source: sourceName,
      "source-layer": stopLayerName,
      minzoom: zoomMin,
      ...filterProperties(stopFilter()),
      paint: {
        "circle-radius": markerRadiusPixels,
        "circle-color": markerColor,
        "circle-stroke-color": markerStrokeColor,
        "circle-stroke-width": markerStrokeWidthPixels
      }
    }, firstVehicleLayerName(map))

    // A label is left out where it would cover another label, so a crowded
    // street shows the labels of some of its stops.
    map.addLayer({
      id: labelLayerName,
      type: "symbol",
      source: sourceName,
      "source-layer": stopLayerName,
      minzoom: zoomMin,
      filter: labelFilter(),
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
    }, firstVehicleLayerName(map))

    // A click on a stop whose popup opened by itself leaves that popup as
    // it is.
    map.on("click", markerLayerName, (event) => {
      const stop = stopFromFeature(event.features[0])
      const stopId = stop.id
      const open = this.openPopups.get(stopId)

      if (open === undefined || open.auto === false) {
        this.dismissedStopIds.delete(stopId)
        this.openPopup({stop, auto: false, side: null})
      }
    })

    map.on("mouseenter", markerLayerName, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", markerLayerName, () => { map.getCanvas().style.cursor = "" })

    this.attached = true
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
    window.removeEventListener(changeEventName, this.onChange)
    window.removeEventListener(riderPopupChangeEventName, this.onRiderPopupChange)
    window.clearTimeout(this.followTimer)
  }
}
