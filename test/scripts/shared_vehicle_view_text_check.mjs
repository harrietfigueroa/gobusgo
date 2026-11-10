// Checks the texts of a shared scooter's or bike's details view, as pure
// functions of values written out by hand: the kind as the title, the rows
// of its range and its operator, the note on where the data comes from and
// how old it is, and the key that tells one shared vehicle from another.
// Run it with `node test/scripts/shared_vehicle_view_text_check.mjs`; it
// exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {sharedVehicleKey, sharedVehicleViewText} from "../../assets/js/shared_vehicle_view_text.js"

const FETCHED_AT_MS = 1_793_000_000_000
const MS_PER_MINUTE = 60_000

function minutesLater(minutes) {
  return FETCHED_AT_MS + minutes * MS_PER_MINUTE
}

const TWO_MINUTES = 2
const HALF_A_MINUTE = 0.5
const A_MINUTE_BEFORE = -1
const scooter = {formLabel: "Scooter", rangeMeters: 3240, operatorName: "Lime", fetchedAtMs: FETCHED_AT_MS, nowMs: minutesLater(TWO_MINUTES)}
const scooterRows = [{key: "Range", value: "3.2 km"}, {key: "Operator", value: "Lime"}]
const TWO_MINUTE_NOTE = "Position and range from Lime's public feed, fetched 2 min ago."
const RECENT_NOTE = "Position and range from Lime's public feed, fetched under a minute ago."

const viewCases = [
  {
    name: "a scooter with its range, two minutes after its fetch",
    given: scooter,
    text: {title: "Scooter", rows: scooterRows, note: TWO_MINUTE_NOTE}
  },
  {
    name: "a bike whose range the feed leaves out",
    given: {...scooter, formLabel: "E-bike", rangeMeters: null},
    text: {title: "E-bike", rows: [{key: "Range", value: "Not published"}, {key: "Operator", value: "Lime"}], note: TWO_MINUTE_NOTE}
  },
  {
    name: "a fetch under a minute old",
    given: {...scooter, nowMs: minutesLater(HALF_A_MINUTE)},
    text: {title: "Scooter", rows: scooterRows, note: RECENT_NOTE}
  },
  {
    name: "a fetch after the device's clock, as a skewed clock reads it",
    given: {...scooter, nowMs: minutesLater(A_MINUTE_BEFORE)},
    text: {title: "Scooter", rows: scooterRows, note: RECENT_NOTE}
  },
  {
    name: "a range of zero",
    given: {...scooter, rangeMeters: 0},
    text: {title: "Scooter", rows: [{key: "Range", value: "0.0 km"}, {key: "Operator", value: "Lime"}], note: TWO_MINUTE_NOTE}
  }
]

for (const {name, given, text} of viewCases) {
  deepStrictEqual(sharedVehicleViewText(given), text, name)
}

function negativeRange() {
  return sharedVehicleViewText({...scooter, rangeMeters: -1})
}

function blankTitle() {
  return sharedVehicleViewText({...scooter, formLabel: ""})
}

throws(negativeRange, "a negative range is refused")
throws(blankTitle, "a blank kind is refused")

const keyCases = [
  {name: "a scooter at a point", given: {formFactor: "scooter", lon: -122.3321, lat: 47.6062}, key: "scooter@-122.3321,47.6062"},
  {name: "a bike at the same point", given: {formFactor: "bicycle", lon: -122.3321, lat: 47.6062}, key: "bicycle@-122.3321,47.6062"}
]

for (const {name, given, key} of keyCases) {
  deepStrictEqual(sharedVehicleKey(given), key, name)
}

const REFUSAL_CASE_COUNT = 2
const caseCount = viewCases.length + keyCases.length + REFUSAL_CASE_COUNT
console.log(`shared vehicle view texts: ${caseCount} cases hold`)
