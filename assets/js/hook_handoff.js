// What a hook the offline host mounted hands the hook LiveView mounts on
// the same element, so the rider's view survives the handoff: the host
// keeps each instance's state by its element's identifier before it
// destroys the instance, and the new instance takes it once when it
// mounts. A hook that hands nothing over starts as it does on any page.

import {assertCondition} from "./core/assert.js"

/** The most states kept at once: one per hook element of a page, which holds far fewer. */
export const HANDOFF_COUNT_MAX = 64

/** A read of a handed-over state: found, or none. */
export const HandoffKind = Object.freeze({found: "found", none: "none"})

/** The read of an element with no state handed over, and what a hook's `handoffState` returns when it has none to hand. */
export const NO_HANDOFF = Object.freeze({kind: HandoffKind.none})

const states = new Map()

/** Keeps `state` for the next hook mounted on the element `elementId`. */
export function keepHandoffState({elementId, state}) {
  assertCondition(typeof elementId === "string", `a hook element's identifier is a text: ${elementId}`)
  assertCondition(elementId !== "", "a hook element has an identifier")
  const isWithinBound = states.size < HANDOFF_COUNT_MAX || states.has(elementId)
  assertCondition(isWithinBound, `at most ${HANDOFF_COUNT_MAX} handoff states are kept`)
  states.set(elementId, state)
}

/** The state handed over to the element `elementId`, taken once, or none. */
export function takeHandoffState(elementId) {
  assertCondition(typeof elementId === "string", `a hook element's identifier is a text: ${elementId}`)

  if (!states.has(elementId)) {
    return NO_HANDOFF
  }

  const state = states.get(elementId)
  states.delete(elementId)
  return {kind: HandoffKind.found, state}
}
