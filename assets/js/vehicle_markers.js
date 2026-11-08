import {readyEventName} from "./basemap"
import {glidePosition, glides} from "./marker_glide"
import {announceRiderPopupChange, riderPopupClassName} from "./rider_popups"
import {alertLines} from "./service_alerts"

const sourceName = "vehicle-markers"
const roundLayerName = "vehicle-markers-round"
const pointedLayerName = "vehicle-markers-pointed"

// The layers a vehicle's marker is drawn in, round or pointed.
export const markerLayerNames = [roundLayerName, pointedLayerName]
const routeLayerName = "vehicle-markers-route"
const routeFont = ["Noto Sans Medium"]
const routeTextSizePixels = 11
const routeTextOffsetEms = [0, 1]
const routeTextColor = "#0f172a"
const routeHaloColor = "#ffffff"
const routeHaloWidthPixels = 1.5
const pointedImagePrefix = "vehicle-marker-pointed-"
const pointedImageSizePixels = 28
const pointedImagePixelRatio = 2
const pointedTipInsetPixels = 2
const markerRadiusPixels = 6
const markerStrokeWidthPixels = 1.5
const markerStrokeColor = "#ffffff"
const statusOpacityFallback = 1
const positionNote = "Marker position: the source's estimate"
const notSupplied = "Not supplied"
const titleClassName = "popup-title"
const hasHeading = ["==", ["typeof", ["get", "heading"]], "number"]
const hasRoute = ["==", ["typeof", ["get", "route"]], "string"]
const reducedMotionQuery = "(prefers-reduced-motion: reduce)"

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

// The paint expression that gives each marker the opacity of its status.
function statusOpacity(statuses) {
  const cases = statuses.flatMap(({status, opacity}) => [status, opacity])
  return ["match", ["get", "status"], ...cases, statusOpacityFallback]
}

// The image of a pointed marker in one color: the round marker's circle,
// centered in the image, drawn out to a tip that points up, which is north
// for a heading of zero.
function pointedImage(color) {
  const size = pointedImageSizePixels * pointedImagePixelRatio
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size

  const context = canvas.getContext("2d")
  const center = pointedImageSizePixels / 2
  const tipDistance = center - pointedTipInsetPixels
  // The angle at the circle's center between the tip and each point where
  // a line from the tip touches the circle.
  const tangentAngle = Math.acos(markerRadiusPixels / tipDistance)
  const up = -Math.PI / 2

  context.scale(pointedImagePixelRatio, pointedImagePixelRatio)
  context.beginPath()
  context.moveTo(center, center - tipDistance)
  context.arc(center, center, markerRadiusPixels, up + tangentAngle, up - tangentAngle)
  context.closePath()
  context.fillStyle = color
  context.fill()
  context.lineJoin = "round"
  context.lineWidth = markerStrokeWidthPixels
  context.strokeStyle = markerStrokeColor
  context.stroke()

  return context.getImageData(0, 0, size, size)
}

function headingText(heading) {
  if (typeof heading === "number") {
    return `${heading}° clockwise from north`
  } else {
    return notSupplied
  }
}

function suppliedText(value) {
  if (typeof value === "string") {
    return value
  } else {
    return notSupplied
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
    positionNote
  ]
  const routeIds = typeof properties.routeId === "string" ? [properties.routeId] : []
  const content = document.createElement("div")

  appendParagraphs(content, tripLines)
  content.append(...alertLines({routeIds, stopId: null}))
  appendParagraphs(content, detailLines)

  content.firstElementChild.className = titleClassName
  return content
}

// The hook of the element beside the map. It holds every agency's markers
// as the server last sent them, and draws them on each map the basemap
// announces, so a map drawn anew for another archive shows them too.
export const VehicleMarkers = {
  mounted() {
    const statuses = JSON.parse(this.el.dataset.statuses)
    this.statuses = statuses
    this.statusLabels = new Map(statuses.map(({status, label}) => [status, label]))
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

    window.addEventListener(readyEventName, this.onBasemapReady)

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
      reducedMotion: window.matchMedia(reducedMotionQuery).matches
    })

    this.drawn = drawn
    map.addSource(sourceName, {type: "geojson", data: collection, promoteId: "markerId"})

    // A pointed marker's image is made the first time a marker of its color
    // is drawn, since the colors are the routes' and not known in advance.
    map.on("styleimagemissing", ({id}) => {
      if (id.startsWith(pointedImagePrefix)) {
        const color = id.slice(pointedImagePrefix.length)
        map.addImage(id, pointedImage(color), {pixelRatio: pointedImagePixelRatio})
      }
    })

    const opacity = statusOpacity(this.statuses)

    map.addLayer({
      id: roundLayerName,
      type: "circle",
      source: sourceName,
      filter: ["!", hasHeading],
      paint: {
        "circle-radius": markerRadiusPixels,
        "circle-color": ["get", "color"],
        "circle-opacity": opacity,
        "circle-stroke-color": markerStrokeColor,
        "circle-stroke-width": markerStrokeWidthPixels,
        "circle-stroke-opacity": opacity
      }
    })

    // The image turns with the map, so a heading stays a compass direction
    // on a map that is turned.
    map.addLayer({
      id: pointedLayerName,
      type: "symbol",
      source: sourceName,
      filter: hasHeading,
      layout: {
        "icon-image": ["concat", pointedImagePrefix, ["get", "color"]],
        "icon-rotate": ["get", "heading"],
        "icon-rotation-alignment": "map",
        "icon-allow-overlap": true
      },
      paint: {"icon-opacity": opacity}
    })

    // A label is left out where it would cover another label, so a crowded
    // street shows the routes of some of its vehicles.
    map.addLayer({
      id: routeLayerName,
      type: "symbol",
      source: sourceName,
      filter: hasRoute,
      layout: {
        "text-field": ["get", "route"],
        "text-font": routeFont,
        "text-size": routeTextSizePixels,
        "text-anchor": "top",
        "text-offset": routeTextOffsetEms,
        "text-allow-overlap": false
      },
      paint: {
        "text-color": routeTextColor,
        "text-halo-color": routeHaloColor,
        "text-halo-width": routeHaloWidthPixels
      }
    })

    for (const layerName of markerLayerNames) {
      map.on("click", layerName, (event) => {
        const [feature] = event.features

        const popup = new maplibre.Popup({className: riderPopupClassName})
          .setLngLat(feature.geometry.coordinates)
          .setDOMContent(popupContent(feature.properties, this.statusLabels))

        popup.on("close", announceRiderPopupChange)
        popup.addTo(map)
        announceRiderPopupChange()
      })

      map.on("mouseenter", layerName, () => { map.getCanvas().style.cursor = "pointer" })
      map.on("mouseleave", layerName, () => { map.getCanvas().style.cursor = "" })
    }

    this.map = map
  },

  draw() {
    if (this.map !== null) {
      const {collection, drawn, gliding} = placeMarkers({
        markersByAgency: this.markersByAgency,
        drawn: this.drawn,
        startMs: performance.now(),
        reducedMotion: window.matchMedia(reducedMotionQuery).matches
      })

      this.drawn = drawn
      this.gliding = gliding
      this.map.getSource(sourceName).setData(collection)
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

    this.map.getSource(sourceName).updateData({update})
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
    window.removeEventListener(readyEventName, this.onBasemapReady)
  }
}
