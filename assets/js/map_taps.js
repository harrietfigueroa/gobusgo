// Answers a tap on the empty part of each map the basemap announces: while
// the details view shows an item, a tap that hits no vehicle, stop, or
// shared vehicle deselects it, which the panel sheet closes the view for.
// A tap on an item is the item's own hook's to answer.

import {READY_EVENT_NAME} from "./basemap"
import {isItemAt} from "./map_view_reading"
import {TapOutcome, tapOutcome} from "./map_selection"
import {DESELECT_EVENT_NAME, DetailKind, shownDetail} from "./panel_detail"

// MapLibre fires `click` only for a press and release within its click
// tolerance of each other, so the end of a pan, a zoom, or a rotation is no
// tap and closes nothing.
// https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/MapOptions/#clicktolerance — checked 2026-11-10
function answerTap({map, event}) {
  const isItemHit = isItemAt({map, point: event.point})
  const isShowing = shownDetail().kind !== DetailKind.none
  const outcome = tapOutcome({isItemHit, isShowing})

  if (outcome === TapOutcome.deselect) {
    window.dispatchEvent(new CustomEvent(DESELECT_EVENT_NAME))
  }
}

function attachTaps(map) {
  map.on("click", (event) => { answerTap({map, event}) })
}

function attachTapsCallback(event) {
  attachTaps(event.detail.map)
}

/** Answers the taps on every map the basemap announces from now on. */
export function watchMapTaps() {
  window.addEventListener(READY_EVENT_NAME, attachTapsCallback)
}
