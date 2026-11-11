// Cuts the fixture of the 30 queries from the real places: for each query,
// the top matches over the whole table and the intended place, the union
// written as the table's columns. The search ranks each match by a key
// computed from that match alone, so the subset ranks its members exactly
// as the whole table does. Cut it again whenever the ranking's constants
// change, since the top matches depend on them. Run it with
// `node test/scripts/place_search_fixture.mjs --records <records json> --out test/fixtures/places/queries`;
// `--intended` names the queries and the intended places' names, by default
// the file beside the output.

import {mkdirSync, readFileSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {parseArgs} from "node:util"
import {assertCondition} from "../../assets/js/assert.js"
import {buildPlaceIndex, searchPlaces} from "../../assets/js/place_search.js"
import {jsonColumnsOfTable, tableOfRecords} from "./place_records.mjs"

const TOP_COUNT = 20
const FIXTURE_NAME = "places.json"
const INTENDED_NAME = "intended_places.json"
const MICRODEGREES_PER_DEGREE = 1_000_000
const SQUARE = 2

function isIntended({table, placeIndex, entry}) {
  const isNamed = entry.names.includes(table.names[placeIndex])
  const categoryName = table.categoryNames[table.categories[placeIndex]]
  const isCategoryFree = entry.category === undefined
  const hasCategory = isCategoryFree || categoryName === entry.category
  return isNamed && hasCategory
}

function distanceSquared({table, placeIndex, center}) {
  const north = table.latitudeMicrodegrees[placeIndex] / MICRODEGREES_PER_DEGREE - center.latitude
  const east = table.longitudeMicrodegrees[placeIndex] / MICRODEGREES_PER_DEGREE - center.longitude
  return north ** SQUARE + east ** SQUARE
}

function intendedPlaceIndex({table, center, entry}) {
  const candidates = []

  for (let placeIndex = 0; placeIndex < table.placeCount; placeIndex++) {
    if (isIntended({table, placeIndex, entry})) {
      candidates.push(placeIndex)
    }
  }

  assertCondition(candidates.length > 0, `place search fixture: no place for ${entry.query}`)
  let best = candidates[0]

  for (const candidate of candidates) {
    const isNearer = distanceSquared({table, placeIndex: candidate, center}) < distanceSquared({table, placeIndex: best, center})

    if (isNearer) {
      best = candidate
    }
  }

  return best
}

function subsetTable({table, placeIndexes}) {
  const placeCount = placeIndexes.length
  const names = []
  const aliasNames = []
  const aliasStarts = new Uint32Array(placeCount + 1)
  const latitudeMicrodegrees = new Int32Array(placeCount)
  const longitudeMicrodegrees = new Int32Array(placeCount)
  const categories = new Uint8Array(placeCount)
  const prominences = new Uint8Array(placeCount)
  const areas = new Uint8Array(placeCount)

  for (let subsetIndex = 0; subsetIndex < placeCount; subsetIndex++) {
    const placeIndex = placeIndexes[subsetIndex]
    names.push(table.names[placeIndex])
    aliasStarts[subsetIndex] = aliasNames.length

    for (let aliasIndex = table.aliasStarts[placeIndex]; aliasIndex < table.aliasStarts[placeIndex + 1]; aliasIndex++) {
      aliasNames.push(table.aliasNames[aliasIndex])
    }

    latitudeMicrodegrees[subsetIndex] = table.latitudeMicrodegrees[placeIndex]
    longitudeMicrodegrees[subsetIndex] = table.longitudeMicrodegrees[placeIndex]
    categories[subsetIndex] = table.categories[placeIndex]
    prominences[subsetIndex] = table.prominences[placeIndex]
    areas[subsetIndex] = table.areas[placeIndex]
  }

  aliasStarts[placeCount] = aliasNames.length
  return {placeCount, names, aliasStarts, aliasNames, latitudeMicrodegrees, longitudeMicrodegrees, categories, prominences, areas, categoryNames: table.categoryNames}
}

const {values} = parseArgs({options: {records: {type: "string"}, out: {type: "string"}, intended: {type: "string"}}, strict: true})
assertCondition(values.records !== undefined, "place search fixture: --records is required")
assertCondition(values.out !== undefined, "place search fixture: --out is required")
let intendedPath = values.intended

if (intendedPath === undefined) {
  intendedPath = join(values.out, INTENDED_NAME)
}

const records = JSON.parse(readFileSync(values.records, "utf8"))
const intended = JSON.parse(readFileSync(intendedPath, "utf8"))
const table = tableOfRecords(records)
const index = buildPlaceIndex(table)
const center = intended.center
const wanted = new Set()
const queries = []

for (const entry of intended.queries) {
  const results = searchPlaces({index, query: entry.query, center, resultCountMax: TOP_COUNT})

  for (const result of results) {
    wanted.add(result.placeIndex)
  }

  const placeIndex = intendedPlaceIndex({table, center, entry})
  wanted.add(placeIndex)

  queries.push({
    query: entry.query,
    intended: {
      name: table.names[placeIndex],
      category: table.categoryNames[table.categories[placeIndex]],
      latitudeMicrodegrees: table.latitudeMicrodegrees[placeIndex],
      longitudeMicrodegrees: table.longitudeMicrodegrees[placeIndex]
    }
  })
}

const placeIndexes = Array.from(wanted).sort((left, right) => left - right)
const subset = subsetTable({table, placeIndexes})
const fixture = {sourceDate: records.sourceDate, center, queries, table: jsonColumnsOfTable(subset)}
mkdirSync(values.out, {recursive: true})
writeFileSync(join(values.out, FIXTURE_NAME), `${JSON.stringify(fixture)}\n`)
console.log(`${placeIndexes.length} places for ${queries.length} queries written to ${join(values.out, FIXTURE_NAME)}`)
