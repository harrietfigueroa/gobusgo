// Checks what the arrivals board reads of the arguments of an
// `arrivals_board` call, as pure functions of the notification's params: the
// stop, a time that turns the board into a list of scheduled departures, and
// the routes the list keeps. The time is read as the trip planner app reads
// the `when` of `plan_trip`. Run it with
// `node test/scripts/mcp_board_input_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {BoardInputKind, ROUTE_COUNT_MAX, ROUTE_ID_LENGTH_MAX, boardInput} from "../../assets/js/mcp_board_input.js"

function paramsOf(toolArguments) {
  return {arguments: toolArguments}
}

const DEPART_AT = Object.freeze({mode: "departAt", day: "today", time: "23:00"})
const DEPART_AT_READ = Object.freeze({mode: "departAt", day: "today", clockText: "23:00"})
const LEAVING_NOW_READ = Object.freeze({mode: "now", day: "today", clockText: ""})
const ROUTE_IDS = Object.freeze(["1_100", "1_101"])

function scheduled({when, routeIds}) {
  return {kind: BoardInputKind.scheduled, stopId: "1_1", when, routeIds}
}

const cases = [
  {name: "a stop alone is a live board", params: paramsOf({stopId: "1_1"}), expected: {kind: BoardInputKind.live, stopId: "1_1"}},
  {name: "a time makes a list of departures over every route", params: paramsOf({stopId: "1_1", when: DEPART_AT}), expected: scheduled({when: DEPART_AT_READ, routeIds: []})},
  {name: "a time with the routes it keeps", params: paramsOf({stopId: "1_1", when: DEPART_AT, route: ROUTE_IDS}), expected: scheduled({when: DEPART_AT_READ, routeIds: ROUTE_IDS})},
  {name: "a time of no routes keeps every route", params: paramsOf({stopId: "1_1", when: DEPART_AT, route: []}), expected: scheduled({when: DEPART_AT_READ, routeIds: []})},
  {name: "routes with no time leave the board live", params: paramsOf({stopId: "1_1", route: ROUTE_IDS}), expected: {kind: BoardInputKind.live, stopId: "1_1"}},
  {name: "a time of mode now carries no clock", params: paramsOf({stopId: "1_1", when: {mode: "now"}}), expected: scheduled({when: LEAVING_NOW_READ, routeIds: []})},
  {name: "a day is today where none is given", params: paramsOf({stopId: "1_1", when: {mode: "departAt", time: "05:30"}}), expected: scheduled({when: {mode: "departAt", day: "today", clockText: "05:30"}, routeIds: []})},
  {name: "tomorrow", params: paramsOf({stopId: "1_1", when: {mode: "departAt", day: "tomorrow", time: "05:30"}}), expected: scheduled({when: {mode: "departAt", day: "tomorrow", clockText: "05:30"}, routeIds: []})},
  {name: "a time to arrive by is read as the planner reads it", params: paramsOf({stopId: "1_1", when: {mode: "arriveBy", time: "08:00"}}), expected: scheduled({when: {mode: "arriveBy", day: "today", clockText: "08:00"}, routeIds: []})},
  {name: "no params", params: undefined, expected: {kind: BoardInputKind.missing}},
  {name: "params with no arguments", params: {}, expected: {kind: BoardInputKind.missing}},
  {name: "arguments that name nothing", params: paramsOf({}), expected: {kind: BoardInputKind.missing}},
  {name: "no stop", params: paramsOf({when: DEPART_AT}), expected: {kind: BoardInputKind.missing}},
  {name: "an empty stop", params: paramsOf({stopId: ""}), expected: {kind: BoardInputKind.missing}},
  {name: "a stop that is not text", params: paramsOf({stopId: 7}), expected: {kind: BoardInputKind.missing}}
]

for (const {name, params, expected} of cases) {
  deepStrictEqual(boardInput(params), expected, name)
}

const refusedWhenCases = [
  {name: "a mode of no kind", when: {mode: "teleport", time: "08:00"}},
  {name: "a time that is not a clock", when: {mode: "departAt", time: "8:30 pm"}},
  {name: "an hour past 23", when: {mode: "departAt", time: "25:00"}},
  {name: "no clock for a mode that needs one", when: {mode: "departAt"}},
  {name: "a day of no kind", when: {mode: "departAt", day: "friday", time: "08:00"}},
  {name: "a time that is not an object", when: "tonight"}
]

for (const {name, when} of refusedWhenCases) {
  deepStrictEqual(boardInput(paramsOf({stopId: "1_1", when})), {kind: BoardInputKind.refused, field: "when"}, `the time is refused: ${name}`)
}

const refusedRouteCases = [
  {name: "routes that are not a list", route: "1_100"},
  {name: "a route that is not text", route: ["1_100", 7]},
  {name: "an empty route identifier", route: ["1_100", ""]},
  {name: "more routes than the bound", route: Array.from({length: ROUTE_COUNT_MAX + 1}, (_value, index) => `1_${index}`)},
  {name: "a route identifier over the bound", route: ["1".repeat(ROUTE_ID_LENGTH_MAX + 1)]}
]

for (const {name, route} of refusedRouteCases) {
  deepStrictEqual(boardInput(paramsOf({stopId: "1_1", when: DEPART_AT, route})), {kind: BoardInputKind.refused, field: "route"}, `the routes are refused: ${name}`)
}

const atBound = Array.from({length: ROUTE_COUNT_MAX}, (_value, index) => "1".repeat(ROUTE_ID_LENGTH_MAX - 1) + index)
deepStrictEqual(boardInput(paramsOf({stopId: "1_1", when: DEPART_AT, route: atBound})), scheduled({when: DEPART_AT_READ, routeIds: atBound}), "the most routes of the longest identifiers")
deepStrictEqual([ROUTE_COUNT_MAX, ROUTE_ID_LENGTH_MAX], [10, 100], "the bounds the tool's schema states")

console.log("mcp board input: every case passed")
