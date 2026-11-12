// Checks what the Trip tab's journey cards decide as pure functions of
// journeys written out by hand in the router's shape and of arrivals in the
// shape of the "stop-arrivals:arrivals" event: which stops' live arrivals
// are asked for, which arrival is a journey's first bus and how late it
// runs, the leave-in and arrival texts, live and scheduled, the bar's
// segments, and each sort. Run it with
// `node test/scripts/journey_cards_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {LegKind} from "../../assets/js/core/routing_engine.js"
import {journeyRows} from "../../assets/js/core/trip_plan.js"
import {LEG_KIND_TO_POINT} from "../../assets/js/core/point_journeys.js"
import {LiveKind, SegmentKind, SortKind, barSegments, firstRideLive, journeyCard, liveStopIds, sortedCards} from "../../assets/js/journey_cards.js"

const TIME_ZONE = "America/Los_Angeles"
const TODAY = "2026-11-08"
// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const TODAY_START_MS = 1794124800000
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS}
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const SECOND_MS = 1000
const MINUTE_MS = 60 * 1000
const STOP_COUNT_MAX = 7
const STOP_COUNT_ONE = 1
const WALK_SECONDS = 170
const LATE_MINUTES = 2
const EARLY_MINUTES = 1
const FAR_MINUTES = 30
const MATCH_TOLERANCE_PAST_MINUTES = 6
const NO_WALK_S = 0
const DAY_MS = 24 * 60 * 60 * 1000
// A lateness that rounds to no whole minute.
const UNDER_HALF_MINUTE_S = 29
const WALK_ORDER = 0
const DIRECT_ORDER = 1
const CHANGING_ORDER = 2

function seconds(clock) {
  const [hours, minutes] = clock.split(":")
  return Number(hours) * HOUR_SECONDS + Number(minutes) * MINUTE_SECONDS
}

function atMs(clock) {
  return TODAY_START_MS + seconds(clock) * SECOND_MS
}

function ride({routeId, from, departs, to, arrives}) {
  return {kind: LegKind.ride, tripId: `trip-${routeId}`, routeId, serviceDayOffset: 0, fromStopId: from, departureS: seconds(departs), toStopId: to, arrivalS: seconds(arrives), stopIds: [from, to]}
}

function walk({from, to, durationS}) {
  return {kind: LegKind.walk, fromStopId: from, toStopId: to, durationS}
}

// The earliest journey changes once, from E to 36 after a walk of almost
// three minutes; another rides 7 alone; a third walks only.
const changing = {
  serviceDate: TODAY,
  arrivalS: seconds("09:02"),
  changes: 1,
  isEarliest: true,
  legs: [
    ride({routeId: "1_e", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51"}),
    walk({from: "1_1121", to: "1_1500", durationS: WALK_SECONDS}),
    ride({routeId: "1_36", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02"}),
  ],
  stopPositions: {},
}

const direct = {
  serviceDate: TODAY,
  arrivalS: seconds("09:14"),
  changes: 0,
  isEarliest: false,
  legs: [walk({from: "1_400", to: "1_7", durationS: WALK_SECONDS}), ride({routeId: "1_7", from: "1_7", departs: "08:46", to: "1_11920", arrives: "09:14"})],
  stopPositions: {},
}

const walkOnly = {
  serviceDate: TODAY,
  arrivalS: seconds("08:50"),
  changes: 0,
  isEarliest: false,
  legs: [{kind: LegKind.walkFromPosition, toStopId: "1_9", durationS: WALK_SECONDS}, {kind: LEG_KIND_TO_POINT, fromStopId: "1_9", durationS: WALK_SECONDS}],
  stopPositions: {},
  destination: {name: "Pike Place Market", lat: 47.6, lon: -122.3},
}

const names = {stops: {}, routes: {"1_e": {name: "E", color: "#1D4ED8"}, "1_36": {name: "36", color: "#EA580C"}, "1_7": {name: "7", color: "#0F766E"}}}
const NOW_MS = atMs("08:38")

function arrivalsShown({stopId, arrivals}) {
  return {stop_id: stopId, status: "arrivals", age_minutes: 0, arrivals}
}

function arrival({tripId, scheduledClock, lateMinutes, predicted}) {
  const scheduledMs = atMs(scheduledClock)
  return {route: "E", color: "#1D4ED8", headsign: "Aurora Village", minutes: 0, time_ms: scheduledMs + lateMinutes * MINUTE_MS, predicted, trip_id: tripId, scheduled_ms: scheduledMs}
}

function rowsOf(journeys) {
  return journeyRows({journeys, nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
}

function card({row, live, order = WALK_ORDER}) {
  return journeyCard({row, order, live, nowMs: NOW_MS, serviceDayStartsMs, names, timeZone: TIME_ZONE})
}

function kindOf(segment) {
  return segment.kind
}

function durationOf(segment) {
  return segment.durationS
}

function orderOf(shown) {
  return shown.order
}

function scheduledCard(row, order) {
  return card({row, order, live: {kind: LiveKind.scheduled, routeId: "1_e"}})
}

const LATE_E = arrival({tripId: "trip-1_e", scheduledClock: "08:42", lateMinutes: LATE_MINUTES, predicted: true})
const shownByStop = {"1_431": arrivalsShown({stopId: "1_431", arrivals: [LATE_E]})}

// The stops asked for are the first rides' boarding stops, each once, in
// the order of the journeys, at most the bound; a walk alone asks none.
{
  deepStrictEqual(liveStopIds({journeys: [changing, direct, walkOnly, changing], countMax: STOP_COUNT_MAX}), ["1_431", "1_7"])
  deepStrictEqual(liveStopIds({journeys: [changing, direct], countMax: STOP_COUNT_ONE}), ["1_431"])
}

// The first bus is the arrival of the first ride's trip near its scheduled
// time, and its lateness is the prediction less the schedule.
{
  deepStrictEqual(firstRideLive({journey: changing, shownByStop, serviceDayStartsMs}), {kind: LiveKind.live, latenessS: LATE_MINUTES * MINUTE_SECONDS, routeId: "1_e"})
  const early = arrival({tripId: "trip-1_e", scheduledClock: "08:42", lateMinutes: -EARLY_MINUTES, predicted: true})
  const earlyShown = {"1_431": arrivalsShown({stopId: "1_431", arrivals: [early]})}
  deepStrictEqual(firstRideLive({journey: changing, shownByStop: earlyShown, serviceDayStartsMs}).latenessS, -EARLY_MINUTES * MINUTE_SECONDS)
}

// A journey reads scheduled with no arrivals for its stop, with only a
// scheduled arrival, with another trip's arrival, with its trip's arrival
// at another time, and with a stop the page could not open; a walk alone
// has no ride.
{
  const scheduledOnly = arrival({tripId: "trip-1_e", scheduledClock: "08:42", lateMinutes: 0, predicted: false})
  const otherTrip = arrival({tripId: "trip-1_x", scheduledClock: "08:42", lateMinutes: LATE_MINUTES, predicted: true})
  const otherRun = arrival({tripId: "trip-1_e", scheduledClock: "08:42", lateMinutes: 0, predicted: true})
  otherRun.scheduled_ms += MATCH_TOLERANCE_PAST_MINUTES * MINUTE_MS
  const cases = [
    {name: "no arrivals asked", shown: {}},
    {name: "a scheduled arrival", shown: {"1_431": arrivalsShown({stopId: "1_431", arrivals: [scheduledOnly]})}},
    {name: "another trip", shown: {"1_431": arrivalsShown({stopId: "1_431", arrivals: [otherTrip]})}},
    {name: "another run of the trip", shown: {"1_431": arrivalsShown({stopId: "1_431", arrivals: [otherRun]})}},
    {name: "a busy page", shown: {"1_431": {stop_id: "1_431", status: "busy"}}},
  ]

  for (const {name, shown} of cases) {
    deepStrictEqual(firstRideLive({journey: changing, shownByStop: shown, serviceDayStartsMs}), {kind: LiveKind.scheduled, routeId: "1_e"}, name)
  }

  deepStrictEqual(firstRideLive({journey: walkOnly, shownByStop, serviceDayStartsMs}), {kind: LiveKind.noRide})
}

// A live card leads with the leave time moved by the lateness, and its
// arrival moves with it; a scheduled one reads its scheduled times.
{
  const [changingRow] = rowsOf([changing])
  const live = firstRideLive({journey: changing, shownByStop, serviceDayStartsMs})
  const liveCard = card({row: changingRow, live})
  deepStrictEqual(liveCard.leadText, "Leave in 6 min")
  deepStrictEqual(liveCard.arriveText, "arrive 9:04 am")
  deepStrictEqual(liveCard.isLive, true)
  deepStrictEqual(liveCard.detailText, "E 2 min late · 1 change")

  const scheduledCard = card({row: changingRow, live: {kind: LiveKind.scheduled, routeId: "1_e"}})
  deepStrictEqual(scheduledCard.leadText, "Leave in 4 min")
  deepStrictEqual(scheduledCard.arriveText, "arrive 9:02 am")
  deepStrictEqual(scheduledCard.isLive, false)
  deepStrictEqual(scheduledCard.detailText, "E scheduled · 1 change")
}

// The lateness reads on time, late, or early, in whole minutes.
{
  const [changingRow] = rowsOf([changing])
  const texts = [
    {latenessS: 0, text: "E on time · 1 change"},
    {latenessS: UNDER_HALF_MINUTE_S, text: "E on time · 1 change"},
    {latenessS: LATE_MINUTES * MINUTE_SECONDS, text: "E 2 min late · 1 change"},
    {latenessS: -EARLY_MINUTES * MINUTE_SECONDS, text: "E 1 min early · 1 change"},
  ]

  for (const {latenessS, text} of texts) {
    deepStrictEqual(card({row: changingRow, live: {kind: LiveKind.live, latenessS, routeId: "1_e"}}).detailText, text, `lateness ${latenessS}`)
  }
}

// The lead is "Leave now" once the time has come, minutes under an hour,
// and a clock time beyond, with its day where it is not today.
{
  const [changingRow] = rowsOf([changing])
  const leads = [
    {nowMs: atMs("08:42"), text: "Leave now"},
    {nowMs: atMs("08:50"), text: "Leave now"},
    {nowMs: atMs("08:41") + 1, text: "Leave now"},
    {nowMs: atMs("08:40"), text: "Leave in 2 min"},
    {nowMs: atMs("08:42") - FAR_MINUTES * MINUTE_MS, text: "Leave in 30 min"},
    {nowMs: atMs("07:41"), text: "Leave at 8:42 am"},
  ]
  const scheduled = {kind: LiveKind.scheduled, routeId: "1_e"}

  for (const {nowMs, text} of leads) {
    const shown = journeyCard({row: changingRow, order: WALK_ORDER, live: scheduled, nowMs, serviceDayStartsMs, names, timeZone: TIME_ZONE})
    deepStrictEqual(shown.leadText, text, `lead at ${nowMs}`)
  }

  const dayBeforeMs = NOW_MS - DAY_MS
  const [tomorrowRow] = journeyRows({journeys: [changing], nowMs: dayBeforeMs, serviceDayStartsMs, names, timeZone: TIME_ZONE})
  const tomorrowCard = journeyCard({row: tomorrowRow, order: WALK_ORDER, live: scheduled, nowMs: dayBeforeMs, serviceDayStartsMs, names, timeZone: TIME_ZONE})
  deepStrictEqual(tomorrowCard.leadText, "Leave tomorrow at 8:42 am")
}

// A walk alone reads its walk and no bus.
{
  const [walkRow] = rowsOf([walkOnly])
  const walkCard = card({row: walkRow, live: {kind: LiveKind.noRide}})
  deepStrictEqual(walkCard.detailText, "Walk only · No change")
  deepStrictEqual(walkCard.isLive, false)
}

// The bar holds each walk, wait, and ride to scale, a ride in its route's
// color with its name, from the journey's leave time to its arrival.
{
  const segments = barSegments({journey: changing, names})
  const kinds = Array.from(segments, kindOf)
  const durations = Array.from(segments, durationOf)
  deepStrictEqual(kinds, [SegmentKind.ride, SegmentKind.walk, SegmentKind.wait, SegmentKind.ride])
  deepStrictEqual(durations, [seconds("00:09"), WALK_SECONDS, seconds("00:05") - WALK_SECONDS, seconds("00:06")])
  deepStrictEqual(segments[0], {kind: SegmentKind.ride, durationS: seconds("00:09"), name: "E", color: "#1D4ED8"})

  const directSegments = barSegments({journey: direct, names})
  const directKinds = Array.from(directSegments, kindOf)
  deepStrictEqual(directKinds, [SegmentKind.walk, SegmentKind.ride])

  const walkSegments = barSegments({journey: walkOnly, names})
  const walkKinds = Array.from(walkSegments, kindOf)
  deepStrictEqual(walkKinds, [SegmentKind.walk, SegmentKind.walk])
  const noWalk = {...walkOnly, legs: [{kind: LegKind.walkFromPosition, toStopId: "1_9", durationS: NO_WALK_S}]}
  deepStrictEqual(barSegments({journey: noWalk, names}), [])
}

// Soonest sorts by the arrival, live where the card is live; Fewest
// changes by the changes; Least walking by the seconds walked; a tie keeps
// the order the rows came in. The rows come fewest changes first, the
// earlier arrival first within that: the walk, then 7, then E and 36.
{
  const rows = rowsOf([changing, direct, walkOnly])
  const cards = Array.from(rows, scheduledCard)
  const soonest = sortedCards({cards, sort: SortKind.soonest})
  const fewest = sortedCards({cards, sort: SortKind.fewestChanges})
  const leastWalking = sortedCards({cards, sort: SortKind.leastWalking})
  const cardOrders = Array.from(cards, orderOf)
  const soonestOrders = Array.from(soonest, orderOf)
  const fewestOrders = Array.from(fewest, orderOf)
  const leastWalkingOrders = Array.from(leastWalking, orderOf)
  deepStrictEqual(cardOrders, [WALK_ORDER, DIRECT_ORDER, CHANGING_ORDER])
  deepStrictEqual(soonestOrders, [WALK_ORDER, CHANGING_ORDER, DIRECT_ORDER])
  deepStrictEqual(fewestOrders, [WALK_ORDER, DIRECT_ORDER, CHANGING_ORDER])
  deepStrictEqual(leastWalkingOrders, [DIRECT_ORDER, CHANGING_ORDER, WALK_ORDER])

  const lateChanging = card({row: rows[CHANGING_ORDER], order: CHANGING_ORDER, live: {kind: LiveKind.live, latenessS: FAR_MINUTES * MINUTE_SECONDS, routeId: "1_e"}})
  const withLate = [cards[WALK_ORDER], cards[DIRECT_ORDER], lateChanging]
  const lateSoonest = sortedCards({cards: withLate, sort: SortKind.soonest})
  const lateSoonestOrders = Array.from(lateSoonest, orderOf)
  deepStrictEqual(lateSoonestOrders, [WALK_ORDER, DIRECT_ORDER, CHANGING_ORDER])
  throws(() => sortedCards({cards, sort: "sideways"}), AssertionError)
}

console.log("journey_cards_check: every case passed")
