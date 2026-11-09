// The hook of the vehicle map's description. On each map the basemap
// announces, it names the canvas and points it at the description, writes
// what is in view into the description each time the map comes to rest,
// and has the map's live region announce it after a move the rider made or
// a fit, by the imported rules.
//
// The canvas takes `role="application"`: MapLibre's keyboard handler pans,
// zooms, turns, and tilts the map from the keys pressed on the focused
// canvas, and a screen reader in reading mode keeps those keys for itself
// unless the focused element is an application. The role stays on the
// canvas alone, which holds nothing to read, so the controls and popups
// beside it keep reading mode.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/KeyboardHandler/ — checked 2026-11-09

import {READY_EVENT_NAME} from "./basemap"
import {announce} from "./map_live_region"
import {
  AnnouncerEffectKind,
  announcerStep,
  initialAnnouncer,
  MoveEventKind,
  nearestPlace,
  PlaceKind,
  viewBox,
  viewSentence
} from "./map_view_text"
import {sheetInsets} from "./panel_sheet"
import {MARKER_LAYER_NAME as STOP_LAYER_NAME, ZOOM_MIN as STOP_ZOOM_MIN} from "./stop_markers"
import {markerLayerNames as vehicleLayerNames} from "./vehicle_markers"
import {unreachable} from "./assert.js"

const CANVAS_NAME = "Vehicle map"
const CANVAS_ROLE = "application"
const CANVAS_ROLE_DESCRIPTION = "map"
// The description's element, which the server renders around the part of
// it this hook writes.
const DESCRIPTION_ID = "map-description"
const VIEW_TEXT_ID = "map-description-view"

// The layers of `layerNames` the map's style holds now; a style being set
// anew holds none of them, and a map with no tile archive no stop layer.
function presentLayers({map, layerNames}) {
  const present = []

  for (const layerName of layerNames) {
    if (map.getLayer(layerName) !== undefined) {
      present.push(layerName)
    }
  }

  return present
}

// The features of `layerNames` drawn inside `box`, one per value of the
// property `idName`: a point near a tile's edge comes back from each tile
// that holds it.
function renderedById({map, box, layerNames, idName}) {
  const layers = presentLayers({map, layerNames})
  const byId = new Map()

  if (layers.length === 0) {
    return byId
  }

  const features = map.queryRenderedFeatures(box, {layers})

  for (const feature of features) {
    byId.set(feature.properties[idName], feature)
  }

  return byId
}

function isNamedStop(feature) {
  const {name} = feature.properties
  return typeof name === "string" && name !== ""
}

// The named stops of `stops` as places on the screen of `map`.
function stopPlaces({map, stops}) {
  const places = []

  for (const feature of stops.values()) {
    if (isNamedStop(feature)) {
      const point = map.project(feature.geometry.coordinates)
      places.push({name: feature.properties.name, x: point.x, y: point.y})
    }
  }

  return places
}

// The sentence of what `map` shows beside the panel sheet.
function viewTextOf(map) {
  const container = map.getContainer()
  const {box, center} = viewBox({
    width: container.clientWidth,
    height: container.clientHeight,
    insets: sheetInsets()
  })

  const vehicles = renderedById({map, box, layerNames: vehicleLayerNames, idName: "markerId"})
  const hasStopLayer = map.getLayer(STOP_LAYER_NAME) !== undefined
  const isZoomedOut = map.getZoom() < STOP_ZOOM_MIN
  const isStopsHidden = hasStopLayer && isZoomedOut

  if (isStopsHidden) {
    return viewSentence({vehicleCount: vehicles.size, stopCount: 0, stopsDrawn: false, nearest: {kind: PlaceKind.missing}})
  }

  const stops = renderedById({map, box, layerNames: [STOP_LAYER_NAME], idName: "stopId"})
  const places = stopPlaces({map, stops})
  const nearest = nearestPlace({places, center})
  return viewSentence({vehicleCount: vehicles.size, stopCount: stops.size, stopsDrawn: true, nearest})
}

function describeCanvas(canvas) {
  canvas.setAttribute("role", CANVAS_ROLE)
  canvas.setAttribute("aria-roledescription", CANVAS_ROLE_DESCRIPTION)
  canvas.setAttribute("aria-label", CANVAS_NAME)
  canvas.setAttribute("aria-describedby", DESCRIPTION_ID)
}

// A move the rider made carries the input event that made it, and a fit of
// the page's carries the fit's event data.
function isAnnouncedMove(event) {
  const isRiderMove = event.originalEvent !== undefined
  return isRiderMove || event.fitSource === true
}

export const MapDescription = {
  mounted() {
    this.map = null
    this.announcer = initialAnnouncer
    this.waitTimer = null

    this.onBasemapReady = (event) => { this.attach(event.detail.map) }
    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
  },

  attach(map) {
    this.cancelWait()
    this.map = map
    this.announcer = initialAnnouncer
    describeCanvas(map.getCanvas())

    map.on("movestart", () => {
      this.cancelWait()
      this.step({kind: MoveEventKind.started})
    })

    map.on("moveend", (event) => {
      this.step({kind: MoveEventKind.ended, announced: isAnnouncedMove(event)})
    })

    map.on("idle", () => {
      if (this.map === map) {
        this.rest()
      }
    })
  },

  // Writes what the map shows into the description, and tells the
  // announcer the map is at rest.
  rest() {
    const text = viewTextOf(this.map)
    const element = document.getElementById(VIEW_TEXT_ID)

    if (element !== null) {
      element.textContent = text
    }

    this.step({kind: MoveEventKind.rested, nowMs: performance.now(), text})
  },

  step(event) {
    const {state, effect} = announcerStep({state: this.announcer, event})
    this.announcer = state

    switch (effect.kind) {
      case AnnouncerEffectKind.none:
        break
      case AnnouncerEffectKind.announce:
        announce(effect.text)
        break
      case AnnouncerEffectKind.wait:
        this.waitTimer = window.setTimeout(() => {
          this.waitTimer = null
          this.rest()
        }, effect.ms)
        break
      default:
        unreachable(effect.kind, "an unknown announcer effect")
    }
  },

  cancelWait() {
    if (this.waitTimer !== null) {
      window.clearTimeout(this.waitTimer)
      this.waitTimer = null
    }
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    this.cancelWait()
  }
}
