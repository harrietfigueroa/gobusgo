// The bar of a journey as an element, drawn for the eye: each walk, wait,
// and ride as wide as it takes, a ride in its route's color with its name.
// The bar is hidden from assistive technology, so whatever holds it also
// holds the text it shows.

import {SegmentKind} from "./journey_cards"
import {chipTextColor} from "./route_chip_color"

/** The bar of `segments`, from `barSegments`, as a span hidden from assistive technology. */
export function barElement(segments) {
  const bar = document.createElement("span")
  bar.className = "trip-bar"
  bar.setAttribute("aria-hidden", "true")

  for (const segment of segments) {
    const part = document.createElement("span")
    part.className = `trip-bar-segment trip-bar-${segment.kind}`
    part.style.flexGrow = String(segment.durationS)

    if (segment.kind === SegmentKind.ride) {
      part.textContent = segment.name
      part.style.backgroundColor = segment.color
      part.style.color = chipTextColor(segment.color)
    }

    bar.append(part)
  }

  return bar
}
