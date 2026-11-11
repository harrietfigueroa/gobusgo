// Checks what the Trip tab decides as pure functions of journeys written
// out by hand in the router's shape: the journey list's order and texts,
// the "Tomorrow" label of a journey that leaves on the next day, whether two
// ends make a query, the time a query leaves at or arrives by and its
// window line, the names the page is asked for, the routes of a trip's
// filter, and what the map draws of a journey. Run it with
// `node test/scripts/trip_plan_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {LegKind} from "../../assets/js/routing_engine.js"
import {FailureReason, JourneysKind} from "../../assets/js/routing_journeys.js"
import {
  BoundsKind,
  ClockKind,
  EndKind,
  FeatureKind,
  LOCATION_END,
  NO_END,
  QueryKind,
  ROUTE_COLOR_DEFAULT,
  DayChoice,
  PlannedKind,
  StateKind,
  TimeMode,
  defaultClock,
  failureState,
  journeyFeatures,
  journeyRows,
  journeysAnnouncement,
  nameRequest,
  queryOf,
  pickingMessage,
  plannedTime,
  stateMessage,
  stopEnd,
  swappedEnds,
  tripRouteIds,
  wallClockMs,
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
const SECOND_MS = 1000
const NOW_MS = TODAY_START_MS + seconds("08:38") * SECOND_MS
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
const rows = journeyRows({journeys: [earliest, direct], nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
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
const unnamed = journeyRows({journeys: [direct], nowMs: NOW_MS, serviceDayStartsMs, names: {stops: {}, routes: {}}, timeZone: TIME_ZONE})
deepStrictEqual(unnamed[0].steps[0], "8:46 am board 1_100275 at 1_431", "an unnamed stop")

// A journey that leaves on the next day reads "Tomorrow" before its time.
const tomorrow = {...direct, serviceDate: "2026-11-09", isEarliest: true, arrivalS: seconds("05:40"), legs: [ride({routeId: "1_100275", from: "1_431", departs: "05:12", to: "1_11920", arrives: "05:40"})]}
const LATE_NOW_MS = TODAY_START_MS + seconds("23:30") * SECOND_MS
const [tomorrowRow] = journeyRows({journeys: [tomorrow], nowMs: LATE_NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(tomorrowRow.timesText, "Tomorrow 5:12 am → 5:40 am", "the next service date")

// A journey that leaves before midnight and arrives after it is today's.
const pastMidnight = {...tomorrow, serviceDate: "2026-11-08", arrivalS: seconds("24:30"), legs: [ride({routeId: "1_100275", from: "1_431", departs: "23:50", to: "1_11920", arrives: "24:30"})]}
const [pastMidnightRow] = journeyRows({journeys: [pastMidnight], nowMs: LATE_NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(pastMidnightRow.timesText, "11:50 pm → 12:30 am", "past midnight of the same service date")

// A journey of today's service date that leaves past midnight leaves tomorrow.
const owl = {...pastMidnight, arrivalS: seconds("24:50"), legs: [ride({routeId: "1_100275", from: "1_431", departs: "24:10", to: "1_11920", arrives: "24:50"})]}
const [owlRow] = journeyRows({journeys: [owl], nowMs: LATE_NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(owlRow.timesText, "Tomorrow 12:10 am → 12:50 am", "leaving past midnight of the same service date")

// A journey two days on names its weekday.
const later = {...tomorrow, legs: [ride({routeId: "1_100275", from: "1_431", departs: "29:12", to: "1_11920", arrives: "29:40"})], arrivalS: seconds("29:40")}
const [laterRow] = journeyRows({journeys: [later], nowMs: LATE_NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(laterRow.timesText, "Tue 5:12 am → 5:40 am", "two days on")

// A walk alone leaves its walk before it arrives.
const walkOnly = {serviceDate: "2026-11-08", arrivalS: seconds("08:50"), changes: 0, isEarliest: true, legs: [walk({from: "1_431", to: "1_440", durationS: 300})], stopPositions: {}}
const [walkOnlyRow] = journeyRows({journeys: [walkOnly], nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(walkOnlyRow.timesText, "8:45 am → 8:50 am", "a walk alone")

// Arriving by a time, the latest journey is marked, and a journey leaves at
// the time the router found.
const latest = {...direct, isEarliest: undefined, isLatest: true, departureS: seconds("08:46")}
const sooner = {...earliest, isEarliest: undefined, isLatest: false, departureS: seconds("08:42")}
const arrivingRows = journeyRows({journeys: [sooner, latest], nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
deepStrictEqual(arrivingRows[0].badgeText, "Latest · 28 min", "the latest is marked")
deepStrictEqual(arrivingRows[0].isMarked, true, "the latest is the marked row")
deepStrictEqual(arrivingRows[1].badgeText, "20 min", "a sooner journey is not marked")
deepStrictEqual(journeysAnnouncement(arrivingRows), "2 journeys. The latest leaves at 8:46 am.", "several journeys arriving by a time")
deepStrictEqual(journeysAnnouncement([arrivingRows[0]]), "1 journey. It leaves at 8:46 am.", "one journey arriving by a time")

// The status line a screen reader hears once the journeys are written.
deepStrictEqual(journeysAnnouncement(rows), "2 journeys. The earliest arrives at 9:02 am.", "several journeys")
deepStrictEqual(journeysAnnouncement([rows[1]]), "1 journey. It arrives at 9:02 am.", "one journey")
deepStrictEqual(journeysAnnouncement([tomorrowRow]), "1 journey. It arrives tomorrow at 5:40 am.", "a journey on the next service date")
deepStrictEqual(journeysAnnouncement([pastMidnightRow]), "1 journey. It arrives at 12:30 am.", "past midnight of the same service date")

// The window line names the mode and the time chosen, with the earliest
// arrival plus 45 minutes, or the latest departure less 45 minutes.
const NINE_TOMORROW_MS = TOMORROW_START_MS + seconds("09:00") * SECOND_MS
const HALF_EIGHT_MS = TODAY_START_MS + seconds("08:30") * SECOND_MS
const leavingWindow = {journeys: [earliest, direct], nowMs: NOW_MS, serviceDayStartsMs, timeZone: TIME_ZONE}

const windowCases = [
  {name: "now", planned: {kind: PlannedKind.leaving, mode: TimeMode.now, ms: NOW_MS}, journeys: [earliest, direct], expected: "Leaving now · journeys arriving by 9:47 am"},
  {name: "a departure today", planned: {kind: PlannedKind.leaving, mode: TimeMode.departAt, ms: HALF_EIGHT_MS}, journeys: [earliest, direct], expected: "Leaving at 8:30 am · journeys arriving by 9:47 am"},
  {name: "a departure tomorrow", planned: {kind: PlannedKind.leaving, mode: TimeMode.departAt, ms: TOMORROW_START_MS + seconds("05:00") * SECOND_MS}, journeys: [tomorrow], expected: "Leaving at 5:00 am tomorrow · journeys arriving by 6:25 am"},
  {name: "an arrival tomorrow", planned: {kind: PlannedKind.arrivingBy, mode: TimeMode.arriveBy, ms: NINE_TOMORROW_MS}, journeys: [{...latest, serviceDate: "2026-11-09"}, {...sooner, serviceDate: "2026-11-09"}], expected: "Arriving by 9:00 am tomorrow · journeys leaving from 8:01 am"},
]

for (const {name, planned, journeys, expected} of windowCases) {
  deepStrictEqual(windowText({...leavingWindow, journeys, planned}), expected, `the window: ${name}`)
}

// A time on the page's clock, a day and an HH:MM, is the instant it names
// in the time zone, across a change of daylight saving time too.
const OCTOBER_31_EVENING_MS = Date.UTC(2026, 9, 31, 21, 0)

const clockCases = [
  {name: "today", nowMs: NOW_MS, day: DayChoice.today, clockText: "09:00", expected: {kind: ClockKind.valid, ms: TODAY_START_MS + seconds("09:00") * SECOND_MS}},
  {name: "tomorrow", nowMs: NOW_MS, day: DayChoice.tomorrow, clockText: "09:00", expected: {kind: ClockKind.valid, ms: NINE_TOMORROW_MS}},
  {name: "midnight", nowMs: NOW_MS, day: DayChoice.tomorrow, clockText: "00:00", expected: {kind: ClockKind.valid, ms: TOMORROW_START_MS}},
  {name: "the day standard time starts", nowMs: OCTOBER_31_EVENING_MS, day: DayChoice.tomorrow, clockText: "09:00", expected: {kind: ClockKind.valid, ms: Date.UTC(2026, 10, 1, 17, 0)}},
  {name: "the evening before it", nowMs: OCTOBER_31_EVENING_MS, day: DayChoice.today, clockText: "20:00", expected: {kind: ClockKind.valid, ms: Date.UTC(2026, 10, 1, 3, 0)}},
  {name: "no time", nowMs: NOW_MS, day: DayChoice.today, clockText: "", expected: {kind: ClockKind.invalid}},
  {name: "not a time", nowMs: NOW_MS, day: DayChoice.today, clockText: "25:00", expected: {kind: ClockKind.invalid}},
]

for (const {name, nowMs, day, clockText, expected} of clockCases) {
  deepStrictEqual(wallClockMs({nowMs, day, clockText, timeZone: TIME_ZONE}), expected, `the clock: ${name}`)
}

// A time chosen starts at the next five minutes, tomorrow past midnight.
deepStrictEqual(defaultClock({nowMs: NOW_MS, timeZone: TIME_ZONE}), {day: DayChoice.today, clockText: "08:40"}, "the default time")
deepStrictEqual(defaultClock({nowMs: TODAY_START_MS + seconds("23:58") * SECOND_MS, timeZone: TIME_ZONE}), {day: DayChoice.tomorrow, clockText: "00:00"}, "the default time at midnight")

// What a query leaves at or arrives by, in the service date that holds it,
// and a time no saved date holds refused with its own message.
const LAST_DEPARTURE_S = seconds("26:00")

function dayEntry({serviceDate, serviceDayStartMs}) {
  return {serviceDate, serviceDayStartMs, connectionChunks: [{departureSMin: 0, departureSMax: LAST_DEPARTURE_S}]}
}

const twoDays = {formatVersion: 2, snapshots: [dayEntry({serviceDate: "2026-11-08", serviceDayStartMs: TODAY_START_MS}), dayEntry({serviceDate: "2026-11-09", serviceDayStartMs: TOMORROW_START_MS})]}
const todayOnly = {formatVersion: 2, snapshots: [dayEntry({serviceDate: "2026-11-08", serviceDayStartMs: TODAY_START_MS})]}

const plannedCases = [
  {name: "now", when: {mode: TimeMode.now, day: DayChoice.today, clockText: "17:30"}, manifest: twoDays, expected: {kind: PlannedKind.leaving, mode: TimeMode.now, ms: NOW_MS, serviceDate: "2026-11-08", seconds: seconds("08:38")}},
  {name: "a departure today", when: {mode: TimeMode.departAt, day: DayChoice.today, clockText: "17:30"}, manifest: twoDays, expected: {kind: PlannedKind.leaving, mode: TimeMode.departAt, ms: TODAY_START_MS + seconds("17:30") * SECOND_MS, serviceDate: "2026-11-08", seconds: seconds("17:30")}},
  {name: "an arrival tomorrow", when: {mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "09:00"}, manifest: twoDays, expected: {kind: PlannedKind.arrivingBy, mode: TimeMode.arriveBy, ms: NINE_TOMORROW_MS, serviceDate: "2026-11-09", seconds: seconds("09:00")}},
  {name: "an arrival past midnight", when: {mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "00:45"}, manifest: twoDays, expected: {kind: PlannedKind.arrivingBy, mode: TimeMode.arriveBy, ms: TOMORROW_START_MS + seconds("00:45") * SECOND_MS, serviceDate: "2026-11-09", seconds: seconds("00:45")}},
  {name: "a departure tomorrow no saved date holds", when: {mode: TimeMode.departAt, day: DayChoice.tomorrow, clockText: "09:00"}, manifest: todayOnly, expected: {kind: PlannedKind.refused, state: StateKind.outsideSchedules}},
  {name: "an arrival tomorrow no saved date holds", when: {mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "09:00"}, manifest: todayOnly, expected: {kind: PlannedKind.refused, state: StateKind.outsideSchedules}},
  {name: "now with no saved date", when: {mode: TimeMode.now, day: DayChoice.today, clockText: ""}, manifest: {formatVersion: 2, snapshots: []}, expected: {kind: PlannedKind.refused, state: StateKind.noServiceDate}},
  {name: "a departure with no time", when: {mode: TimeMode.departAt, day: DayChoice.today, clockText: ""}, manifest: twoDays, expected: {kind: PlannedKind.refused, state: StateKind.chooseTime}},
]

for (const {name, when, manifest, expected} of plannedCases) {
  deepStrictEqual(plannedTime({when, nowMs: NOW_MS, timeZone: TIME_ZONE, manifest}), expected, `the planned time: ${name}`)
}

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
  {kind: StateKind.outsideSchedules, expected: {headline: "No schedule for that time", caption: "Schedules cover today and tomorrow. Choose another time."}},
  {kind: StateKind.chooseTime, expected: {headline: "Choose a time", caption: "Set the time to plan this trip."}},
  {kind: StateKind.noneInTime, expected: {headline: "No journeys arrive in time", caption: "Nothing reaches this stop by then. Choose a later time."}},
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
