// Checks the object the trip planner app hands the model when an end of the
// start's words matches no place, as pure functions over ends written out by
// hand: version 1 for one end and for both, the order of the ends, the
// words kept as the rider said them, and each refusal of the object's check,
// which names the field. Run it with
// `node test/scripts/mcp_trip_unmatched_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {ProblemKind} from "../../assets/js/mcp_trip_journey.js"
import {UNMATCHED_SCHEMA_NAME, UNMATCHED_SCHEMA_VERSION, unmatchedContext, unmatchedProblem} from "../../assets/js/mcp_trip_unmatched.js"
import {TripEnd} from "../../assets/js/core/trip_plan.js"

const VALID = {kind: ProblemKind.valid}

const one = unmatchedContext({unmatched: [{end: TripEnd.to, words: "somewhere to eat"}]})
deepStrictEqual(one, {schema: "gobusgo.unmatched", version: 1, ends: [{end: "to", words: "somewhere to eat"}]}, "one end")
deepStrictEqual(UNMATCHED_SCHEMA_NAME, "gobusgo.unmatched", "the schema name")
deepStrictEqual(UNMATCHED_SCHEMA_VERSION, 1, "the schema version")
deepStrictEqual(unmatchedProblem(one), VALID, "one end is valid")

const both = unmatchedContext({unmatched: [{end: TripEnd.to, words: "the hospital"}, {end: TripEnd.from, words: "my office"}]})
deepStrictEqual(both.ends, [{end: "from", words: "my office"}, {end: "to", words: "the hospital"}], "both ends, from first")
deepStrictEqual(unmatchedProblem(JSON.parse(JSON.stringify(both))), VALID, "both ends are valid after a JSON round trip")

function writeNoEnd() {
  return unmatchedContext({unmatched: []})
}

function writeEndTwice() {
  const twice = [{end: "to", words: "A"}, {end: "to", words: "B"}]
  return unmatchedContext({unmatched: twice})
}

function writeBlankWords() {
  const blank = [{end: "to", words: " "}]
  return unmatchedContext({unmatched: blank})
}

throws(writeNoEnd, AssertionError, "no end is refused")
throws(writeEndTwice, AssertionError, "an end twice is refused")
throws(writeBlankWords, AssertionError, "blank words are refused")

const problems = [
  {name: "not an object", value: "text", path: "root"},
  {name: "another schema", value: {...one, schema: "gobusgo.journeys"}, path: "schema"},
  {name: "another version", value: {...one, version: 2}, path: "version"},
  {name: "no list of ends", value: {...one, ends: "to"}, path: "ends"},
  {name: "an empty list of ends", value: {...one, ends: []}, path: "ends"},
  {name: "three ends", value: {...one, ends: [{end: "from", words: "A"}, {end: "to", words: "B"}, {end: "to", words: "C"}]}, path: "ends"},
  {name: "an end that is no record", value: {...one, ends: ["to"]}, path: "ends.0"},
  {name: "an unknown end", value: {...one, ends: [{end: "via", words: "A"}]}, path: "ends.0.end"},
  {name: "no words", value: {...one, ends: [{end: "to"}]}, path: "ends.0.words"},
  {name: "blank words", value: {...one, ends: [{end: "to", words: ""}]}, path: "ends.0.words"},
  {name: "ends out of order", value: {...one, ends: [{end: "to", words: "A"}, {end: "from", words: "B"}]}, path: "ends.1.end"},
]

for (const {name, value, path} of problems) {
  deepStrictEqual(unmatchedProblem(value), {kind: ProblemKind.invalid, path}, name)
}

console.log(`mcp_trip_unmatched_check: ${problems.length} refusals passed`)
