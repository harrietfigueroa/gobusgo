// Checks the words the trip planner app searches for an end against the
// places fixture of the 30 queries: a rider's words with a region after them
// find the place the words alone find, a name that holds a region word is
// found whole, and a leading "the" is dropped because the search, which
// keeps a place only when every query word matches one of its words, finds
// the wrong place or none for "the Space Needle" and "the Ballard Locks".
// Run it with `node test/scripts/mcp_trip_words_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {searchWords} from "../../assets/js/mcp_trip_input.js"
import {buildPlaceIndex, searchPlaces} from "../../assets/js/place_search.js"
import {tableOfJsonColumns} from "./place_records.mjs"

const RESULT_COUNT = 5

const fixtureUrl = new URL("../fixtures/places/queries/places.json", import.meta.url)
const fixture = JSON.parse(readFileSync(fixtureUrl, "utf8"))
const index = buildPlaceIndex(tableOfJsonColumns(fixture.table))

function nameOf(result) {
  return result.name
}

function namesFound(query) {
  const results = searchPlaces({index, query, center: fixture.center, resultCountMax: RESULT_COUNT})
  return Array.from(results, nameOf)
}

// What the search finds for the rider's words as they stand: the leading
// "the" leaves the Space Needle behind a hotel and finds no Ballard Locks.
deepStrictEqual(namesFound("the Space Needle"), ["Travelodge Seattle by the Space Needle"], "the search with a leading the finds only a hotel")
deepStrictEqual(namesFound("the Ballard Locks"), [], "the search with a leading the finds no locks")
deepStrictEqual(namesFound("Space Needle, Seattle, WA"), [], "the search with a region finds nothing")

const cases = [
  {name: "the Space Needle", text: "the Space Needle", first: "Space Needle"},
  {name: "the Space Needle with its region", text: "the Space Needle, Seattle, WA 98109", first: "Space Needle"},
  {name: "the Ballard Locks", text: "the Ballard Locks", first: "Hiram M. Chittenden Locks"},
  {name: "a region after the name", text: "Space Needle, Seattle, WA", first: "Space Needle"},
  {name: "a name ending in Washington", text: "University of Washington", first: "University of Washington"},
  {name: "a name ending in Washington with its city", text: "University of Washington, Seattle", first: "University of Washington"},
  {name: "a name ending in Seattle", text: "Russian Community Center of Seattle", first: "Russian Community Center of Seattle"},
  {name: "a name ending in Seattle after a dash", text: "VA Medical Center - Seattle", first: "VA Medical Center - Seattle"},
  {name: "a name beginning with Seattle", text: "Seattle Center", first: "Seattle Center"},
  {name: "a name beginning with The", text: "The District at Northgate", first: "The District at Northgate"},
]

for (const {name, text, first} of cases) {
  const found = namesFound(searchWords(text))
  deepStrictEqual(found.includes(first), true, `${name}: ${JSON.stringify(found)} holds ${first}`)
}

console.log(`mcp_trip_words_check: ${cases.length} searches passed`)
