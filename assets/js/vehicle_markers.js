import {READY_EVENT_NAME} from "./basemap"
import {glidePosition, glides} from "./marker_glide"
import {announceRiderPopupChange, RIDER_POPUP_CLASS_NAME} from "./rider_popups"
import {compactPopupContent} from "./route_chips"
import {alertLines} from "./service_alerts"

const SOURCE_NAME = "vehicle-markers"
const ROUND_LAYER_NAME = "vehicle-markers-round"
const POINTED_LAYER_NAME = "vehicle-markers-pointed"

// The layers a vehicle's marker is drawn in, round or pointed.
export const markerLayerNames = [ROUND_LAYER_NAME, POINTED_LAYER_NAME]
const ROUTE_LAYER_NAME = "vehicle-markers-route"
const routeFont = ["Noto Sans Medium"]
const ROUTE_TEXT_SIZE_PIXELS = 11
const routeTextOffsetEms = [0, 1]
const ROUTE_TEXT_COLOR = "#0f172a"
const ROUTE_HALO_COLOR = "#ffffff"
const ROUTE_HALO_WIDTH_PIXELS = 1.5
const POINTED_IMAGE_PREFIX = "vehicle-marker-pointed-"
const POINTED_IMAGE_SIZE_PIXELS = 28
const POINTED_IMAGE_PIXEL_RATIO = 2
const POINTED_TIP_INSET_PIXELS = 2
const HALVING_DIVISOR = 2
const MARKER_RADIUS_PIXELS = 6
const MARKER_STROKE_WIDTH_PIXELS = 1.5
const MARKER_STROKE_COLOR = "#ffffff"
const STATUS_OPACITY_FALLBACK = 1
const POSITION_NOTE = "Marker position: the source's estimate"
const NOT_SUPPLIED = "Not supplied"
const TITLE_CLASS_NAME = "popup-title"
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
      features.push({
        type: "Feature",
        geometry: point(position),
        properties: {
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
      })
    }
  }

  return {collection: {type: "FeatureCollection", features}, drawn: placed, gliding}
}

function statusCase({status, opacity}) {
  return [status, opacity]
}

// The paint expression that gives each marker the opacity of its status.
function statusOpacity(statuses) {
  const cases = statuses.flatMap(statusCase)
  return ["match", ["get", "status"], ...cases, STATUS_OPACITY_FALLBACK]
}

// The image of a pointed marker in one color: the round marker's circle,
// centered in the image, drawn out to a tip that points up, which is north
// for a heading of zero.
function pointedImage(color) {
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
  context.strokeStyle = MARKER_STROKE_COLOR
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

// A popup's content is built as text nodes: the vehicle identifier comes
// from outside the application and is never parsed as HTML. The current
// alerts of the vehicle's route stand under its route and headsign.
function popupContent(properties, statusLabels) {
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

  appendParagraphs(content, tripLines)

  for (const alertLine of alertLines({routeIds, stopId: null})) {
    content.append(alertLine)
  }

  appendParagraphs(content, detailLines)

  content.firstElementChild.className = TITLE_CLASS_NAME
  return content
}

// A vehicle's popup opens as its route's number in its marker's color.
function compactVehicleContent(properties, statusLabels) {
  const chips = []

  if (typeof properties.route === "string") {
    chips.push({name: properties.route, color: properties.color})
  }

  return compactPopupContent({
    chips,
    countMax: 1,
    emptyText: `Vehicle ${properties.vehicleId}`,
    label: `Vehicle ${properties.vehicleId}: show details`,
    details: popupContent(properties, statusLabels)
  })
}

function statusLabelEntry({status, label}) {
  return [status, label]
}

// The hook of the element beside the map. It holds every agency's markers
// as the server last sent them, and draws them on each map the basemap
// announces, so a map drawn anew for another archive shows them too.
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

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.stopGliding()
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => { this.attach(map, maplibre) })
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)

    this.handleEvent("vehicle-markers:agency", ({agency_id: agencyId, markers}) => {
      this.markersByAgency.set(agencyId, markers)
      this.draw()
    })

    this.pushEvent("vehicle-markers:ready", {})
  },

  attach(map, maplibre) {
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

    // A pointed marker's image is made the first time a marker of its color
    // is drawn, since the colors are the routes' and not known in advance.
    map.on("styleimagemissing", ({id}) => {
      if (id.startsWith(POINTED_IMAGE_PREFIX)) {
        const color = id.slice(POINTED_IMAGE_PREFIX.length)
        map.addImage(id, pointedImage(color), {pixelRatio: POINTED_IMAGE_PIXEL_RATIO})
      }
    })

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
        "circle-stroke-color": MARKER_STROKE_COLOR,
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
        "text-color": ROUTE_TEXT_COLOR,
        "text-halo-color": ROUTE_HALO_COLOR,
        "text-halo-width": ROUTE_HALO_WIDTH_PIXELS
      }
    })

    const canvas = map.getCanvas()

    for (const layerName of markerLayerNames) {
      map.on("click", layerName, (event) => {
        const [feature] = event.features

        const popup = new maplibre.Popup({className: RIDER_POPUP_CLASS_NAME})
          .setLngLat(feature.geometry.coordinates)
          .setDOMContent(compactVehicleContent(feature.properties, this.statusLabels))

        popup.on("close", announceRiderPopupChange)
        popup.addTo(map)
        announceRiderPopupChange()
      })

      map.on("mouseenter", layerName, () => { canvas.style.cursor = "pointer" })
      map.on("mouseleave", layerName, () => { canvas.style.cursor = "" })
    }

    this.map = map
  },

  draw() {
    if (this.map !== null) {
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

    this.map.getSource(SOURCE_NAME).updateData({update})
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
  }
}
