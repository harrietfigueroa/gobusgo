// The selected journey on the map: each ride a line in its route's color
// over a casing, each walk a dashed line, and a point at each end, and the
// labels of its times. Its layers stand over the route lines and under the stops and the
// vehicles, so a label gives way to a vehicle's badge and chevron as the
// badges give way to each other, are added to each map the basemap
// announces, and are added again in the map's theme once a style set anew
// has loaded, which drops them. The labels are drawn on the map's canvas,
// so no assistive technology reads them.

import {FIT_EVENT_DATA, READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {CHANGE_EVENT_NAME as CHOSEN_CHANGE_EVENT_NAME, ChosenKind, chosenJourney} from "./chosen_journey"
import {currentTheme} from "./color_theme"
import {LabelKind, journeyLabels} from "./journey_labels"
import {sheetInsets} from "./panel_sheet"
import {PILL_IMAGE_SIZE_PIXELS, pillImageSpec} from "./journey_label_pill"
import {MARKER_LAYER_NAME as STOP_MARKER_LAYER_NAME} from "./stop_markers"
import {registerImageResolver} from "./style_images"
import {mapColors} from "./theme"
import {BoundsKind, FeatureKind} from "./trip_plan"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"

const SOURCE_NAME = "trip-journey"
const CASING_LAYER_NAME = "trip-journey-casing"
const RIDE_LAYER_NAME = "trip-journey-ride"
const WALK_LAYER_NAME = "trip-journey-walk"
const ENDS_LAYER_NAME = "trip-journey-ends"
const LABEL_SOURCE_NAME = "trip-journey-label-points"
const LABEL_LAYER_NAME = "trip-journey-labels"
const ARRIVAL_LAYER_NAME = "trip-journey-arrival"
const IMAGE_RESOLVER_KEY = "trip-map"
const PILL_IMAGE_PREFIX = "trip-label-pill-"
const IMAGE_PIXEL_RATIO = 2
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
// The room kept beside the journey for a label standing at its leftmost or
// rightmost point: the width of the longest label with its offset.
const FIT_LABEL_MARGIN_PIXELS = 130
const FIT_ZOOM_MAX = 16
const LABEL_FONT = ["Noto Sans Medium"]
const LABEL_SIZE_PIXELS = 12
const LABEL_HALO_WIDTH_PIXELS = 3
// Wide enough that a label stays on one line.
const LABEL_WIDTH_MAX = 24
// The distance from a labeled point to its label, in multiples of the text size.
const LABEL_RADIAL_OFFSET = 1.1
const LABEL_ANCHORS = ["left", "right", "top", "bottom"]
// The order labels are placed in, lowest first, so a crowded stretch keeps
// the labels that matter most: the end, the start, a boarding, a getting
// off, and last a walk.
const LABEL_SORT_KEYS = Object.freeze({
  [LabelKind.arrive]: 0,
  [LabelKind.leave]: 1,
  [LabelKind.board]: 2,
  [LabelKind.alight]: 3,
  [LabelKind.walk]: 4
})
const lineLayout = {"line-cap": "round", "line-join": "round"}
const EMPTY_COLLECTION = Object.freeze({type: "FeatureCollection", features: []})

/** The kinds of a read of the map's center. */
export const CenterKind = Object.freeze({center: "center", none: "none"})

const isRide = ["==", ["get", "kind"], FeatureKind.ride]
const isWalk = ["==", ["get", "kind"], FeatureKind.walk]
const isEnd = ["in", ["get", "kind"], ["literal", [FeatureKind.origin, FeatureKind.destination]]]
const isArrival = ["==", ["get", "kind"], LabelKind.arrive]
const isNotArrival = ["!=", ["get", "kind"], LabelKind.arrive]

function labelFeature(label) {
  return {
    type: "Feature",
    geometry: {type: "Point", coordinates: label.coordinate},
    properties: {kind: label.kind, text: label.text, sortKey: LABEL_SORT_KEYS[label.kind]}
  }
}

// The labels of the journey that is chosen now, as a feature collection, or
// none where none is chosen.
function labelCollectionNow() {
  const chosen = chosenJourney()

  if (chosen.kind === ChosenKind.none) {
    return EMPTY_COLLECTION
  }

  const features = Array.from(journeyLabels({chosen}), labelFeature)
  return {type: "FeatureCollection", features}
}

// The first layer the journey goes under: a stop's, or else a vehicle's,
// or none on a map that holds neither yet, which adds them over it later.
function beforeLayerName(map) {
  const layerNames = [STOP_MARKER_LAYER_NAME, ...vehicleMarkerLayerNames]
  return layerNames.find((layerName) => map.getLayer(layerName) !== undefined)
}

// The pill the arrival label stands on, drawn in the label ink of `theme`
// at the size MapLibre stretches it from.
function pillImage({theme}) {
  const colors = mapColors(theme)
  const spec = pillImageSpec({pixelRatio: IMAGE_PIXEL_RATIO})
  const canvas = document.createElement("canvas")
  canvas.width = PILL_IMAGE_SIZE_PIXELS * IMAGE_PIXEL_RATIO
  canvas.height = PILL_IMAGE_SIZE_PIXELS * IMAGE_PIXEL_RATIO
  const context = canvas.getContext("2d")
  context.scale(IMAGE_PIXEL_RATIO, IMAGE_PIXEL_RATIO)
  context.beginPath()
  context.roundRect(0, 0, PILL_IMAGE_SIZE_PIXELS, PILL_IMAGE_SIZE_PIXELS, spec.radiusPixels)
  context.fillStyle = colors.badgeInk
  context.fill()
  return context.getImageData(0, 0, canvas.width, canvas.height)
}

function addPillImage({map, id}) {
  const spec = pillImageSpec({pixelRatio: IMAGE_PIXEL_RATIO})
  const theme = currentTheme()

  if (id === PILL_IMAGE_PREFIX + theme) {
    map.addImage(id, pillImage({theme}), {
      pixelRatio: IMAGE_PIXEL_RATIO,
      stretchX: spec.stretchX,
      stretchY: spec.stretchY,
      content: spec.content
    })
  }
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

  map.addLayer({
    id: LABEL_LAYER_NAME,
    type: "symbol",
    source: LABEL_SOURCE_NAME,
    filter: isNotArrival,
    layout: {
      "text-field": ["get", "text"],
      "text-font": LABEL_FONT,
      "text-size": LABEL_SIZE_PIXELS,
      "text-max-width": LABEL_WIDTH_MAX,
      "text-variable-anchor": LABEL_ANCHORS,
      "text-radial-offset": LABEL_RADIAL_OFFSET,
      "text-justify": "auto",
      "text-allow-overlap": false,
      "symbol-sort-key": ["get", "sortKey"]
    },
    paint: {
      "text-color": colors.badgeInk,
      "text-halo-color": colors.badgePaper,
      "text-halo-width": LABEL_HALO_WIDTH_PIXELS
    }
  }, before)

  // The arrival is a pill in the label ink with the label paper for its
  // text, so it reads apart from the times along the way, over their layer
  // so it is placed first. The pill stands out from the point by its padding
  // too, to clear the end's dot.
  const spec = pillImageSpec({pixelRatio: IMAGE_PIXEL_RATIO})
  const padding = spec.textFitPaddingPixels
  map.addLayer({
    id: ARRIVAL_LAYER_NAME,
    type: "symbol",
    source: LABEL_SOURCE_NAME,
    filter: isArrival,
    layout: {
      "text-field": ["get", "text"],
      "text-font": LABEL_FONT,
      "text-size": LABEL_SIZE_PIXELS,
      "text-max-width": LABEL_WIDTH_MAX,
      "text-variable-anchor": LABEL_ANCHORS,
      "text-radial-offset": LABEL_RADIAL_OFFSET + padding[1] / LABEL_SIZE_PIXELS,
      "text-justify": "auto",
      "text-allow-overlap": false,
      "icon-image": PILL_IMAGE_PREFIX + currentTheme(),
      "icon-text-fit": "both",
      "icon-text-fit-padding": padding,
      "icon-allow-overlap": false
    },
    paint: {"text-color": colors.badgePaper}
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
    map.addSource(LABEL_SOURCE_NAME, {type: "geojson", data: labelCollectionNow()})
    registerImageResolver({map, key: IMAGE_RESOLVER_KEY, resolve: (id) => { addPillImage({map, id}) }})
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

  // The labels follow the chosen journey: its change redraws them, and
  // clearing it removes them.
  function onChosenChange() {
    if (map !== null) {
      map.getSource(LABEL_SOURCE_NAME).setData(labelCollectionNow())
    }
  }

  window.addEventListener(READY_EVENT_NAME, onBasemapReady)
  window.addEventListener(RESTYLED_EVENT_NAME, onRestyled)
  window.addEventListener(CHOSEN_CHANGE_EVENT_NAME, onChosenChange)

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
        right: FIT_LABEL_MARGIN_PIXELS,
        bottom: insets.bottom + FIT_MARGIN_PIXELS,
        left: insets.left + FIT_LABEL_MARGIN_PIXELS
      },
      maxZoom: FIT_ZOOM_MAX
    }, FIT_EVENT_DATA)
  }

  function destroy() {
    window.removeEventListener(READY_EVENT_NAME, onBasemapReady)
    window.removeEventListener(RESTYLED_EVENT_NAME, onRestyled)
    window.removeEventListener(CHOSEN_CHANGE_EVENT_NAME, onChosenChange)
  }

  // The map's center in degrees, or none before a map has loaded.
  function center() {
    if (map === null) {
      return {kind: CenterKind.none}
    }

    const {lat, lng} = map.getCenter()
    return {kind: CenterKind.center, lat, lon: lng}
  }

  return {
    show,
    clear() { show(EMPTY_COLLECTION) },
    fit,
    center,
    destroy
  }
}
