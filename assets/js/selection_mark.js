// The mark the map draws around the item the details view shows, a stop, a
// vehicle, or a shared vehicle: a pale green halo under the item and a green
// ring around it, so the selection reads by its shape on either theme's map.
// Every value here is pure; a hook adds the layers to its own source.

const SELECTION_COLOR = "#16a34a"
const HALO_OPACITY = 0.25
const RING_STROKE_WIDTH_PIXELS = 3
// The ring stands this far outside the item's edge, and the halo this far
// outside the ring's.
const RING_GAP_PIXELS = 4
const HALO_REACH_PIXELS = 4
// A step expression's stop is a zoom followed by its output.
const STEP_STOP_LENGTH = 2

/** The paint of the halo under an item of `radiusPixels`, or a zoom expression of radii. */
export function selectionHaloPaint(radiusPixels) {
  return {
    "circle-radius": radiusAround({radiusPixels, outsidePixels: RING_GAP_PIXELS + HALO_REACH_PIXELS}),
    "circle-color": SELECTION_COLOR,
    "circle-opacity": HALO_OPACITY
  }
}

/** The paint of the ring around an item of `radiusPixels`, or a zoom expression of radii. */
export function selectionRingPaint(radiusPixels) {
  return {
    "circle-radius": radiusAround({radiusPixels, outsidePixels: RING_GAP_PIXELS}),
    "circle-opacity": 0,
    "circle-stroke-color": SELECTION_COLOR,
    "circle-stroke-width": RING_STROKE_WIDTH_PIXELS
  }
}

/** The color of the mark, for a canvas that draws it beside the map's layers. */
export function selectionColor() {
  return SELECTION_COLOR
}

/** How far the ring stands from an item's center, for a canvas that draws it. */
export function selectionRingRadius(radiusPixels) {
  return radiusPixels + RING_GAP_PIXELS
}

/** How far the halo reaches from an item's center, for a canvas that draws it. */
export function selectionHaloRadius(radiusPixels) {
  return radiusPixels + RING_GAP_PIXELS + HALO_REACH_PIXELS
}

/** The halo's opacity, for a canvas that draws it. */
export function selectionHaloOpacity() {
  return HALO_OPACITY
}

/** The ring's width, for a canvas that draws it. */
export function selectionRingWidth() {
  return RING_STROKE_WIDTH_PIXELS
}

// A radius of pixels, or a MapLibre `step` expression over the zoom whose
// outputs are radii, widened by `outsidePixels`.
// https://maplibre.org/maplibre-style-spec/expressions/#step — checked 2026-11-10
function radiusAround({radiusPixels, outsidePixels}) {
  if (typeof radiusPixels === "number") {
    return radiusPixels + outsidePixels
  }

  const [operator, input, firstOutput, ...stops] = radiusPixels
  const widened = [operator, input, firstOutput + outsidePixels]

  for (let index = 0; index < stops.length; index += STEP_STOP_LENGTH) {
    const zoom = stops[index]
    const output = stops[index + 1]
    widened.push(zoom, output + outsidePixels)
  }

  return widened
}
