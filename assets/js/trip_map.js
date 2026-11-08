// The selected journey on the map: each ride a line in its route's color
// over a casing, each walk a dashed line, and a point at each end. Its
// layers stand over the route lines and under the stops and the vehicles,
// are added to each map the basemap announces, and are added again in the
// map's theme once a style set anew has loaded, which drops them.

import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {currentTheme} from "./color_theme"
import {sheetInsets} from "./panel_sheet"
import {MARKER_LAYER_NAME as STOP_MARKER_LAYER_NAME} from "./stop_markers"
import {mapColors} from "./theme"
import {BoundsKind, FeatureKind} from "./trip_plan"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"

const SOURCE_NAME = "trip-journey"
const CASING_LAYER_NAME = "trip-journey-casing"
const RIDE_LAYER_NAME = "trip-journey-ride"
const WALK_LAYER_NAME = "trip-journey-walk"
const ENDS_LAYER_NAME = "trip-journey-ends"
const RIDE_WIDTH_PIXELS = 5
// A casing is as much wider than its line as it shows on both sides.
const CASING_WIDTH_EXTRA_PIXELS = 4
const WALK_WIDTH_PIXELS = 3
// A dash and the gap after it, in multiples of the line's width.
const WALK_DASH_LENGTH = 1
const WALK_GAP_LENGTH = 2
const WALK_DASH_PATTERN = [WALK_DASH_LENGTH, WALK_GAP_LENGTH]
const END_RADIUS_PIXELS = 7
const END_STROKE_WIDTH_PIXELS = 3
// The room kept between the journey and the map's edges when the map is
// fitted to it, beside the room the sheet covers.
const FIT_MARGIN_PIXELS = 48
const FIT_ZOOM_MAX = 16
const lineLayout = {"line-cap": "round", "line-join": "round"}
const EMPTY_COLLECTION = Object.freeze({type: "FeatureCollection", features: []})

const isRide = ["==", ["get", "kind"], FeatureKind.ride]
const isWalk = ["==", ["get", "kind"], FeatureKind.walk]
const isEnd = ["in", ["get", "kind"], ["literal", [FeatureKind.origin, FeatureKind.destination]]]

// The first layer the journey goes under: a stop's, or else a vehicle's,
// or none on a map that holds neither yet, which adds them over it later.
function beforeLayerName(map) {
  const layerNames = [STOP_MARKER_LAYER_NAME, ...vehicleMarkerLayerNames]
  return layerNames.find((layerName) => map.getLayer(layerName) !== undefined)
}

function addLayers(map) {
  const colors = mapColors(currentTheme())
  const before = beforeLayerName(map)

  map.addLayer({
    id: CASING_LAYER_NAME,
    type: "line",
    source: SOURCE_NAME,
    filter: isRide,
    layout: lineLayout,
    paint: {"line-color": colors.tripCasing, "line-width": RIDE_WIDTH_PIXELS + CASING_WIDTH_EXTRA_PIXELS}
  }, before)

  map.addLayer({
    id: RIDE_LAYER_NAME,
    type: "line",
    source: SOURCE_NAME,
    filter: isRide,
    layout: lineLayout,
    paint: {"line-color": ["get", "color"], "line-width": RIDE_WIDTH_PIXELS}
  }, before)

  map.addLayer({
    id: WALK_LAYER_NAME,
    type: "line",
    source: SOURCE_NAME,
    filter: isWalk,
    layout: {"line-cap": "butt", "line-join": "round"},
    paint: {"line-color": colors.tripWalk, "line-width": WALK_WIDTH_PIXELS, "line-dasharray": WALK_DASH_PATTERN}
  }, before)

  map.addLayer({
    id: ENDS_LAYER_NAME,
    type: "circle",
    source: SOURCE_NAME,
    filter: isEnd,
    paint: {
      "circle-radius": END_RADIUS_PIXELS,
      "circle-color": ["match", ["get", "kind"], FeatureKind.origin, colors.tripOrigin, colors.tripDestination],
      "circle-stroke-color": colors.tripCasing,
      "circle-stroke-width": END_STROKE_WIDTH_PIXELS
    }
  }, before)
}

/**
 * The journey drawing of the page's maps. `show` draws a feature
 * collection in place of the one drawn, `clear` draws none, and `fit` moves
 * the view to bounds, a BoundsKind member, beside the panel sheet.
 */
export function createTripMap() {
  let map = null
  let collection = EMPTY_COLLECTION

  function attach() {
    map.addSource(SOURCE_NAME, {type: "geojson", data: collection})
    addLayers(map)
  }

  function onBasemapReady(event) {
    map = null
    const announced = event.detail.map

    // The map takes sources and layers once its style has loaded.
    announced.once("load", () => {
      map = announced
      attach()
    })
  }

  // A style set anew holds none of the layers, nor the source.
  function onRestyled(event) {
    if (event.detail.map === map) {
      attach()
    }
  }

  window.addEventListener(READY_EVENT_NAME, onBasemapReady)
  window.addEventListener(RESTYLED_EVENT_NAME, onRestyled)

  function show(shown) {
    collection = shown

    if (map !== null) {
      map.getSource(SOURCE_NAME).setData(collection)
    }
  }

  function fit(bounds) {
    const isFittable = map !== null && bounds.kind === BoundsKind.bounds

    if (!isFittable) {
      return
    }

    const insets = sheetInsets()

    map.fitBounds(bounds.bounds, {
      padding: {
        top: FIT_MARGIN_PIXELS,
        right: FIT_MARGIN_PIXELS,
        bottom: insets.bottom + FIT_MARGIN_PIXELS,
        left: insets.left + FIT_MARGIN_PIXELS
      },
      maxZoom: FIT_ZOOM_MAX
    })
  }

  function destroy() {
    window.removeEventListener(READY_EVENT_NAME, onBasemapReady)
    window.removeEventListener(RESTYLED_EVENT_NAME, onRestyled)
  }

  return {
    show,
    clear() { show(EMPTY_COLLECTION) },
    fit,
    destroy
  }
}
