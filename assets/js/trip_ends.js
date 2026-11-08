// The ends of a trip that the rest of the page hands to the Trip tab: a
// stop a rider chose "From here" or "To here" for, and the stop a rider
// taps on the map while the tab waits for one. Each reaches the tab as the
// "gobusgo:trip-end" DOM event on the window, naming the end and the stop.

import {assertCondition} from "./assert.js"
import {TripEnd} from "./trip_plan.js"

/** The DOM event the window gets for a stop chosen as an end of the trip. */
export const END_EVENT_NAME = "gobusgo:trip-end"

const FROM_HERE_TEXT = "From here"
const TO_HERE_TEXT = "To here"
const PickingKind =Object.freeze({none: "none", picking: "picking"})

let picking = Object.freeze({kind: PickingKind.none})

function isEnd(end) {
  return end === TripEnd.from || end === TripEnd.to
}

/** Makes the stop `stopId`, named `name`, the `end` of the trip. */
export function chooseTripEnd({end, stopId, name}) {
  assertCondition(isEnd(end), "trip ends: an end of unknown kind: " + end)
  window.dispatchEvent(new CustomEvent(END_EVENT_NAME, {detail: {end, stopId, name}}))
}

/**
 * The "From here" and "To here" buttons of the stop `stopId`, named
 * `name`, each with `className`; a click makes the stop that end of the
 * trip.
 */
export function tripEndButtons({stopId, name, className}) {
  const buttons = []

  for (const [end, text] of [[TripEnd.from, FROM_HERE_TEXT], [TripEnd.to, TO_HERE_TEXT]]) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = className
    button.textContent = text
    button.setAttribute("aria-label", `${text}: ${name}`)
    button.addEventListener("click", () => { chooseTripEnd({end, stopId, name}) })
    buttons.push(button)
  }

  return buttons
}

/** Has the next stop a rider taps on the map become the `end` of the trip. */
export function startPicking(end) {
  assertCondition(isEnd(end), "trip ends: an end of unknown kind: " + end)
  picking = Object.freeze({kind: PickingKind.picking, end})
}

/** Lets the next stop a rider taps open as any tap opens it. */
export function stopPicking() {
  picking = Object.freeze({kind: PickingKind.none})
}

/** Whether the next stop a rider taps becomes an end of the trip. */
export function isPicking() {
  return picking.kind === PickingKind.picking
}

/**
 * Makes the stop a rider tapped the end the tab waits for, which ends the
 * wait. Only while `isPicking()` holds.
 */
export function pickStop({stopId, name}) {
  assertCondition(isPicking(), "trip ends: a stop picked while no end waits for one")
  const {end} = picking
  stopPicking()
  chooseTripEnd({end, stopId, name})
}
