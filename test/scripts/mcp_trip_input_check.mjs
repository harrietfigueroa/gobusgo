// Checks how the trip planner app reads a `plan_trip` call, as pure
// functions over argument objects written out by hand: the two ends' texts
// trimmed and bounded, the time of the trip with its day and clock, the
// default of leaving now, each refusal naming its field, and where the
// arguments sit in the host's two notifications. Run it with `node
// test/scripts/mcp_trip_input_check.mjs`; it exits non-zero on the first case
// that differs.

import {deepStrictEqual} from "node:assert/strict"
import {END_TEXT_LENGTH_MAX, InputKind, toolInputArguments, toolResultArguments, tripInput} from "../../assets/js/mcp_trip_input.js"
import {DayChoice, TimeMode} from "../../assets/js/trip_plan.js"

const NOW = {mode: TimeMode.now, day: DayChoice.today, clockText: ""}

function found({from, to, when}) {
  return {kind: InputKind.found, from, to, when}
}

function refused(field) {
  return {kind: InputKind.refused, field}
}

const cases = [
  {name: "two ends and no time leave now", value: {from: "Pine and 3rd", to: "Ballard"}, expected: found({from: "Pine and 3rd", to: "Ballard", when: NOW})},
  {name: "an end is trimmed", value: {from: "  Pine and 3rd ", to: "\tBallard\n"}, expected: found({from: "Pine and 3rd", to: "Ballard", when: NOW})},
  {name: "a time of mode now carries no clock", value: {from: "A", to: "B", when: {mode: "now", time: "08:30"}}, expected: found({from: "A", to: "B", when: NOW})},
  {
    name: "departAt with a clock leaves today",
    value: {from: "A", to: "B", when: {mode: "departAt", time: "08:30"}},
    expected: found({from: "A", to: "B", when: {mode: TimeMode.departAt, day: DayChoice.today, clockText: "08:30"}}),
  },
  {
    name: "arriveBy tomorrow names the day",
    value: {from: "A", to: "B", when: {mode: "arriveBy", day: "tomorrow", time: "23:59"}},
    expected: found({from: "A", to: "B", when: {mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "23:59"}}),
  },
  {name: "an end at the length bound is read", value: {from: "a".repeat(END_TEXT_LENGTH_MAX), to: "B"}, expected: found({from: "a".repeat(END_TEXT_LENGTH_MAX), to: "B", when: NOW})},
  {name: "no arguments refuse from", value: undefined, expected: refused("from")},
  {name: "a list of arguments refuses from", value: [], expected: refused("from")},
  {name: "a missing from refuses from", value: {to: "B"}, expected: refused("from")},
  {name: "a blank from refuses from", value: {from: "   ", to: "B"}, expected: refused("from")},
  {name: "a from that is not text refuses from", value: {from: 7, to: "B"}, expected: refused("from")},
  {name: "a from past the bound refuses from", value: {from: "a".repeat(END_TEXT_LENGTH_MAX + 1), to: "B"}, expected: refused("from")},
  {name: "a missing to refuses to", value: {from: "A"}, expected: refused("to")},
  {name: "a blank to refuses to", value: {from: "A", to: ""}, expected: refused("to")},
  {name: "a when that is not an object refuses when", value: {from: "A", to: "B", when: "now"}, expected: refused("when")},
  {name: "an unknown mode refuses when", value: {from: "A", to: "B", when: {mode: "teleport"}}, expected: refused("when")},
  {name: "departAt with no time refuses when", value: {from: "A", to: "B", when: {mode: "departAt"}}, expected: refused("when")},
  {name: "a clock with a meridiem refuses when", value: {from: "A", to: "B", when: {mode: "departAt", time: "8:30 pm"}}, expected: refused("when")},
  {name: "a clock past 23:59 refuses when", value: {from: "A", to: "B", when: {mode: "arriveBy", time: "24:00"}}, expected: refused("when")},
  {name: "an unknown day refuses when", value: {from: "A", to: "B", when: {mode: "departAt", day: "friday", time: "08:30"}}, expected: refused("when")},
]

for (const {name, value, expected} of cases) {
  deepStrictEqual(tripInput(value), expected, name)
}

// The host's tool-input notification holds the arguments under `arguments`,
// and the tool result holds them under `structuredContent`.
deepStrictEqual(toolInputArguments({arguments: {from: "A", to: "B"}}), {from: "A", to: "B"}, "tool input arguments")
deepStrictEqual(toolResultArguments({content: [], structuredContent: {from: "A", to: "B"}}), {from: "A", to: "B"}, "tool result structured content")
deepStrictEqual(toolInputArguments(undefined), {}, "tool input with no params")
deepStrictEqual(toolResultArguments("text"), {}, "tool result with params of another shape")
const noArguments = toolInputArguments(undefined)
deepStrictEqual(tripInput(noArguments), refused("from"), "no params refuse from")

console.log(`mcp_trip_input_check: ${cases.length} cases passed`)
