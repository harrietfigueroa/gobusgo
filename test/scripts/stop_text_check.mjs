// Checks the texts of the stop view in the glanceable style, as pure
// functions of values written out by hand: the pills of a stop's code and
// direction, the key line under its arrivals with what a screen reader
// reads in its place, and the title of the list of stops under a tap. Run
// it with `node test/scripts/stop_text_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {PillKind, arrivalsKey, codePill, directionPill, stopListTitle} from "../../assets/js/stop_text.js"

const directionCases = [
  {direction: "N", pill: {kind: PillKind.shown, mark: "↑", text: "North"}},
  {direction: "NE", pill: {kind: PillKind.shown, mark: "↗", text: "Northeast"}},
  {direction: "E", pill: {kind: PillKind.shown, mark: "→", text: "East"}},
  {direction: "SE", pill: {kind: PillKind.shown, mark: "↘", text: "Southeast"}},
  {direction: "S", pill: {kind: PillKind.shown, mark: "↓", text: "South"}},
  {direction: "SW", pill: {kind: PillKind.shown, mark: "↙", text: "Southwest"}},
  {direction: "W", pill: {kind: PillKind.shown, mark: "←", text: "West"}},
  {direction: "NW", pill: {kind: PillKind.shown, mark: "↖", text: "Northwest"}},
  {direction: "Inbound", pill: {kind: PillKind.shown, mark: "", text: "Inbound"}},
  {direction: "", pill: {kind: PillKind.absent}},
  {direction: undefined, pill: {kind: PillKind.absent}}
]

for (const {direction, pill} of directionCases) {
  deepStrictEqual(directionPill(direction), pill, `direction ${String(direction)}`)
}

const codeCases = [
  {code: "575", pill: {kind: PillKind.shown, mark: "#", text: "575"}},
  {code: "", pill: {kind: PillKind.absent}},
  {code: undefined, pill: {kind: PillKind.absent}}
]

for (const {code, pill} of codeCases) {
  deepStrictEqual(codePill(code), pill, `code ${String(code)}`)
}

const keyCases = [
  {
    case: "a fetch made now",
    given: {ageMinutes: 0, isScheduled: false},
    key: {
      shown: "live · plain = scheduled · updated now",
      spoken: "Times with a dot are live; plain times are scheduled. Updated now."
    }
  },
  {
    case: "a fetch a minute old",
    given: {ageMinutes: 1, isScheduled: false},
    key: {
      shown: "live · plain = scheduled · updated 1 min ago",
      spoken: "Times with a dot are live; plain times are scheduled. Updated 1 min ago."
    }
  },
  {
    case: "the saved schedules' arrivals",
    given: {ageMinutes: 0, isScheduled: true},
    key: {
      shown: "scheduled times from the saved schedules",
      spoken: "Scheduled times from the saved schedules."
    }
  }
]

for (const {case: caseName, given, key} of keyCases) {
  deepStrictEqual(arrivalsKey(given), key, caseName)
}

const TWO_STOPS = 2
const TWELVE_STOPS = 12
const titleCases = [
  {count: TWO_STOPS, title: "2 stops here"},
  {count: TWELVE_STOPS, title: "12 stops here"}
]

for (const {count, title} of titleCases) {
  deepStrictEqual(stopListTitle(count), title, `the list's title for ${count} stops`)
}

function titleOfOneStop() {
  stopListTitle(1)
}

throws(titleOfOneStop, "a list of one stop has no title")

const TITLE_REFUSAL_COUNT = 1
console.log(`stop texts: ${directionCases.length + codeCases.length + keyCases.length + titleCases.length + TITLE_REFUSAL_COUNT} cases hold`)
