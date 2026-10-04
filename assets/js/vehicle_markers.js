import {readyEventName} from "./basemap"

const sourceName = "vehicle-markers"
const layerName = "vehicle-markers"
const markerRadiusPixels = 6
const markerStrokeWidthPixels = 1.5
const markerStrokeColor = "#ffffff"
const statusColorFallback = "#000000"
const positionNote = "Marker position: the source's estimate"

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

// A popup's content is built as text nodes: the vehicle identifier comes
// from outside the application and is never parsed as HTML.
function popupContent(properties, statusLabels) {
  const lines = [
    `Vehicle ${properties.vehicleId}`,
    statusLabels.get(properties.status),
    `Location reported: ${properties.locationAge}`,
    `Real-time data: ${properties.realTime}`,
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

    map.addLayer({
      id: layerName,
      type: "circle",
      source: sourceName,
      paint: {
        "circle-radius": markerRadiusPixels,
        "circle-color": statusColor(this.statuses),
        "circle-stroke-color": markerStrokeColor,
        "circle-stroke-width": markerStrokeWidthPixels
      }
    })

    map.on("click", layerName, (event) => {
      const [feature] = event.features

      new maplibre.Popup()
        .setLngLat(feature.geometry.coordinates)
        .setDOMContent(popupContent(feature.properties, this.statusLabels))
        .addTo(map)
    })

    map.on("mouseenter", layerName, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", layerName, () => { map.getCanvas().style.cursor = "" })
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
