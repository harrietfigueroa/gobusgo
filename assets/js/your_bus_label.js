// The label beside the vehicle of the chosen journey's first ride: a symbol
// layer over the vehicle markers' source, filtered to the marker whose trip
// and service date are the ride's, so it stands beside the marker's own
// feature and leaves no label where the page holds no such marker. The
// vehicle hook adds it with its layers, each time a style loads, and the
// chosen journey's changes set its text and filter. It is drawn on the
// map's canvas, so no assistive technology reads it.

import {CHANGE_EVENT_NAME as CHOSEN_CHANGE_EVENT_NAME, ChosenKind, chosenJourney} from "./chosen_journey"
import {currentTheme} from "./color_theme"
import {YourBusLabelKind, yourBusLabel} from "./journey_labels"
import {mapColors} from "./theme"

const LAYER_NAME = "vehicle-your-bus"
const LABEL_FONT = ["Noto Sans Medium"]
const LABEL_SIZE_PIXELS = 12
const LABEL_HALO_WIDTH_PIXELS = 3
// The distance from the marker's center to the label, in multiples of the
// text size: past the bus glyph's radius of 11 pixels with a gap.
const LABEL_RADIAL_OFFSET = 1.6
// Wide enough that the text stays on one line.
const LABEL_WIDTH_MAX = 24
const LABEL_ANCHORS = ["left", "right"]
const SOURCE_NAME_DEFAULT = "vehicle-markers"
const HIDDEN_FILTER = ["==", ["literal", 0], ["literal", 1]]

// The filter and text of the label of the journey chosen now: the marker of
// its first ride's trip and service date, and "Your bus · 4 min away"; or a
// filter no marker passes where none is chosen or the bus has passed.
function labelNow() {
  const chosen = chosenJourney()

  if (chosen.kind === ChosenKind.none) {
    return {filter: HIDDEN_FILTER, text: ""}
  }

  const label = yourBusLabel({chosen})

  if (label.kind === YourBusLabelKind.none) {
    return {filter: HIDDEN_FILTER, text: ""}
  }

  const filter = ["all", ["==", ["get", "tripId"], label.tripId], ["==", ["get", "serviceDateMs"], label.serviceDateMs]]
  return {filter, text: label.text}
}

/**
 * The label of the first bus on the vehicle markers' source named
 * `sourceName`. `attach(map)` adds its layer to a map whose style has loaded
 * and the source exists in, and `destroy` stops it following the chosen
 * journey.
 */
export function createYourBusLabel({sourceName = SOURCE_NAME_DEFAULT} = {}) {
  let map = null

  function apply() {
    const hasLayer = map !== null && map.getLayer(LAYER_NAME) !== undefined

    if (!hasLayer) {
      return
    }

    const {filter, text} = labelNow()
    map.setFilter(LAYER_NAME, filter)
    map.setLayoutProperty(LAYER_NAME, "text-field", text)
  }

  function attach(attached) {
    map = attached
    const colors = mapColors(currentTheme())
    const {filter, text} = labelNow()

    // The label is its marker's own, so it stays where it collides with the
    // marker's badge, and it takes its room before the journey's labels,
    // which give way to it.
    map.addLayer({
      id: LAYER_NAME,
      type: "symbol",
      source: sourceName,
      filter,
      layout: {
        "text-field": text,
        "text-font": LABEL_FONT,
        "text-size": LABEL_SIZE_PIXELS,
        "text-max-width": LABEL_WIDTH_MAX,
        "text-variable-anchor": LABEL_ANCHORS,
        "text-radial-offset": LABEL_RADIAL_OFFSET,
        "text-justify": "auto",
        "text-allow-overlap": true,
        "text-ignore-placement": false
      },
      paint: {
        "text-color": colors.badgeInk,
        "text-halo-color": colors.badgePaper,
        "text-halo-width": LABEL_HALO_WIDTH_PIXELS
      }
    })
  }

  window.addEventListener(CHOSEN_CHANGE_EVENT_NAME, apply)

  return {
    attach,
    destroy() { window.removeEventListener(CHOSEN_CHANGE_EVENT_NAME, apply) }
  }
}
