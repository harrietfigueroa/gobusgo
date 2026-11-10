// Reads the vehicles, stops, and shared vehicles a map draws in the part of
// it the panel sheet leaves in sight, for the map's description and its list
// of what is in view, and whether a point of the map holds any of them.

import {viewBox} from "./map_view_text"
import {sheetInsets} from "./panel_sheet"
import {SHARED_VEHICLE_LAYER_NAME} from "./shared_vehicles"
import {MARKER_LAYER_NAME as STOP_LAYER_NAME, ZOOM_MIN as STOP_ZOOM_MIN} from "./stop_markers"
import {markerLayerNames as vehicleLayerNames} from "./vehicle_markers"
import {HitKind, overlayFeaturesIn, overlayHitAt} from "./vehicle_overlay"

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
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#queryrenderedfeatures — checked 2026-11-09
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

/**
 * What `map` draws beside the panel sheet: the middle of that part on the
 * screen, its vehicles' features by marker identifier, its stops' features
 * by stop identifier, its shared vehicles' features by key, and whether the
 * zoom draws stops at all. A zoom that draws no stops reads none.
 */
export function readView(map) {
  const container = map.getContainer()
  const {box, center} = viewBox({
    width: container.clientWidth,
    height: container.clientHeight,
    insets: sheetInsets()
  })

  const vehicles = renderedById({map, box, layerNames: vehicleLayerNames, idName: "markerId"})

  // The vehicles the canvas over the map draws are in no layer, and stand
  // where its last draw put them.
  for (const feature of overlayFeaturesIn({map, box})) {
    vehicles.set(feature.properties.markerId, feature)
  }

  const sharedVehicles = renderedById({map, box, layerNames: [SHARED_VEHICLE_LAYER_NAME], idName: "vehicleKey"})
  const hasStopLayer = map.getLayer(STOP_LAYER_NAME) !== undefined
  const isZoomedOut = map.getZoom() < STOP_ZOOM_MIN
  const isStopsHidden = hasStopLayer && isZoomedOut

  if (isStopsHidden) {
    return {center, vehicles, stops: new Map(), sharedVehicles, stopsDrawn: false}
  }

  const stops = renderedById({map, box, layerNames: [STOP_LAYER_NAME], idName: "stopId"})
  return {center, vehicles, stops, sharedVehicles, stopsDrawn: true}
}

/**
 * Whether `point`, a point on the screen of `map`, holds a vehicle, a stop,
 * or a shared vehicle, on the canvas over the map or in the layers that
 * take a tap, as a tap at the point finds them.
 */
export function isItemAt({map, point}) {
  if (overlayHitAt({map, point}).kind === HitKind.found) {
    return true
  }

  const layerNames = [...vehicleLayerNames, STOP_LAYER_NAME, SHARED_VEHICLE_LAYER_NAME]
  const layers = presentLayers({map, layerNames})

  if (layers.length === 0) {
    return false
  }

  const features = map.queryRenderedFeatures(point, {layers})
  return features.length > 0
}

/** Where `feature`, a point, stands on the screen of `map`. */
export function screenPoint({map, feature}) {
  const point = map.project(feature.geometry.coordinates)
  return {x: point.x, y: point.y}
}
