// Checks how the trip planner app reads a `plan_trip` call, as pure
// functions over argument objects written out by hand: the two ends' texts
// trimmed and bounded, a start the rider names by where they are, the time
// of the trip with its day and clock, the default of leaving now, each
// refusal naming its field, and where the arguments sit in the host's two
// notifications. Run it with `node
// test/scripts/mcp_trip_input_check.mjs`; it exits non-zero on the first case
// that differs.

import {deepStrictEqual} from "node:assert/strict"
import {END_TEXT_LENGTH_MAX, InputKind, REGION_PARTS_MAX, StartKind, searchWords, toolInputArguments, toolResultArguments, tripInput} from "../../assets/js/mcp_trip_input.js"
import {DayChoice, TimeMode} from "../../assets/js/trip_plan.js"

const NOW = {mode: TimeMode.now, day: DayChoice.today, clockText: ""}
const POSITION = {kind: StartKind.position}

function words(text) {
  return {kind: StartKind.words, text}
}

function found({from, to, when}) {
  return {kind: InputKind.found, from, to, when}
}

function refused(field) {
  return {kind: InputKind.refused, field}
}

const cases = [
  {name: "two ends and no time leave now", value: {from: "Pine and 3rd", to: "Ballard"}, expected: found({from: words("Pine and 3rd"), to: "Ballard", when: NOW})},
  {name: "an end is trimmed", value: {from: "  Pine and 3rd ", to: "\tBallard\n"}, expected: found({from: words("Pine and 3rd"), to: "Ballard", when: NOW})},
  {name: "a time of mode now carries no clock", value: {from: "A", to: "B", when: {mode: "now", time: "08:30"}}, expected: found({from: words("A"), to: "B", when: NOW})},
  {
    name: "departAt with a clock leaves today",
    value: {from: "A", to: "B", when: {mode: "departAt", time: "08:30"}},
    expected: found({from: words("A"), to: "B", when: {mode: TimeMode.departAt, day: DayChoice.today, clockText: "08:30"}}),
  },
  {
    name: "arriveBy tomorrow names the day",
    value: {from: "A", to: "B", when: {mode: "arriveBy", day: "tomorrow", time: "23:59"}},
    expected: found({from: words("A"), to: "B", when: {mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "23:59"}}),
  },
  {name: "an end at the length bound is read", value: {from: "a".repeat(END_TEXT_LENGTH_MAX), to: "B"}, expected: found({from: words("a".repeat(END_TEXT_LENGTH_MAX)), to: "B", when: NOW})},
  {name: "a missing from starts where the rider is", value: {to: "B"}, expected: found({from: POSITION, to: "B", when: NOW})},
  {name: "a blank from starts where the rider is", value: {from: "   ", to: "B"}, expected: found({from: POSITION, to: "B", when: NOW})},
  {name: "here starts where the rider is", value: {from: "here", to: "B"}, expected: found({from: POSITION, to: "B", when: NOW})},
  {name: "my location in any case starts where the rider is", value: {from: " My Location ", to: "B"}, expected: found({from: POSITION, to: "B", when: NOW})},
  {name: "my current location starts where the rider is", value: {from: "my  current location.", to: "B"}, expected: found({from: POSITION, to: "B", when: NOW})},
  {name: "where I am starts where the rider is", value: {from: "where I am", to: "B"}, expected: found({from: POSITION, to: "B", when: NOW})},
  {name: "a place holding here is words", value: {from: "Here and Now Cafe", to: "B"}, expected: found({from: words("Here and Now Cafe"), to: "B", when: NOW})},
  {name: "no arguments refuse from", value: undefined, expected: refused("from")},
  {name: "a list of arguments refuses from", value: [], expected: refused("from")},
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
deepStrictEqual(tripInput(noArguments), refused("to"), "no params refuse to")

// The words the search takes drop a trailing region after a comma, a trailing
// ZIP, and a leading "the", and keep every name that holds a region word.
const searchCases = [
  {name: "a trailing city", text: "Space Needle, Seattle", expected: "Space Needle"},
  {name: "a trailing state abbreviation", text: "Space Needle, WA", expected: "Space Needle"},
  {name: "a trailing state name", text: "Space Needle, Washington", expected: "Space Needle"},
  {name: "a city and a state", text: "Space Needle, Seattle, WA", expected: "Space Needle"},
  {name: "a city, a state, and a ZIP", text: "Space Needle, Seattle, WA 98101", expected: "Space Needle"},
  {name: "a city, a state, and a ZIP plus four", text: "Space Needle, Seattle, WA 98109-4601", expected: "Space Needle"},
  {name: "a ZIP in its own part", text: "Space Needle, Seattle, 98109", expected: "Space Needle"},
  {name: "a trailing ZIP with no comma", text: "400 Broad St 98109", expected: "400 Broad St"},
  {name: "a trailing ZIP plus four with no comma", text: "400 Broad St 98109-4601", expected: "400 Broad St"},
  {name: "a street address with its region", text: "400 Broad St, Seattle, WA 98109", expected: "400 Broad St"},
  {name: "an intersection with its city", text: "Pine and 3rd, Seattle", expected: "Pine and 3rd"},
  {name: "spaces around the commas", text: "  Space Needle ,  Seattle ,WA  ", expected: "Space Needle"},
  {name: "only the last parts up to the bound", text: "A, B, C, D, E", expected: "A, B"},
  {name: "a leading the", text: "the Space Needle", expected: "Space Needle"},
  {name: "a leading The in capitals", text: "The Ballard Locks, Seattle, WA", expected: "Ballard Locks"},
  {name: "a name ending in Washington", text: "University of Washington", expected: "University of Washington"},
  {name: "a name ending in Seattle", text: "Russian Community Center of Seattle", expected: "Russian Community Center of Seattle"},
  {name: "a name ending in Seattle after a dash", text: "VA Medical Center - Seattle", expected: "VA Medical Center - Seattle"},
  {name: "a name beginning with Seattle", text: "Seattle Center", expected: "Seattle Center"},
  {name: "a neighborhood named for the city", text: "West Seattle", expected: "West Seattle"},
  {name: "a city alone", text: "Seattle", expected: "Seattle"},
  {name: "a name with its own city after a comma", text: "University of Washington, Seattle", expected: "University of Washington"},
  {name: "a leading city before a comma is the name", text: "Seattle, WA", expected: "Seattle"},
  {name: "a ZIP alone keeps its words", text: "98101", expected: "98101"},
  {name: "a ZIP after a comma alone keeps its words", text: ", 98101", expected: ", 98101"},
  {name: "the alone keeps its words", text: "the", expected: "the"},
  {name: "a word that only begins with the", text: "Theater District", expected: "Theater District"},
  {name: "text with nothing to strip", text: "Pine and 3rd", expected: "Pine and 3rd"},
  {name: "a four-digit number is no ZIP", text: "Highway 9999", expected: "Highway 9999"},
]

for (const {name, text, expected} of searchCases) {
  deepStrictEqual(searchWords(text), expected, name)
}

deepStrictEqual(REGION_PARTS_MAX, 3, "a city, a state, and a ZIP")

console.log(`mcp_trip_input_check: ${cases.length + searchCases.length} cases passed`)
