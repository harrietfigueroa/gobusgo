// Checks the texts of the callout a tap opens on the map, as pure functions
// of values written out by hand: a vehicle's title and detail line, the
// hidden text after what a callout shows, so its accessible name holds its
// visible text first and then what a press does, and a stop's arrival rows.
// Run it with `node test/scripts/callout_text_check.mjs`; it exits non-zero
// on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {calloutNameSuffix, vehicleCalloutText} from "../../assets/js/callout_text.js"
import {ArrivalRowsKind, arrivalRows} from "../../assets/js/stop_arrivals.js"

const vehicle = {
  route: "E Line",
  headsign: "Aurora Village",
  schedule: "2 min late",
  nextStop: "3rd Ave & Pike St, 1 min away",
  fallbackName: "Vehicle 1_7012"
}

const vehicleCases = [
  {
    case: "a vehicle with every text",
    given: vehicle,
    text: {title: "E Line · Aurora Village", detail: "2 min late · next 3rd Ave & Pike St, 1 min away"}
  },
  {
    case: "a vehicle with no lateness",
    given: {...vehicle, schedule: null},
    text: {title: "E Line · Aurora Village", detail: "next 3rd Ave & Pike St, 1 min away"}
  },
  {
    case: "a vehicle with no next stop",
    given: {...vehicle, nextStop: null},
    text: {title: "E Line · Aurora Village", detail: "2 min late"}
  },
  {
    case: "a stale vehicle, with neither",
    given: {...vehicle, schedule: null, nextStop: null},
    text: {title: "E Line · Aurora Village", detail: ""}
  },
  {
    case: "a vehicle with no headsign",
    given: {...vehicle, headsign: null},
    text: {title: "E Line", detail: "2 min late · next 3rd Ave & Pike St, 1 min away"}
  },
  {
    case: "a vehicle with no route",
    given: {...vehicle, route: null},
    text: {title: "Aurora Village", detail: "2 min late · next 3rd Ave & Pike St, 1 min away"}
  },
  {
    case: "a vehicle with neither route nor headsign",
    given: {...vehicle, route: null, headsign: null},
    text: {title: "Vehicle 1_7012", detail: "2 min late · next 3rd Ave & Pike St, 1 min away"}
  }
]

for (const {case: caseName, given, text} of vehicleCases) {
  deepStrictEqual(vehicleCalloutText(given), text, caseName)
}

const suffixCases = [
  {case: "a stop", given: {detailName: "", action: "show the stop"}, suffix: ": show the stop"},
  {case: "a vehicle with no badge", given: {detailName: "", action: "show the vehicle"}, suffix: ": show the vehicle"},
  {case: "a stale vehicle", given: {detailName: "Stale", action: "show the vehicle"}, suffix: ", Stale: show the vehicle"}
]

for (const {case: caseName, given, suffix} of suffixCases) {
  deepStrictEqual(calloutNameSuffix(given), suffix, caseName)
}

const live = {route: "E Line", color: "#b91c1c", headsign: "Aurora Village", minutes: 2, predicted: true}
const scheduled = {route: "49", color: null, headsign: "University District", minutes: 11, predicted: false}

const rowCases = [
  {case: "waiting", shown: {status: "waiting"}, rows: {kind: ArrivalRowsKind.note, text: "Waiting for this stop's arrivals"}},
  {case: "refused", shown: {status: "refused"}, rows: {kind: ArrivalRowsKind.note, text: "No arrivals for this stop"}},
  {
    case: "busy",
    shown: {status: "busy"},
    rows: {kind: ArrivalRowsKind.note, text: "Too many stops open; close one to see this stop's arrivals"}
  },
  {
    case: "no arrival soon",
    shown: {status: "arrivals", age_minutes: 0, arrivals: []},
    rows: {kind: ArrivalRowsKind.note, text: "No arrivals soon"}
  },
  {
    case: "a live arrival on a route with a color and a scheduled one on a route with none",
    shown: {status: "arrivals", age_minutes: 0, arrivals: [live, scheduled]},
    rows: {
      kind: ArrivalRowsKind.rows,
      rows: [
        {route: "E Line", color: "#b91c1c", headsign: "Aurora Village", time: "2 min", isLive: true},
        {route: "49", color: null, headsign: "University District", time: "11 min", isLive: false}
      ]
    }
  },
  {
    case: "an arrival now, with no route and no headsign",
    shown: {status: "arrivals", age_minutes: 0, arrivals: [{route: null, color: null, headsign: null, minutes: 0, predicted: true}]},
    rows: {
      kind: ArrivalRowsKind.rows,
      rows: [{route: null, color: null, headsign: null, time: "now", isLive: true}]
    }
  }
]

for (const {case: caseName, shown, rows} of rowCases) {
  deepStrictEqual(arrivalRows(shown), rows, caseName)
}

// The saved schedules' arrivals name no color.
{
  const shown = {status: "arrivals", age_minutes: 0, scheduled: true, arrivals: [{route: "49", headsign: null, minutes: 3, predicted: false}]}
  const rows = {kind: ArrivalRowsKind.rows, rows: [{route: "49", color: null, headsign: null, time: "3 min", isLive: false}]}
  deepStrictEqual(arrivalRows(shown), rows, "an arrival with no color")
}

console.log(`callout texts: ${vehicleCases.length + suffixCases.length + rowCases.length + 1} cases hold`)
