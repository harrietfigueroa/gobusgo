// Checks what the Trip tab decides as pure functions of journeys written
// out by hand in the router's shape: the journey list's order and texts,
// the "Tomorrow" label of a journey on the next service date, whether two
// ends make a query, the names the page is asked for, the routes of a
// trip's filter, and what the map draws of a journey. Run it with
// `node test/scripts/trip_plan_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {LegKind} from "../../assets/js/routing_engine.js"
import {FailureReason, JourneysKind} from "../../assets/js/routing_journeys.js"
import {
  BoundsKind,
  EndKind,
  FeatureKind,
  LOCATION_END,
  NO_END,
  QueryKind,
  ROUTE_COLOR_DEFAULT,
  StateKind,
  failureState,
  journeyFeatures,
  journeyRows,
  journeysAnnouncement,
  nameRequest,
  queryOf,
  pickingMessage,
  stateMessage,
  stopEnd,
  swappedEnds,
  tripRouteIds,
  windowText,
} from "../../assets/js/trip_plan.js"

const TIME_ZONE = "America/Los_Angeles"
// 2026-11-08 and 2026-11-09 at midnight in Seattle, eight hours after
// midnight UTC.
const TODAY_START_MS = 1794124800000
const DAY_MS = 24 * 60 * 60 * 1000
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const TOMORROW_START_MS = TODAY_START_MS + DAY_MS
const serviceDayStartsMs = {"2026-11-08": TODAY_START_MS, "2026-11-09": TOMORROW_START_MS}
const departure = {serviceDate: "2026-11-08", departureS: seconds("08:38")}
const ROUTE_COUNT_MAX = 6
const ROUTE_COUNT_MAX_ONE = 1
const NAME_COUNT_MAX = 10
const NAME_COUNT_MAX_TWO = 2

// The stops' positions, written as the router hands them over, in degrees.
const PIKE = {lat: 47.61, lon: -122.34}
const PASSED = {lat: 47.6, lon: -122.33}
const CHERRY = {lat: 47.6, lon: -122.33}
const JACKSON = {lat: 47.59, lon: -122.33}
const OTHELLO = {lat: 47.54, lon: -122.28}
const RIDER = {lat: 47.612, lon: -122.341}

function lonLat({lat, lon}) {
  return [lon, lat]
}

function seconds(clock) {
  const [hours, minutes] = clock.split(":")
  return Number(hours) * HOUR_SECONDS + Number(minutes) * MINUTE_SECONDS
}

function journeyOf(row) {
  return row.journey
}

function kindOf(feature) {
  return feature.properties.kind
}

function featureCount(collection) {
  return collection.features.length
}

function ride({routeId, from, departs, to, arrives, passing = []}) {
  return {kind: LegKind.ride, tripId: `trip-${routeId}`, routeId, serviceDayOffset: 0, fromStopId: from, departureS: seconds(departs), toStopId: to, arrivalS: seconds(arrives), stopIds: [from, ...passing, to]}
}

function walk({from, to, durationS}) {
  return {kind: LegKind.walk, fromStopId: from, toStopId: to, durationS}
}

// The earliest journey changes once, from E to 36 after a three-minute
// walk; a later one rides 7 alone.
const earliest = {
  serviceDate: "2026-11-08",
  arrivalS: seconds("09:02"),
  changes: 1,
  isEarliest: true,
  legs: [
    ride({routeId: "1_102576", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51", passing: ["1_440"]}),
    walk({from: "1_1121", to: "1_1500", durationS: 170}),
    ride({routeId: "1_100210", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02"}),
  ],
  stopPositions: {"1_431": PIKE, "1_440": PASSED, "1_1121": CHERRY, "1_1500": JACKSON, "1_11920": OTHELLO},
}

const direct = {
  serviceDate: "2026-11-08",
  arrivalS: seconds("09:14"),
  changes: 0,
  isEarliest: false,
  legs: [ride({routeId: "1_100275", from: "1_431", departs: "08:46", to: "1_11920", arrives: "09:14"})],
  stopPositions: {"1_431": PIKE, "1_11920": OTHELLO},
}

const names = {
  stops: {
    "1_431": {name: "3rd Ave & Pike St", code: "431"},
    "1_1121": {name: "3rd Ave & Cherry St", code: null},
    "1_1500": {name: "4th Ave S & Jackson St", code: null},
    "1_11920": {name: "Rainier Ave S & S Othello St", code: null},
  },
  routes: {"1_102576": {name: "E", color: "#1D4ED8"}, "1_100210": {name: "36", color: "#EA580C"}},
}

// The list: fewest changes first, whatever order the router gives.
const rows = journeyRows({journeys: [earliest, direct], departure, serviceDayStartsMs, names, timeZone: TIME_ZONE})
const ordered = Array.from(rows, journeyOf)
deepStrictEqual(ordered, [direct, earliest], "the order: fewest changes first")
deepStrictEqual(rows[1].timesText, "8:42 am → 9:02 am", "the earliest's times")
deepStrictEqual(rows[1].badgeText, "Earliest · 20 min", "the earliest is marked")
deepStrictEqual(rows[0].badgeText, "28 min", "a later journey is not marked")
deepStrictEqual(rows[1].changesText, "1 change", "one change")
deepStrictEqual(rows[0].changesText, "No change", "no change")

deepStrictEqual(rows[1].summary, [
  {kind: LegKind.ride, chip: {name: "E", color: "#1D4ED8"}},
  {kind: LegKind.walk, text: "walk 3 min"},
  {kind: LegKind.ride, chip: {name: "36", color: "#EA580C"}},
], "the earliest's summary")

deepStrictEqual(rows[1].steps, [
  "8:42 am board E at 3rd Ave & Pike St",
  "8:51 am get off at 3rd Ave & Cherry St",
  "walk 3 min to 4th Ave S & Jackson St",
  "8:56 am board 36 at 4th Ave S & Jackson St",
  "9:02 am arrive at Rainier Ave S & S Othello St",
], "the earliest's steps")

// A route and a stop the page has not named read as their identifiers.
deepStrictEqual(rows[0].summary, [{kind: LegKind.ride, chip: {name: "1_100275", color: ROUTE_COLOR_DEFAULT}}], "an unnamed route")
const unnamed = journeyRows({journeys: [direct], departure, serviceDayStartsMs, names: {stops: {}, routes: {}}, timeZone: TIME_ZONE})
deepStrictEqual(unnamed[0].steps[0], "8:46 am board 1_100275 at 1_431", "an unnamed stop")

// A journey on the next service date reads "Tomorrow" before its time.
const tomorrow = {...direct, serviceDate: "2026-11-09", isEarliest: true, arrivalS: seconds("05:40"), legs: [ride({routeId: "1_100275", from: "1_431", departs: "05:12", to: "1_11920", arrives: "05:40"})]}
const lateDeparture = {serviceDate: "2026-11-08", departureS: seconds("23:30")}
const [tomorrowRow] = journeyRows({journeys: [tomorrow], departure: lateDeparture, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(tomorrowRow.timesText, "Tomorrow 5:12 am → 5:40 am", "the next service date")

// A journey past midnight of the departure's own service date is not tomorrow's.
const pastMidnight = {...tomorrow, serviceDate: "2026-11-08", arrivalS: seconds("24:30"), legs: [ride({routeId: "1_100275", from: "1_431", departs: "23:50", to: "1_11920", arrives: "24:30"})]}
const [pastMidnightRow] = journeyRows({journeys: [pastMidnight], departure: lateDeparture, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(pastMidnightRow.timesText, "11:50 pm → 12:30 am", "past midnight of the same service date")

// The status line a screen reader hears once the journeys are written.
deepStrictEqual(journeysAnnouncement(rows), "2 journeys. The earliest arrives at 9:02 am.", "several journeys")
deepStrictEqual(journeysAnnouncement([rows[1]]), "1 journey. It arrives at 9:02 am.", "one journey")
deepStrictEqual(journeysAnnouncement([tomorrowRow]), "1 journey. It arrives tomorrow at 5:40 am.", "a journey on the next service date")
deepStrictEqual(journeysAnnouncement([pastMidnightRow]), "1 journey. It arrives at 12:30 am.", "past midnight of the same service date")

// The window line names the earliest arrival plus 45 minutes.
deepStrictEqual(windowText({journeys: [earliest, direct], serviceDayStartsMs, timeZone: TIME_ZONE}), "Leaving now · journeys arriving by 9:47 am", "the window")

// Two ends make a query once From is set and To is a stop, and never from
// a stop to itself.
const pike = stopEnd({stopId: "1_431", name: "3rd Ave & Pike St"})
const othello = stopEnd({stopId: "1_11920", name: "Rainier Ave S & S Othello St"})

const queryCases = [
  {name: "no end", ends: {from: NO_END, to: NO_END}, expected: {kind: QueryKind.incomplete}},
  {name: "no To", ends: {from: LOCATION_END, to: NO_END}, expected: {kind: QueryKind.incomplete}},
  {name: "no From", ends: {from: NO_END, to: othello}, expected: {kind: QueryKind.incomplete}},
  {name: "one stop at both ends", ends: {from: pike, to: pike}, expected: {kind: QueryKind.sameStop}},
  {name: "from a stop", ends: {from: pike, to: othello}, expected: {kind: QueryKind.ready, from: pike, toStopId: "1_11920"}},
  {name: "from the location", ends: {from: LOCATION_END, to: othello}, expected: {kind: QueryKind.ready, from: LOCATION_END, toStopId: "1_11920"}},
]

for (const {name, ends, expected} of queryCases) {
  deepStrictEqual(queryOf(ends), expected, `query: ${name}`)
}

// A swap moves each end to the other field, and the location, a From end
// alone, leaves To empty.
deepStrictEqual(swappedEnds({from: pike, to: othello}), {from: othello, to: pike}, "swap two stops")
deepStrictEqual(swappedEnds({from: LOCATION_END, to: othello}), {from: othello, to: NO_END}, "swap from the location")
deepStrictEqual(swappedEnds({from: NO_END, to: othello}).from.kind, EndKind.stop, "swap into an empty From")

// Every state has its headline and its caption.
const stateMessageCases = [
  {kind: StateKind.loading, expected: {headline: "Finding journeys…", caption: "Searching today's and tomorrow's schedules."}},
  {kind: StateKind.noServiceDate, expected: {headline: "No schedule for this time yet", caption: "Try again later."}},
  {kind: StateKind.locationDenied, expected: {headline: "Location is off", caption: "Start from a stop instead, or allow location in your browser's settings."}},
  {kind: StateKind.locationUnavailable, expected: {headline: "Can't find your location", caption: "Start from a stop instead, or try again."}},
  {kind: StateKind.sameStop, expected: {headline: "From and To are the same stop", caption: "Choose another stop for one of them."}},
  {kind: StateKind.notSaved, expected: {headline: "Not saved for offline", caption: "Connect to plan this trip."}},
  {kind: JourneysKind.none, expected: {headline: "No journeys found", caption: "Nothing runs between these two today or tomorrow."}},
  {kind: JourneysKind.unknownStop, expected: {headline: "Stop not in the schedules", caption: "Choose another stop nearby."}},
  {kind: JourneysKind.noStartStop, expected: {headline: "No stop within a walk", caption: "Start from a stop instead."}},
  {kind: JourneysKind.failed, expected: {headline: "Journeys didn't load", caption: "Check your connection and try again."}}
]

for (const {kind, expected} of stateMessageCases) {
  deepStrictEqual(stateMessage(kind), expected, `state message: ${kind}`)
}

const routerStateKinds = [JourneysKind.none, JourneysKind.unknownStop, JourneysKind.noStartStop, JourneysKind.failed]
const stateKindCount = Object.keys(StateKind).length + routerStateKinds.length
deepStrictEqual(stateMessageCases.length, stateKindCount, "every state of the tab and of the router has a case")

deepStrictEqual(
  pickingMessage("From"),
  {headline: "Pick a stop for From", caption: "Tap a stop on the map. Stops show once the map is zoomed in."},
  "the message while a stop is picked"
)

// A query whose schedules are not saved says so, and any other failure says it failed.
deepStrictEqual(failureState({kind: JourneysKind.failed, reason: FailureReason.notSaved, path: ""}), StateKind.notSaved, "a schedule not saved")
deepStrictEqual(failureState({kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: ""}), JourneysKind.failed, "a fetch that failed")

// The names asked for are the stops a leg boards, leaves, or walks between,
// not the stops a ride only passes, and each ride's route, each once.
deepStrictEqual(nameRequest({journeys: [earliest, direct], countMax: NAME_COUNT_MAX}), {
  stopIds: ["1_431", "1_1121", "1_1500", "1_11920"],
  routeIds: ["1_102576", "1_100210", "1_100275"],
}, "the names asked for")

deepStrictEqual(nameRequest({journeys: [earliest, direct], countMax: NAME_COUNT_MAX_TWO}), {stopIds: ["1_431", "1_1121"], routeIds: ["1_102576", "1_100210"]}, "the names asked for within the bound")

// A trip's filter names the routes the journey rides, once each, in riding
// order; a walk alone names none.
const twice = {...earliest, legs: [...earliest.legs, ride({routeId: "1_102576", from: "1_11920", departs: "09:10", to: "1_431", arrives: "09:30"})]}
deepStrictEqual(tripRouteIds({journey: earliest, countMax: ROUTE_COUNT_MAX}), ["1_102576", "1_100210"], "the trip's routes")
deepStrictEqual(tripRouteIds({journey: twice, countMax: ROUTE_COUNT_MAX}), ["1_102576", "1_100210"], "a route ridden twice")
deepStrictEqual(tripRouteIds({journey: {...earliest, legs: [walk({from: "1_431", to: "1_440", durationS: 60})]}, countMax: ROUTE_COUNT_MAX}), [], "a walk alone")
function tooManyRoutes() {
  return tripRouteIds({journey: earliest, countMax: ROUTE_COUNT_MAX_ONE})
}

throws(tooManyRoutes, AssertionError, "more routes than the bound")

// The map draws a line per ride through every stop it passes, in its
// route's color, a line per walk, and the two ends.
const drawn = journeyFeatures({journey: earliest, names, origin: null})
const drawnKinds = Array.from(drawn.collection.features, kindOf)
deepStrictEqual(drawnKinds, [FeatureKind.ride, FeatureKind.walk, FeatureKind.ride, FeatureKind.origin, FeatureKind.destination], "the features")
const [firstRide, , , , destination] = drawn.collection.features
deepStrictEqual(firstRide.geometry.coordinates, [lonLat(PIKE), lonLat(PASSED), lonLat(CHERRY)], "a ride through its stops")
deepStrictEqual(firstRide.properties.color, "#1D4ED8", "a ride in its route's color")
deepStrictEqual(destination.geometry.coordinates, lonLat(OTHELLO), "the destination")
deepStrictEqual(drawn.bounds, {kind: BoundsKind.bounds, bounds: [[PIKE.lon, OTHELLO.lat], [OTHELLO.lon, PIKE.lat]]}, "the bounds")

// A journey from the rider's position starts its first walk there.
const located = {...direct, legs: [{kind: LegKind.walkFromPosition, toStopId: "1_431", durationS: 240}, ...direct.legs]}
const fromRider = journeyFeatures({journey: located, names, origin: RIDER})
const [walkFromRider, , origin] = fromRider.collection.features
deepStrictEqual(walkFromRider.geometry.coordinates, [lonLat(RIDER), lonLat(PIKE)], "a walk from the position")
deepStrictEqual(origin.geometry.coordinates, lonLat(RIDER), "the origin at the position")

// A journey whose stops have no known position draws nothing.
const unplaced = journeyFeatures({journey: {...direct, stopPositions: {}}, names, origin: null})
deepStrictEqual(featureCount(unplaced.collection), 0, "no position draws no feature")
deepStrictEqual(unplaced.bounds, {kind: BoundsKind.none}, "no position has no bounds")

console.log("trip plan: every case holds")
