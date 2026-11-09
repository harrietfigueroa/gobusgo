// Checks the text a compact popup adds, hidden, after what it shows, so its
// accessible name holds its visible text first and then names its item and
// what a press does; and the name of its close button. Run it with
// `node test/scripts/popup_name_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {closeButtonName, popupNameSuffix} from "../../assets/js/route_chips.js"

const suffixCases = [
  {
    case: "a stop with route chips",
    given: {hasChips: true, itemName: "Pike St & 6th Ave", action: "show the stop"},
    suffix: ", Pike St & 6th Ave: show the stop"
  },
  {
    case: "a stop with no route, which shows its name",
    given: {hasChips: false, itemName: "Pike St & 6th Ave", action: "show the stop"},
    suffix: ": show the stop"
  },
  {
    case: "a vehicle with a route",
    given: {hasChips: true, itemName: "C Line to Downtown Seattle", action: "show the vehicle"},
    suffix: ", C Line to Downtown Seattle: show the vehicle"
  },
  {
    case: "a vehicle with no route, which shows its name",
    given: {hasChips: false, itemName: "Vehicle 1_6253", action: "show the vehicle"},
    suffix: ": show the vehicle"
  }
]

for (const {case: caseName, given, suffix} of suffixCases) {
  deepStrictEqual(popupNameSuffix(given), suffix, caseName)
}

deepStrictEqual(closeButtonName("Pike St & 6th Ave"), "Close Pike St & 6th Ave")

console.log(`popup names: ${suffixCases.length + 1} cases hold`)
