import {readyEventName} from "./basemap"

const sourceName = "vehicle-markers"
const roundLayerName = "vehicle-markers-round"
const pointedLayerName = "vehicle-markers-pointed"
const layerNames = [roundLayerName, pointedLayerName]
const pointedImagePrefix = "vehicle-marker-pointed-"
const pointedImageSizePixels = 28
const pointedImagePixelRatio = 2
const pointedTipInsetPixels = 2
const markerRadiusPixels = 6
const markerStrokeWidthPixels = 1.5
const markerStrokeColor = "#ffffff"
const statusColorFallback = "#000000"
const positionNote = "Marker position: the source's estimate"
const headingNotSupplied = "Not supplied"
const hasHeading = ["==", ["typeof", ["get", "heading"]], "number"]

// Every agency's markers as one GeoJSON collection, a point per marker with
// the texts its popup shows.
function featureCollection(markersByAgency) {
  const features = []

  for (const markers of markersByAgency.values()) {
    for (const marker of markers) {
      features.push({
        type: "Feature",
        geometry: {type: "Point", coordinates: [marker.lon, marker.lat]},
        properties: {
          vehicleId: marker.vehicle_id,
          heading: marker.heading,
          status: marker.status,
          locationAge: marker.location_age,
          realTime: marker.real_time
        }
      })
    }
  }

  return {type: "FeatureCollection", features}
}

// The paint expression that gives each marker the color of its status.
function statusColor(statuses) {
  const cases = statuses.flatMap(({status, color}) => [status, color])
  return ["match", ["get", "status"], ...cases, statusColorFallback]
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
    return headingNotSupplied
  }
}

// A popup's content is built as text nodes: the vehicle identifier comes
// from outside the application and is never parsed as HTML.
function popupContent(properties, statusLabels) {
  const lines = [
    `Vehicle ${properties.vehicleId}`,
    statusLabels.get(properties.status),
    `Location reported: ${properties.locationAge}`,
    `Real-time data: ${properties.realTime}`,
    `Heading: ${headingText(properties.heading)}`,
    positionNote
  ]
  const content = document.createElement("div")

  for (const line of lines) {
    const paragraph = document.createElement("p")
    paragraph.textContent = line
    content.appendChild(paragraph)
  }

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

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
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
    map.addSource(sourceName, {type: "geojson", data: featureCollection(this.markersByAgency)})

    for (const {status, color} of this.statuses) {
      map.addImage(pointedImagePrefix + status, pointedImage(color), {
        pixelRatio: pointedImagePixelRatio
      })
    }

    map.addLayer({
      id: roundLayerName,
      type: "circle",
      source: sourceName,
      filter: ["!", hasHeading],
      paint: {
        "circle-radius": markerRadiusPixels,
        "circle-color": statusColor(this.statuses),
        "circle-stroke-color": markerStrokeColor,
        "circle-stroke-width": markerStrokeWidthPixels
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
        "icon-image": ["concat", pointedImagePrefix, ["get", "status"]],
        "icon-rotate": ["get", "heading"],
        "icon-rotation-alignment": "map",
        "icon-allow-overlap": true
      }
    })

    for (const layerName of layerNames) {
      map.on("click", layerName, (event) => {
        const [feature] = event.features

        new maplibre.Popup()
          .setLngLat(feature.geometry.coordinates)
          .setDOMContent(popupContent(feature.properties, this.statusLabels))
          .addTo(map)
      })

      map.on("mouseenter", layerName, () => { map.getCanvas().style.cursor = "pointer" })
      map.on("mouseleave", layerName, () => { map.getCanvas().style.cursor = "" })
    }

    this.map = map
  },

  draw() {
    if (this.map !== null) {
      this.map.getSource(sourceName).setData(featureCollection(this.markersByAgency))
    }
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
  }
}
