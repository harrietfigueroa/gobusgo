// Checks what the details view of the panel sheet decides as pure functions
// of values written out by hand: the next-arrival text the Favorites badge
// shows, which arrival rows carry the live dot, and how far the map moves
// to bring the view's item out from under the sheet. Run it with
// `node test/scripts/panel_detail_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {revealOffset} from "../../assets/js/reveal_offset.js"
import {arrivalRows, isNextArrivalLive, nextArrivalText, nextArrivalTimeText} from "../../assets/js/stop_arrivals.js"

const arrival = {route: "E", headsign: "Aurora Village", minutes: 2, predicted: true}

const arrivalCases = [
  {name: "waiting", shown: {status: "waiting"}, time: "", text: ""},
  {name: "busy", shown: {status: "busy"}, time: "", text: ""},
  {name: "no arrival soon", shown: {status: "arrivals", age_minutes: 0, arrivals: []}, time: "", text: ""},
  {name: "an arrival in minutes", shown: {status: "arrivals", age_minutes: 0, arrivals: [arrival]}, time: "2 min", text: "E 2 min"},
  {name: "an arrival now", shown: {status: "arrivals", age_minutes: 0, arrivals: [{...arrival, minutes: 0}]}, time: "now", text: "E now"},
  {name: "an arrival with no route", shown: {status: "arrivals", age_minutes: 0, arrivals: [{...arrival, route: null}]}, time: "2 min", text: "2 min"}
]

for (const {name, shown, time, text} of arrivalCases) {
  deepStrictEqual(nextArrivalTimeText(shown), time, `time: ${name}`)
  deepStrictEqual(nextArrivalText(shown), text, `text: ${name}`)
}

const scheduledArrival = {...arrival, route: "5", headsign: "Shoreline", minutes: 7, predicted: false}

const liveCases = [
  {
    name: "a predicted and a scheduled arrival",
    shown: {status: "arrivals", age_minutes: 0, arrivals: [arrival, scheduledArrival]},
    live: [true, false],
    isNextLive: true
  },
  {
    name: "a scheduled arrival first",
    shown: {status: "arrivals", age_minutes: 2, arrivals: [scheduledArrival, arrival]},
    live: [false, true],
    isNextLive: false
  },
  {
    name: "the saved schedules' arrivals",
    shown: {status: "arrivals", age_minutes: 0, scheduled: true, arrivals: [scheduledArrival]},
    live: [false],
    isNextLive: false
  },
  {
    name: "no arrival soon",
    shown: {status: "arrivals", age_minutes: 0, arrivals: []},
    live: [],
    isNextLive: false
  },
  {
    name: "waiting",
    shown: {status: "waiting"},
    live: [],
    isNextLive: false
  }
]

function rowIsLive(row) {
  return row.isLive
}

function rowsLive(shown) {
  const rows = arrivalRows(shown)

  if (rows.kind === "rows") {
    return Array.from(rows.rows, rowIsLive)
  }

  return []
}

for (const {name, shown, live, isNextLive} of liveCases) {
  deepStrictEqual(rowsLive(shown), live, `live dots: ${name}`)
  deepStrictEqual(isNextArrivalLive(shown), isNextLive, `next live: ${name}`)
}

const MARGIN_PIXELS = 96
const phone = {viewWidth: 390, viewHeight: 844, insets: {left: 0, bottom: 506}}
const desktop = {viewWidth: 1280, viewHeight: 800, insets: {left: 372, bottom: 0}}

const revealCases = [
  {name: "a point above a phone's sheet", view: phone, point: {x: 200, y: 150}, expected: {x: 0, y: 0}},
  {name: "a point under a phone's sheet", view: phone, point: {x: 200, y: 600}, expected: {x: 0, y: 431}},
  {name: "a point just above a phone's sheet", view: phone, point: {x: 200, y: 300}, expected: {x: 0, y: 131}},
  {name: "a point beside a desktop's panel", view: desktop, point: {x: 800, y: 400}, expected: {x: 0, y: 0}},
  {name: "a point under a desktop's panel", view: desktop, point: {x: 200, y: 400}, expected: {x: -626, y: 0}}
]

for (const {name, view, point, expected} of revealCases) {
  deepStrictEqual(revealOffset({...view, point, marginPixels: MARGIN_PIXELS}), expected, name)
}

const caseCount = arrivalCases.length + liveCases.length + revealCases.length
console.log(`${caseCount} cases passed`)
