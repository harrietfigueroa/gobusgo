// The texts of the stop view in the glanceable style, as pure functions of a
// stop's texts and its arrivals' age. Nothing here reads the document.

import {assertCondition} from "#core/assert.js"
import {LIST_COUNT_MIN} from "./map_selection.js"

/** Whether a pill is shown, with its mark and its text, or absent. */
export const PillKind = Object.freeze({shown: "shown", absent: "absent"})

// The arrow and the word of each compass direction OneBusAway gives a stop.
// https://developer.onebusaway.org/api/where/elements/stop — checked 2026-11-09
const directions = Object.freeze({
  N: {mark: "↑", text: "North"},
  NE: {mark: "↗", text: "Northeast"},
  E: {mark: "→", text: "East"},
  SE: {mark: "↘", text: "Southeast"},
  S: {mark: "↓", text: "South"},
  SW: {mark: "↙", text: "Southwest"},
  W: {mark: "←", text: "West"},
  NW: {mark: "↖", text: "Northwest"}
})

function isText(value) {
  return typeof value === "string" && value !== ""
}

/**
 * The pill of a stop's `direction`: the arrow and the word of a compass
 * direction, the text alone of any other, and absent for none.
 */
export function directionPill(direction) {
  if (!isText(direction)) {
    return {kind: PillKind.absent}
  }

  if (Object.hasOwn(directions, direction)) {
    return {kind: PillKind.shown, ...directions[direction]}
  }

  return {kind: PillKind.shown, mark: "", text: direction}
}

/** The title of the list of the `count` stops under a tap, "4 stops here"; a list holds two or more. */
export function stopListTitle(count) {
  assertCondition(Number.isSafeInteger(count), `a list's stop count is an integer, got: ${count}`)
  assertCondition(count >= LIST_COUNT_MIN, `a list holds at least ${LIST_COUNT_MIN} stops, got: ${count}`)
  return `${count} stops here`
}

/** The line under a list of stops that leaves `restCount` of them out, "and 2 more". */
export function stopListRestText(restCount) {
  assertCondition(Number.isSafeInteger(restCount), `a list's left-out count is an integer, got: ${restCount}`)
  assertCondition(restCount >= 1, `a list leaves out at least one stop, got: ${restCount}`)
  return `and ${restCount} more`
}

/** The pill of a stop's `code`, "#" before it, and absent for none. */
export function codePill(code) {
  if (!isText(code)) {
    return {kind: PillKind.absent}
  }

  return {kind: PillKind.shown, mark: "#", text: code}
}

function updatedText(ageMinutes) {
  if (ageMinutes >= 1) {
    return `${ageMinutes} min ago`
  }

  return "now"
}

/**
 * The key under a stop's arrivals: the line shown beside a live dot, and the
 * sentences a screen reader reads in its place. The server's arrivals are
 * from a fetch `ageMinutes` old; the saved schedules' are all scheduled.
 */
export function arrivalsKey({ageMinutes, isScheduled}) {
  if (isScheduled) {
    return {
      shown: "scheduled times from the saved schedules",
      spoken: "Scheduled times from the saved schedules."
    }
  }

  const updated = updatedText(ageMinutes)

  return {
    shown: `live · plain = scheduled · updated ${updated}`,
    spoken: `Times with a dot are live; plain times are scheduled. Updated ${updated}.`
  }
}
