// The texts of a shared scooter's or bike's details view, and the key that
// tells one shared vehicle from another, as pure functions of the values its
// feature carries. Nothing here reads the document or a clock.

import {assertCondition} from "./core/assert.js"

const METERS_PER_KILOMETER = 1000
const MS_PER_MINUTE = 60_000
const RANGE_FRACTION_DIGITS = 1

/** A range of `rangeMeters`, a number of at least zero, in kilometers to a tenth: "3.2 km". */
export function rangeText(rangeMeters) {
  assertCondition(typeof rangeMeters === "number", `a range is a number, got: ${rangeMeters}`)
  assertCondition(rangeMeters >= 0, `a range is not negative, got: ${rangeMeters}`)
  const kilometers = rangeMeters / METERS_PER_KILOMETER
  return `${kilometers.toFixed(RANGE_FRACTION_DIGITS)} km`
}

function rangeValue(rangeMeters) {
  if (typeof rangeMeters === "number") {
    return rangeText(rangeMeters)
  }

  return "Not published"
}

// A fetch the device's clock reads as later than now, as a skewed clock
// does, reads as recent.
function ageText({fetchedAtMs, nowMs}) {
  const minutes = Math.floor((nowMs - fetchedAtMs) / MS_PER_MINUTE)

  if (minutes < 1) {
    return "under a minute ago"
  }

  return `${minutes} min ago`
}

/**
 * A shared vehicle's view: its kind, `formLabel`, as the title; rows of
 * its range in kilometers, or that the feed publishes none, and its
 * operator; and a note that its position and range come from the
 * operator's public feed, with the age of the fetch at `nowMs`.
 */
export function sharedVehicleViewText({formLabel, rangeMeters, operatorName, fetchedAtMs, nowMs}) {
  assertCondition(typeof formLabel === "string", `a kind is text, got: ${formLabel}`)
  assertCondition(formLabel !== "", "a kind is not blank")

  const rows = [
    {key: "Range", value: rangeValue(rangeMeters)},
    {key: "Operator", value: operatorName}
  ]

  const note = `Position and range from ${operatorName}'s public feed, fetched ${ageText({fetchedAtMs, nowMs})}.`
  return {title: formLabel, rows, note}
}

/**
 * The key of a shared vehicle: its kind and its position. A feed names no
 * stable identifier a page may keep, so two vehicles of one kind at one
 * point share a key.
 */
export function sharedVehicleKey({formFactor, lon, lat}) {
  return `${formFactor}@${lon},${lat}`
}
