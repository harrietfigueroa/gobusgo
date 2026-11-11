// Checks the 30 queries a rider is expected to type against a fixture cut
// from the real places: each query, searched from the map's center, puts its
// intended place first. The fixture holds, for each query, the top matches
// over the whole table and the intended place, and the search ranks each
// match by a key computed from that match alone, so the subset ranks them
// as the whole table does. The fixture's script cuts it again after a change
// to the ranking's constants. Run it with
// `node test/scripts/place_search_queries_check.mjs`; it exits non-zero
// and names each query whose first result differs.

import {deepStrictEqual} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {buildPlaceIndex, searchPlaces} from "../../assets/js/place_search.js"
import {tableOfJsonColumns} from "./place_records.mjs"

const QUERY_COUNT = 30
const RESULT_COUNT = 5

const fixtureUrl = new URL("../fixtures/places/queries/places.json", import.meta.url)
const fixture = JSON.parse(readFileSync(fixtureUrl, "utf8"))
const {center, queries} = fixture
const table = tableOfJsonColumns(fixture.table)

deepStrictEqual(queries.length, QUERY_COUNT, "the fixture holds the 30 queries")
const index = buildPlaceIndex(table)
const failures = []

for (const {query, intended} of queries) {
  const results = searchPlaces({index, query, center, resultCountMax: RESULT_COUNT})
  const [first] = results

  if (first === undefined) {
    failures.push(`${query}: no result`)
    continue
  }

  const found = {
    name: first.name,
    category: table.categoryNames[first.category],
    latitudeMicrodegrees: table.latitudeMicrodegrees[first.placeIndex],
    longitudeMicrodegrees: table.longitudeMicrodegrees[first.placeIndex]
  }

  try {
    deepStrictEqual(found, intended)
  } catch {
    failures.push(`${query}: first is ${JSON.stringify(found)}, intended ${JSON.stringify(intended)}`)
  }
}

deepStrictEqual(failures, [], "queries whose first result is not the intended place")
console.log(`place search query checks passed: ${queries.length} queries`)
