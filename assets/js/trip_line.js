// The line at the top of a stop's or a vehicle's details view that says
// what the chosen journey does there. It is a button at least as tall as a
// map control, and pressing it opens the Trip tab. The views own what the
// line says; this module owns the control.

import {assertCondition} from "./assert"
import {OPEN_EVENT_NAME} from "./panel_sheet"

const TRIP_LINE_CLASS_NAME = "panel-detail-trip"
const TRIP_PLANNER_ID = "trip-planner"

// Opens the Trip tab by the page's open event, sent from the Trip tab's
// panel as the trip strip sends it; the panel takes the view's place.
function openTripTab() {
  const planner = document.getElementById(TRIP_PLANNER_ID)
  assertCondition(planner !== null, "trip line: the page has no Trip tab's panel")
  planner.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true}))
}

/** A hidden line whose press opens the Trip tab. */
export function tripLineElement() {
  const line = document.createElement("button")
  line.type = "button"
  line.className = TRIP_LINE_CLASS_NAME
  line.hidden = true
  line.addEventListener("click", openTripTab)

  return line
}

/** Writes `text` into `line` and shows it, or hides and empties it for an empty `text`. */
export function writeTripLineText({line, text}) {
  const isShown = text !== ""
  line.toggleAttribute("hidden", !isShown)

  if (isShown) {
    line.replaceChildren(text)
  } else {
    line.replaceChildren()
  }
}
