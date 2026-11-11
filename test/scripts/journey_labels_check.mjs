// Checks what the map labels of the chosen journey say and where they
// stand, as pure functions of journeys written out by hand in the router's
// shape: a journey with a change, a walk-only journey from the rider's
// position, a journey whose first bus is scheduled, and one whose first bus
// is live and late or early, with each label's kind, text, and place, and
// the text of the first bus's label and the trip and service date its
// vehicle is found by. Run it with
// `node test/scripts/journey_labels_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {LegKind} from "../../assets/js/routing_engine.js"
import {LEG_KIND_TO_POINT} from "../../assets/js/point_journeys.js"
import {LiveKind} from "../../assets/js/journey_cards.js"
import {LabelKind, YourBusLabelKind, journeyLabels, yourBusLabel} from "../../assets/js/journey_labels.js"

const TIME_ZONE = "America/Los_Angeles"
const TODAY = "2026-11-08"
// 2026-11-08 at midnight in Seattle, eight hours after midnight UTC.
const TODAY_START_MS = 1794124800000
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS}
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const SECOND_MS = 1000
const MINUTE_MS = 60 * 1000
const WALK_SECONDS = 170
const LATE_MINUTES = 2
const HALVING_DIVISOR = 2
const ARRIVE_INDEX = 3
const BOARD_INDEX = 2
const DUE_LEAD_SECONDS = 5
const EARLY_MINUTES = 3

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

const START = {lat: 47.6, lon: -122.3}
const BOARD_E = {lat: 47.61, lon: -122.31}
const CHANGE_E = {lat: 47.62, lon: -122.32}
const BOARD_36 = {lat: 47.63, lon: -122.33}
const END_36 = {lat: 47.64, lon: -122.34}
const DESTINATION = {lat: 47.65, lon: -122.35}

function kindOf(label) {
  return label.kind
}

function textOf(label) {
  return label.text
}

function coordinate(position) {
  return [position.lon, position.lat]
}

// The middle of the line a walk draws between two positions.
function midpoint({from, to}) {
  return {lat: (from.lat + to.lat) / HALVING_DIVISOR, lon: (from.lon + to.lon) / HALVING_DIVISOR}
}

// A walk from the rider's position, a ride, a walk to another stop, a
// second ride, and a walk to a point.
const changing = {
  serviceDate: TODAY,
  arrivalS: seconds("09:05"),
  changes: 1,
  isEarliest: false,
  legs: [
    {kind: LegKind.walkFromPosition, toStopId: "1_431", durationS: WALK_SECONDS},
    ride({routeId: "1_e", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51"}),
    {kind: LegKind.walk, fromStopId: "1_1121", toStopId: "1_1500", durationS: WALK_SECONDS},
    ride({routeId: "1_36", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02"}),
    {kind: LEG_KIND_TO_POINT, fromStopId: "1_11920", durationS: WALK_SECONDS},
  ],
  stopPositions: {"1_431": BOARD_E, "1_1121": CHANGE_E, "1_1500": BOARD_36, "1_11920": END_36},
  destination: {name: "Pike Place Market", ...DESTINATION},
}

// A walk to a stop and a single ride that ends at the destination stop.
const direct = {
  serviceDate: TODAY,
  arrivalS: seconds("09:14"),
  changes: 0,
  isEarliest: true,
  legs: [{kind: LegKind.walk, fromStopId: "1_400", toStopId: "1_7", durationS: WALK_SECONDS}, ride({routeId: "1_7", from: "1_7", departs: "08:46", to: "1_11920", arrives: "09:14"})],
  stopPositions: {"1_400": START, "1_7": BOARD_E, "1_11920": END_36},
}

const walkOnly = {
  serviceDate: TODAY,
  arrivalS: seconds("08:50"),
  changes: 0,
  isEarliest: false,
  legs: [{kind: LegKind.walkFromPosition, toStopId: "1_9", durationS: WALK_SECONDS}, {kind: LEG_KIND_TO_POINT, fromStopId: "1_9", durationS: WALK_SECONDS}],
  stopPositions: {"1_9": BOARD_E},
  destination: {name: "Pike Place Market", ...DESTINATION},
}

const names = {
  stops: {},
  routes: {"1_e": {name: "E", color: "#1D4ED8"}, "1_36": {name: "36", color: "#EA580C"}, "1_7": {name: "7", color: "#0F766E"}},
}
const NOW_MS = atMs("08:38")
const SCHEDULED = {kind: LiveKind.scheduled, routeId: "1_e"}
const NO_RIDE = {kind: LiveKind.noRide}

function chosenOf({journey, live, nowMs = NOW_MS}) {
  return {journey, live, leadText: "Leave in 4 min", arriveText: "Arrive 9:05 am", serviceDayStartsMs, timeZone: TIME_ZONE, names, origin: START, nowMs}
}

function labelsOf({journey, live}) {
  return journeyLabels({chosen: chosenOf({journey, live})})
}

function labelAt({kind, text, position}) {
  return {kind, text, coordinate: coordinate(position)}
}

// A journey with a change: where it leaves from, each walk's minutes
// between its ends, each boarding with its route and time, each ride's end
// where another leg follows, and the arrival at the destination.
deepStrictEqual(labelsOf({journey: changing, live: SCHEDULED}), [
  labelAt({kind: LabelKind.leave, text: "Leave 8:39 am", position: START}),
  labelAt({kind: LabelKind.walk, text: "3 min", position: midpoint({from: START, to: BOARD_E})}),
  labelAt({kind: LabelKind.board, text: "E 8:42 am", position: BOARD_E}),
  labelAt({kind: LabelKind.alight, text: "Get off 8:51 am", position: CHANGE_E}),
  labelAt({kind: LabelKind.walk, text: "3 min", position: midpoint({from: CHANGE_E, to: BOARD_36})}),
  labelAt({kind: LabelKind.board, text: "36 8:56 am", position: BOARD_36}),
  labelAt({kind: LabelKind.alight, text: "Get off 9:02 am", position: END_36}),
  labelAt({kind: LabelKind.walk, text: "3 min", position: midpoint({from: END_36, to: DESTINATION})}),
  labelAt({kind: LabelKind.arrive, text: "Arrive 9:05 am", position: DESTINATION}),
])

// A journey that ends with a ride has no getting off, only the arrival
// where the ride ends, as the timeline has none.
{
  const labels = labelsOf({journey: direct, live: {kind: LiveKind.scheduled, routeId: "1_7"}})
  const kinds = Array.from(labels, kindOf)
  deepStrictEqual(kinds, [LabelKind.leave, LabelKind.walk, LabelKind.board, LabelKind.arrive])
  deepStrictEqual(labels[ARRIVE_INDEX], labelAt({kind: LabelKind.arrive, text: "Arrive 9:14 am", position: END_36}))
}

// A journey that only walks has its leave, its walks, and its arrival, and
// no boarding.
{
  const labels = labelsOf({journey: walkOnly, live: NO_RIDE})
  const kinds = Array.from(labels, kindOf)
  deepStrictEqual(kinds, [LabelKind.leave, LabelKind.walk, LabelKind.walk, LabelKind.arrive])
  deepStrictEqual(labels[0].text, "Leave 8:44 am")
  deepStrictEqual(labels[ARRIVE_INDEX].text, "Arrive 8:50 am")
}

// A live late first bus moves the leave time, the first boarding and its
// getting off, and the arrival by the lateness, adds the lateness to the
// first boarding, and leaves the second ride's times scheduled.
{
  const live = {kind: LiveKind.live, latenessS: LATE_MINUTES * MINUTE_SECONDS, routeId: "1_e"}
  const labels = labelsOf({journey: changing, live})
  const texts = Array.from(labels, textOf)
  deepStrictEqual(texts, ["Leave 8:41 am", "3 min", "E 8:44 am +2", "Get off 8:53 am", "3 min", "36 8:56 am", "Get off 9:02 am", "3 min", "Arrive 9:07 am"])
}

// A live early first bus reads as early.
{
  const live = {kind: LiveKind.live, latenessS: -EARLY_MINUTES * MINUTE_SECONDS, routeId: "1_e"}
  const texts = Array.from(labelsOf({journey: changing, live}), textOf)
  deepStrictEqual(texts[BOARD_INDEX], "E 8:39 am -3")
}

// A live bus within half a minute of its schedule reads as on time.
{
  const live = {kind: LiveKind.live, latenessS: 20, routeId: "1_e"}
  const texts = Array.from(labelsOf({journey: changing, live}), textOf)
  deepStrictEqual(texts[BOARD_INDEX], "E 8:42 am on time")
}

// A stop with no known position leaves out the labels that stand on it.
{
  const unplaced = {...changing, stopPositions: {...changing.stopPositions, "1_1121": undefined}}
  const labels = labelsOf({journey: unplaced, live: SCHEDULED})
  const texts = Array.from(labels, textOf)
  deepStrictEqual(texts.includes("Get off 8:51 am"), false)
  deepStrictEqual(texts.includes("E 8:42 am"), true)
}

// A journey from the rider's position with no position known leaves from
// the first stop it places.
{
  const labels = journeyLabels({chosen: {...chosenOf({journey: changing, live: SCHEDULED}), origin: null}})
  deepStrictEqual(labels[0], labelAt({kind: LabelKind.leave, text: "Leave 8:39 am", position: BOARD_E}))
}

// The first bus's label counts the minutes to its boarding stop from the
// scheduled departure moved by its lateness, at the time the texts were
// written, and names the trip and service date its vehicle is found by.
deepStrictEqual(yourBusLabel({chosen: chosenOf({journey: changing, live: SCHEDULED})}), {
  kind: YourBusLabelKind.label,
  tripId: "trip-1_e",
  serviceDateMs: TODAY_START_MS,
  text: "Your bus · 4 min away",
})

deepStrictEqual(
  yourBusLabel({chosen: chosenOf({journey: changing, live: {kind: LiveKind.live, latenessS: LATE_MINUTES * MINUTE_SECONDS, routeId: "1_e"}})}).text,
  "Your bus · 6 min away",
)

// Seconds do not count as a minute: 3 min 59 s away is 3 min.
deepStrictEqual(yourBusLabel({chosen: chosenOf({journey: changing, live: SCHEDULED, nowMs: atMs("08:38") + 1 * SECOND_MS})}).text, "Your bus · 3 min away")

// Under a minute away reads as due, and a bus past its boarding stop has
// no label.
deepStrictEqual(yourBusLabel({chosen: chosenOf({journey: changing, live: SCHEDULED, nowMs: atMs("08:42") - DUE_LEAD_SECONDS * SECOND_MS})}).text, "Your bus · due")
deepStrictEqual(yourBusLabel({chosen: chosenOf({journey: changing, live: SCHEDULED, nowMs: atMs("08:42") + MINUTE_MS})}), {kind: YourBusLabelKind.none})

// A journey that only walks has no bus.
deepStrictEqual(yourBusLabel({chosen: chosenOf({journey: walkOnly, live: NO_RIDE})}), {kind: YourBusLabelKind.none})
