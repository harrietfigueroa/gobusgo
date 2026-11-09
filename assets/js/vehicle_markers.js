import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {currentTheme} from "./color_theme"
import {glidePosition, glides} from "./marker_glide"
import {announceRiderPopupChange, RIDER_POPUP_CLASS_NAME} from "./rider_popups"
import {compactPopupContent} from "./route_chips"
import {alertLines} from "./service_alerts"
import {mapColors} from "./theme"
import {
  CHANGE_EVENT_NAME as DETAIL_CHANGE_EVENT_NAME,
  DetailKind,
  showDetail,
  showsDetail,
  updateDetail
} from "./panel_detail"
import {revealOnMap} from "./panel_sheet"
import {pageEvents} from "./page_events"

const SOURCE_NAME = "vehicle-markers"
const ROUND_LAYER_NAME = "vehicle-markers-round"
const POINTED_LAYER_NAME = "vehicle-markers-pointed"

// The layers a vehicle's marker is drawn in, round or pointed.
export const markerLayerNames = [ROUND_LAYER_NAME, POINTED_LAYER_NAME]
const ROUTE_LAYER_NAME = "vehicle-markers-route"
const routeFont = ["Noto Sans Medium"]
const ROUTE_TEXT_SIZE_PIXELS = 11
const routeTextOffsetEms = [0, 1]
const ROUTE_HALO_WIDTH_PIXELS = 1.5
const POINTED_IMAGE_PREFIX = "vehicle-marker-pointed-"
const POINTED_IMAGE_SIZE_PIXELS = 28
const POINTED_IMAGE_PIXEL_RATIO = 2
const POINTED_TIP_INSET_PIXELS = 2
const HALVING_DIVISOR = 2
const MARKER_RADIUS_PIXELS = 6
const MARKER_STROKE_WIDTH_PIXELS = 1.5
const STATUS_OPACITY_FALLBACK = 1
const POSITION_NOTE = "Marker position: the source's estimate"
const NOT_SUPPLIED = "Not supplied"
const FACTS_CLASS_NAME = "panel-detail-facts"
const ALERTS_CLASS_NAME = "panel-detail-alerts"
// The class of the popup of the vehicle the details view shows.
const SELECTED_POPUP_CLASS_NAME = "popup-selected"
const hasHeading = ["==", ["typeof", ["get", "heading"]], "number"]
const hasRoute = ["==", ["typeof", ["get", "route"]], "string"]
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"

function point(coordinates) {
  return {type: "Point", coordinates}
}

// Every agency's markers as one GeoJSON collection, a point per marker with
// the texts its label and its popup show, and the glides that bring markers
// already drawn to their new positions. A marker in `drawn`, the positions
// drawn now, that glides is placed where it is drawn and glides from there;
// any other stands at its new position. `drawn` comes back as the positions
// the collection draws, so a vehicle that leaves the fetch leaves it too.
function placeMarkers({markersByAgency, drawn, startMs, reducedMotion}) {
  const features = []
  const placed = new Map()
  const gliding = new Map()

  for (const markers of markersByAgency.values()) {
    for (const marker of markers) {
      const target = [marker.lon, marker.lat]
      let position = target

      if (drawn.has(marker.id)) {
        const source = drawn.get(marker.id)

        if (glides({source, target, reducedMotion})) {
          position = source
          gliding.set(marker.id, {source, target, startMs})
        }
      }

      placed.set(marker.id, position)
      features.push({type: "Feature", geometry: point(position), properties: markerProperties(marker)})
    }
  }

  return {collection: {type: "FeatureCollection", features}, drawn: placed, gliding}
}

// The texts a marker's label, popup, and view show, as its feature holds
// them.
function markerProperties(marker) {
  return {
    markerId: marker.id,
    vehicleId: marker.vehicle_id,
    heading: marker.heading,
    color: marker.color,
    routeId: marker.route_id,
    route: marker.route,
    headsign: marker.headsign,
    schedule: marker.schedule,
    nextStop: marker.next_stop,
    status: marker.status,
    locationAge: marker.location_age,
    realTime: marker.real_time
  }
}

const MarkerLookupKind = Object.freeze({found: "found", missing: "missing"})

// The marker of `markerId` among `markers`, or missing where they do not
// hold it.
function findMarker({markers, markerId}) {
  const marker = markers.find((candidate) => candidate.id === markerId)

  if (marker === undefined) {
    return {kind: MarkerLookupKind.missing}
  } else {
    return {kind: MarkerLookupKind.found, marker}
  }
}

function statusCase({status, opacity}) {
  return [status, opacity]
}

// The paint expression that gives each marker the opacity of its status.
function statusOpacity(statuses) {
  const cases = statuses.flatMap(statusCase)
  return ["match", ["get", "status"], ...cases, STATUS_OPACITY_FALLBACK]
}

// The image of a pointed marker in one color, outlined in `strokeColor`:
// the round marker's circle, centered in the image, drawn out to a tip that
// points up, which is north for a heading of zero.
function pointedImage({color, strokeColor}) {
  const size = POINTED_IMAGE_SIZE_PIXELS * POINTED_IMAGE_PIXEL_RATIO
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size

  const context = canvas.getContext("2d")
  const center = POINTED_IMAGE_SIZE_PIXELS / HALVING_DIVISOR
  const tipDistance = center - POINTED_TIP_INSET_PIXELS
  // The angle at the circle's center between the tip and each point where
  // a line from the tip touches the circle.
  const tangentAngle = Math.acos(MARKER_RADIUS_PIXELS / tipDistance)
  const up = -Math.PI / HALVING_DIVISOR

  context.scale(POINTED_IMAGE_PIXEL_RATIO, POINTED_IMAGE_PIXEL_RATIO)
  context.beginPath()
  context.moveTo(center, center - tipDistance)
  context.arc(center, center, MARKER_RADIUS_PIXELS, up + tangentAngle, up - tangentAngle)
  context.closePath()
  context.fillStyle = color
  context.fill()
  context.lineJoin = "round"
  context.lineWidth = MARKER_STROKE_WIDTH_PIXELS
  context.strokeStyle = strokeColor
  context.stroke()

  return context.getImageData(0, 0, size, size)
}

function headingText(heading) {
  if (typeof heading === "number") {
    return `${heading}° clockwise from north`
  } else {
    return NOT_SUPPLIED
  }
}

function suppliedText(value) {
  if (typeof value === "string") {
    return value
  } else {
    return NOT_SUPPLIED
  }
}

// The lines for a vehicle's lateness and its next stop, each only for a
// marker that has the text.
function tripTimeLines(properties) {
  const lines = []

  if (typeof properties.schedule === "string") {
    lines.push(`Schedule: ${properties.schedule}`)
  }

  if (typeof properties.nextStop === "string") {
    lines.push(`Next stop: ${properties.nextStop}`)
  }

  return lines
}

function appendParagraphs(content, lines) {
  for (const line of lines) {
    const paragraph = document.createElement("p")
    paragraph.textContent = line
    content.appendChild(paragraph)
  }
}

// The view's title: the route and where it goes, or the vehicle for one
// with neither.
function vehicleViewTitle(properties) {
  const names = []

  if (typeof properties.route === "string") {
    names.push(properties.route)
  }

  if (typeof properties.headsign === "string") {
    names.push(`to ${properties.headsign}`)
  }

  if (names.length === 0) {
    return `Vehicle ${properties.vehicleId}`
  } else {
    return names.join(" ")
  }
}

// A vehicle's view is built as text nodes: the vehicle identifier comes
// from outside the application and is never parsed as HTML. The current
// alerts of the vehicle's route stand under its route and headsign.
function vehicleViewContent(properties, statusLabels) {
  const tripLines = [
    `Vehicle ${properties.vehicleId}`,
    `Route: ${suppliedText(properties.route)}`,
    `Headsign: ${suppliedText(properties.headsign)}`
  ]
  const detailLines = [
    ...tripTimeLines(properties),
    statusLabels.get(properties.status),
    `Location reported: ${properties.locationAge}`,
    `Real-time data: ${properties.realTime}`,
    `Heading: ${headingText(properties.heading)}`,
    POSITION_NOTE
  ]
  const routeIds = []

  if (typeof properties.routeId === "string") {
    routeIds.push(properties.routeId)
  }

  const content = document.createElement("div")
  const trip = document.createElement("div")
  trip.className = FACTS_CLASS_NAME
  appendParagraphs(trip, tripLines)

  const alerts = document.createElement("div")
  alerts.className = ALERTS_CLASS_NAME

  for (const alertLine of alertLines({routeIds, stopId: null})) {
    alerts.append(alertLine)
  }

  const details = document.createElement("div")
  details.className = FACTS_CLASS_NAME
  appendParagraphs(details, detailLines)

  content.append(trip, alerts, details)
  return content
}

// A vehicle's popup is its route's number in its marker's color, with its
// lateness beside it where the marker has one. A click on it hands the
// vehicle to `onSelect`.
function compactVehicleContent({properties, onSelect}) {
  const chips = []
  let noteText = ""

  if (typeof properties.route === "string") {
    chips.push({name: properties.route, color: properties.color})
  }

  if (typeof properties.schedule === "string") {
    noteText = properties.schedule
  }

  const {content} = compactPopupContent({
    chips,
    countMax: 1,
    emptyText: `Vehicle ${properties.vehicleId}`,
    noteText,
    label: `Vehicle ${properties.vehicleId}: show the vehicle`,
    onSelect
  })

  return content
}

function statusLabelEntry({status, label}) {
  return [status, label]
}

// The hook of the element beside the map. It holds every agency's markers
// as the server last sent them, and draws them on each map the basemap
// announces, so a map drawn anew for another archive shows them too, and
// again in the theme of a map whose style is set anew.
export const VehicleMarkers = {
  mounted() {
    const statuses = JSON.parse(this.el.dataset.statuses)
    this.statuses = statuses
    const labelEntries = Array.from(statuses, statusLabelEntry)
    this.statusLabels = new Map(labelEntries)
    this.markersByAgency = new Map()
    this.map = null
    this.drawn = new Map()
    this.gliding = new Map()
    this.frame = null
    // The marker the details view shows, or null while it shows none, and
    // the texts it was last written from.
    this.viewMarkerId = null
    this.viewText = ""
    // The rider's popup of a vehicle, with its marker, or null while none
    // is open.
    this.riderPopup = null

    // The view moving to a stop, or closing, unmarks the vehicle's popup.
    this.onDetailChange = () => {
      const isViewLeft = this.viewMarkerId !== null && showsDetail({kind: DetailKind.vehicle, id: this.viewMarkerId}) === false

      if (isViewLeft) {
        this.viewMarkerId = null
        this.markSelected()
      }
    }

    window.addEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.stopGliding()
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => { this.attach(map, maplibre) })
    }

    // A style set anew holds none of the layers, nor the source, nor the
    // images of the pointed markers, which are made again as they are drawn.
    this.onRestyled = (event) => {
      const {map} = event.detail

      if (map === this.map) {
        this.addLayers(map)
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)

    this.events = pageEvents(this)

    this.events.handle("vehicle-markers:agency", ({agency_id: agencyId, markers}) => {
      this.markersByAgency.set(agencyId, markers)
      this.draw()
      this.updateView(markers)
    })

    this.events.push({name: "vehicle-markers:ready", payload: {}})
  },

  attach(map, maplibre) {
    // A pointed marker's image is made the first time a marker of its color
    // is drawn, since the colors are the routes' and not known in advance.
    // MapLibre awaits this resolver before it hands a tile its images, and
    // gives it to every style the map is set to; its "styleimagemissing"
    // event comes after the tile has taken its images without the new one
    // (maplibre-gl 6.12.0, ImageManager._getImagesForIds).
    map.setMissingStyleImageResolver((id) => {
      if (id.startsWith(POINTED_IMAGE_PREFIX)) {
        const color = id.slice(POINTED_IMAGE_PREFIX.length)
        const strokeColor = mapColors(currentTheme()).vehicleStroke
        const image = pointedImage({color, strokeColor})
        map.addImage(id, image, {pixelRatio: POINTED_IMAGE_PIXEL_RATIO})
      }
    })

    this.addLayers(map)
    const canvas = map.getCanvas()

    // A map keeps the listeners of a layer while the layer is added again.
    for (const layerName of markerLayerNames) {
      // A click on a vehicle opens its compact popup and shows the vehicle
      // in the details view.
      map.on("click", layerName, (event) => {
        const [feature] = event.features
        const {properties} = feature
        const lngLat = feature.geometry.coordinates
        const onSelect = () => { this.selectVehicle({properties, lngLat}) }

        const popup = new maplibre.Popup({className: RIDER_POPUP_CLASS_NAME})
          .setLngLat(lngLat)
          .setDOMContent(compactVehicleContent({properties, onSelect}))

        const riderPopup = {popup, markerId: properties.markerId}

        popup.on("close", () => {
          if (this.riderPopup === riderPopup) {
            this.riderPopup = null
          }

          announceRiderPopupChange()
        })

        popup.addTo(map)
        this.riderPopup = riderPopup
        this.selectVehicle({properties, lngLat})
        announceRiderPopupChange()
      })

      map.on("mouseenter", layerName, () => { canvas.style.cursor = "pointer" })
      map.on("mouseleave", layerName, () => { canvas.style.cursor = "" })
    }

    this.map = map
  },

  // Adds the source with every marker and the layers in the page's theme.
  addLayers(map) {
    this.stopGliding()

    // A new map draws every marker at its position, with nothing to glide from.
    const {collection, drawn} = placeMarkers({
      markersByAgency: this.markersByAgency,
      drawn: new Map(),
      startMs: performance.now(),
      reducedMotion: window.matchMedia(REDUCED_MOTION_QUERY).matches
    })

    this.drawn = drawn
    map.addSource(SOURCE_NAME, {type: "geojson", data: collection, promoteId: "markerId"})

    const colors = mapColors(currentTheme())
    const opacity = statusOpacity(this.statuses)

    map.addLayer({
      id: ROUND_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      filter: ["!", hasHeading],
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": ["get", "color"],
        "circle-opacity": opacity,
        "circle-stroke-color": colors.vehicleStroke,
        "circle-stroke-width": MARKER_STROKE_WIDTH_PIXELS,
        "circle-stroke-opacity": opacity
      }
    })

    // The image turns with the map, so a heading stays a compass direction
    // on a map that is turned.
    map.addLayer({
      id: POINTED_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      filter: hasHeading,
      layout: {
        "icon-image": ["concat", POINTED_IMAGE_PREFIX, ["get", "color"]],
        "icon-rotate": ["get", "heading"],
        "icon-rotation-alignment": "map",
        "icon-allow-overlap": true
      },
      paint: {"icon-opacity": opacity}
    })

    // A label is left out where it would cover another label, so a crowded
    // street shows the routes of some of its vehicles.
    map.addLayer({
      id: ROUTE_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      filter: hasRoute,
      layout: {
        "text-field": ["get", "route"],
        "text-font": routeFont,
        "text-size": ROUTE_TEXT_SIZE_PIXELS,
        "text-anchor": "top",
        "text-offset": routeTextOffsetEms,
        "text-allow-overlap": false
      },
      paint: {
        "text-color": colors.vehicleLabel,
        "text-halo-color": colors.vehicleHalo,
        "text-halo-width": ROUTE_HALO_WIDTH_PIXELS
      }
    })
  },

  draw() {
    // A map whose style is being set anew has no source until the style has
    // loaded, and the markers held here are drawn when the source is added.
    const hasSource = this.map !== null && this.map.getSource(SOURCE_NAME) !== undefined

    if (hasSource) {
      const {collection, drawn, gliding} = placeMarkers({
        markersByAgency: this.markersByAgency,
        drawn: this.drawn,
        startMs: performance.now(),
        reducedMotion: window.matchMedia(REDUCED_MOTION_QUERY).matches
      })

      this.drawn = drawn
      this.gliding = gliding
      this.map.getSource(SOURCE_NAME).setData(collection)
      this.requestGlideFrame()
    }
  },

  // Shows the vehicle of `properties` in the details view, marks its popup,
  // and moves the map so the vehicle, at `lngLat`, stands beside the sheet.
  selectVehicle({properties, lngLat}) {
    this.viewMarkerId = properties.markerId
    this.viewText = JSON.stringify(properties)
    showDetail({
      kind: DetailKind.vehicle,
      id: properties.markerId,
      title: vehicleViewTitle(properties),
      content: vehicleViewContent(properties, this.statusLabels)
    })
    this.markSelected()

    if (this.map !== null) {
      revealOnMap({map: this.map, lngLat})
    }
  },

  // Writes the view of the vehicle it shows from `markers`, one agency's
  // latest fetch, where they hold that vehicle. A vehicle no fetch holds
  // any more keeps the view it has.
  updateView(markers) {
    if (this.viewMarkerId === null) {
      return
    }

    const lookup = findMarker({markers, markerId: this.viewMarkerId})

    if (lookup.kind === MarkerLookupKind.missing) {
      return
    }

    // A fetch that leaves the vehicle's texts as they were leaves the view,
    // and the focus in it, as it is.
    const properties = markerProperties(lookup.marker)
    const viewText = JSON.stringify(properties)

    if (viewText !== this.viewText) {
      this.viewText = viewText

      updateDetail({
        kind: DetailKind.vehicle,
        id: properties.markerId,
        title: vehicleViewTitle(properties),
        content: vehicleViewContent(properties, this.statusLabels)
      })
    }
  },

  markSelected() {
    if (this.riderPopup !== null) {
      const isSelected = this.riderPopup.markerId === this.viewMarkerId
      this.riderPopup.popup.getElement().classList.toggle(SELECTED_POPUP_CLASS_NAME, isSelected)
    }
  },

  requestGlideFrame() {
    const isFrameDue = this.gliding.size > 0 && this.frame === null

    if (isFrameDue) {
      this.frame = requestAnimationFrame((frameMs) => { this.glideFrame(frameMs) })
    }
  },

  // One frame moves each gliding marker, and nothing else, in the source.
  // A glide ends after its duration, so the frames stop once every marker
  // has arrived.
  glideFrame(frameMs) {
    this.frame = null
    const source = this.map.getSource(SOURCE_NAME)

    if (source === undefined) {
      this.gliding = new Map()
      return
    }

    const update = []

    for (const [markerId, glide] of this.gliding) {
      const elapsedMs = frameMs - glide.startMs
      const {position, ended} = glidePosition({...glide, elapsedMs})

      update.push({id: markerId, newGeometry: point(position)})
      this.drawn.set(markerId, position)

      if (ended) {
        this.gliding.delete(markerId)
      }
    }

    source.updateData({update})
    this.requestGlideFrame()
  },

  stopGliding() {
    if (this.frame !== null) {
      cancelAnimationFrame(this.frame)
      this.frame = null
    }

    this.gliding = new Map()
  },

  destroyed() {
    this.stopGliding()
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.removeEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
    this.events.release()
  }
}
