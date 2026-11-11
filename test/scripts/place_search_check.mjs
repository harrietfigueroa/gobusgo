// Checks the place search on places written out by hand: the shared
// normalization fixture, each kind of word match, each tier, the distance
// band, the prominence gap, the area rule, the bounds of a query and of the
// results, and the input it refuses. Each case builds the few places it
// needs, so a failing case names the behavior that broke. Run it with
// `node test/scripts/place_search_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {AssertionError} from "../../assets/js/assert.js"
import {
  AREA_MAX,
  buildPlaceIndex,
  distanceBand,
  editDistanceBounded,
  editsAllowed,
  normalizedWords,
  placeRank,
  PROMINENCE_STEP_POINTS,
  QUERY_LENGTH_MAX,
  QUERY_WORD_COUNT_MAX,
  RESULT_COUNT_MAX,
  searchPlaces,
  TIER_NAME,
  TIER_TYPO,
  TIER_WRITTEN
} from "../../assets/js/place_search.js"

const MICRODEGREES_PER_DEGREE = 1_000_000
const CENTER = Object.freeze({latitude: 47.6114, longitude: -122.337})
// A degree of latitude is about 111 km, so these offsets from the center
// stand in the first three bands and past the last.
const NEAR_LATITUDE = 47.6214
const RIDE_LATITUDE = 47.6914
const METRO_LATITUDE = 47.9514
const FAR_LATITUDE = 48.6114
// A multiple of the prominence step, so a case reads the step's edges off it.
const PROMINENCE_BASE = 50
const PROMINENCE_DEFAULT = PROMINENCE_BASE
const RESULT_COUNT = 10
const CATEGORY_NAMES = Object.freeze(["place", "food"])
// About 450 m north, inside the walking band from the near latitude.
const BLOCK_LATITUDE_DEGREES = 0.004
// About 1.1 km north.
const SHORT_RIDE_LATITUDE_DEGREES = 0.01
const CROWD_LATITUDE_DEGREES = 0.0001
const CROWD_OVER_COUNT = 5
const SMALL_RESULT_COUNT = 3
const PAIR_RESULT_COUNT = 2
const NOT_A_STRING = 7
const NEAR_DISTANCE_HUNDRED_METERS = 11
const HUNDRED_METERS = 100
const LONGITUDE_OVER_DEGREES = 181
const LATITUDE_OVER_DEGREES = 91

function place(overrides) {
  return {
    name: "Unnamed",
    aliases: [],
    latitude: CENTER.latitude,
    longitude: CENTER.longitude,
    category: 0,
    prominence: PROMINENCE_DEFAULT,
    area: 0,
    ...overrides
  }
}

function tableOf(places) {
  const placeCount = places.length
  const names = []
  const aliasNames = []
  const aliasStarts = new Uint32Array(placeCount + 1)
  const latitudeMicrodegrees = new Int32Array(placeCount)
  const longitudeMicrodegrees = new Int32Array(placeCount)
  const categories = new Uint8Array(placeCount)
  const prominences = new Uint8Array(placeCount)
  const areas = new Uint8Array(placeCount)

  for (let placeIndex = 0; placeIndex < placeCount; placeIndex++) {
    const each = places[placeIndex]
    names.push(each.name)
    aliasStarts[placeIndex] = aliasNames.length

    for (const alias of each.aliases) {
      aliasNames.push(alias)
    }

    latitudeMicrodegrees[placeIndex] = Math.round(each.latitude * MICRODEGREES_PER_DEGREE)
    longitudeMicrodegrees[placeIndex] = Math.round(each.longitude * MICRODEGREES_PER_DEGREE)
    categories[placeIndex] = each.category
    prominences[placeIndex] = each.prominence
    areas[placeIndex] = each.area
  }

  aliasStarts[placeCount] = aliasNames.length
  return {placeCount, names, aliasStarts, aliasNames, latitudeMicrodegrees, longitudeMicrodegrees, categories, prominences, areas, categoryNames: CATEGORY_NAMES}
}

function found({places, query, resultCountMax = RESULT_COUNT}) {
  const index = buildPlaceIndex(tableOf(places))
  return searchPlaces({index, query, center: CENTER, resultCountMax})
}

function namesAndTiers(results) {
  const pairs = []

  for (const result of results) {
    pairs.push([result.name, result.tier])
  }

  return pairs
}

function namesOf(results) {
  const names = []

  for (const result of results) {
    names.push(result.name)
  }

  return names
}

// The shared normalization fixture, which the Elixir build checks too.
const normalizedUrl = new URL("../fixtures/places/normalized_words.json", import.meta.url)
const normalizedCases = JSON.parse(readFileSync(normalizedUrl, "utf8"))

for (const {text, words} of normalizedCases) {
  deepStrictEqual(normalizedWords(text), words, `normalizedWords of ${JSON.stringify(text)}`)
}

const lumen = place({name: "Lumen Field"})
const lumenCenter = place({name: "Lumen Field Event Center"})
const dicks = place({name: "Dick's Drive-In"})
const harborview = place({name: "Harborview Medical Center", aliases: ["Harborview"]})

// Each case: the places, the query, and the names and tiers it finds, best first.
const matchCases = [
  {name: "the same word", places: [lumen], query: "field", expected: [["Lumen Field", TIER_WRITTEN]]},
  {name: "every word, in any order", places: [lumen], query: "field lumen", expected: [["Lumen Field", TIER_WRITTEN]]},
  {name: "the beginning of a word", places: [lumen], query: "lum", expected: [["Lumen Field", TIER_WRITTEN]]},
  {name: "a word of an alias", places: [harborview], query: "harborview", expected: [["Harborview Medical Center", TIER_NAME]]},
  {name: "an apostrophe dropped", places: [dicks], query: "dicks", expected: [["Dick's Drive-In", TIER_WRITTEN]]},
  {name: "a diacritic dropped", places: [place({name: "Café Allegro"})], query: "cafe allegro", expected: [["Café Allegro", TIER_NAME]]},
  {name: "a word no place holds", places: [lumen], query: "zebra", expected: []},
  {name: "one word of two missing", places: [lumen], query: "lumen zebra", expected: []},
  {name: "no typo in a word of three letters", places: [place({name: "Bar Harbor"})], query: "bat", expected: []},
  {name: "a typo of one edit in a word of four letters", places: [lumen], query: "lumn", expected: [["Lumen Field", TIER_TYPO]]},
  {name: "a typo of one edit in a word of seven letters", places: [place({name: "Seattle Center"})], query: "sxattle", expected: [["Seattle Center", TIER_TYPO]]},
  {name: "two edits refused in a word of seven letters", places: [place({name: "Seattle Center"})], query: "sxattlx", expected: []},
  {name: "two typos of one edit in two words", places: [lumen], query: "lumin feild", expected: [["Lumen Field", TIER_TYPO]]},
  {name: "two edits in a word of eight letters", places: [harborview], query: "harbrvew", expected: [["Harborview Medical Center", TIER_TYPO]]},
  {name: "a transposition is one edit", places: [lumen], query: "feild", expected: [["Lumen Field", TIER_TYPO]]},
  {name: "a first letter that is wrong", places: [lumen], query: "kield", expected: []},
  {name: "a typo in a word that is not the last", places: [lumen], query: "lumin field", expected: [["Lumen Field", TIER_TYPO]]},
  {name: "the last word as a fuzzy prefix", places: [place({name: "Pike Place Market"})], query: "pike place markt", expected: [["Pike Place Market", TIER_TYPO]]},
  {name: "a fuzzy prefix of the last word only", places: [place({name: "Pike Place Market"})], query: "pika place market", expected: [["Pike Place Market", TIER_TYPO]]},
  {name: "a typo in a word that is neither the last nor the first", places: [place({name: "Pike Place Market"})], query: "plac pikes market", expected: [["Pike Place Market", TIER_TYPO]]},
  {name: "st read as saint", places: [place({name: "Saint Marks Cathedral"})], query: "st marks", expected: [["Saint Marks Cathedral", TIER_WRITTEN]]},
  {name: "st read as street", places: [place({name: "King Street Station"})], query: "king st station", expected: [["King Street Station", TIER_WRITTEN]]},
  {name: "mt read as mount", places: [place({name: "Mount Rainier"})], query: "mt rainier", expected: [["Mount Rainier", TIER_WRITTEN]]},
  {name: "ave read as avenue", places: [place({name: "Fifth Avenue Theater"})], query: "fifth ave theater", expected: [["Fifth Avenue Theater", TIER_WRITTEN]]},
  {name: "ctr read as center", places: [place({name: "Seattle Center"})], query: "seattle ctr", expected: [["Seattle Center", TIER_WRITTEN]]},
  {name: "hosp read as hospital", places: [place({name: "Harborview Hospital"})], query: "harborview hosp", expected: [["Harborview Hospital", TIER_WRITTEN]]},
  {name: "univ read as university", places: [place({name: "University Village"})], query: "univ village", expected: [["University Village", TIER_WRITTEN]]},
  {name: "centre read as center", places: [place({name: "Seattle Center"})], query: "seattle centre", expected: [["Seattle Center", TIER_NAME]]},
  {name: "theatre read as theater", places: [place({name: "5th Avenue Theatre"})], query: "5th avenue theater", expected: [["5th Avenue Theatre", TIER_NAME]]}
]

for (const {name, places, query, expected} of matchCases) {
  const results = found({places, query})
  deepStrictEqual(namesAndTiers(results), expected, name)
}

// Each case: the places, the query, and the names it finds in order, whose first holds the tier asked.
const tierCases = [
  {
    name: "a name spelled out whole before names it begins",
    places: [lumenCenter, lumen],
    query: "lumen field",
    expected: [["Lumen Field", TIER_NAME], ["Lumen Field Event Center", TIER_WRITTEN]]
  },
  {
    name: "an alias spelled out whole is a name",
    places: [harborview],
    query: "harborview",
    expected: [["Harborview Medical Center", TIER_NAME]]
  },
  {
    name: "a written match before a typo",
    places: [place({name: "Lumin Feild Cafe"}), lumenCenter],
    query: "lumen field",
    expected: [["Lumen Field Event Center", TIER_WRITTEN], ["Lumin Feild Cafe", TIER_TYPO]]
  },
  {
    name: "a farther name outranks a nearer written match",
    places: [place({name: "Lumen Field Event Center", latitude: NEAR_LATITUDE, prominence: 200}), place({name: "Lumen Field", latitude: FAR_LATITUDE, prominence: 0})],
    query: "lumen field",
    expected: [["Lumen Field", TIER_NAME], ["Lumen Field Event Center", TIER_WRITTEN]]
  }
]

for (const {name, places, query, expected} of tierCases) {
  const results = found({places, query})
  deepStrictEqual(namesAndTiers(results), expected, name)
}

// Each case: places that tie in tier, the query, and the names in the order they rank.
const rankCases = [
  {
    name: "a nearer band first",
    places: [place({name: "Costco Ride", latitude: RIDE_LATITUDE}), place({name: "Costco Near", latitude: NEAR_LATITUDE}), place({name: "Costco Metro", latitude: METRO_LATITUDE})],
    query: "costco",
    expected: ["Costco Near", "Costco Ride", "Costco Metro"]
  },
  {
    name: "a past-the-last-band place after the metro band",
    places: [place({name: "Costco Far", latitude: FAR_LATITUDE}), place({name: "Costco Metro", latitude: METRO_LATITUDE})],
    query: "costco",
    expected: ["Costco Metro", "Costco Far"]
  },
  {
    name: "more prominent first within a band",
    places: [place({name: "Costco Plain", latitude: NEAR_LATITUDE, prominence: 50}), place({name: "Costco Known", latitude: NEAR_LATITUDE + BLOCK_LATITUDE_DEGREES, prominence: PROMINENCE_BASE + PROMINENCE_STEP_POINTS})],
    query: "costco",
    expected: ["Costco Known", "Costco Plain"]
  },
  {
    name: "a prominence gap inside one step loses to one band",
    places: [place({name: "Costco Ride", latitude: RIDE_LATITUDE, prominence: PROMINENCE_BASE + PROMINENCE_STEP_POINTS - 1}), place({name: "Costco Near", latitude: NEAR_LATITUDE, prominence: PROMINENCE_BASE})],
    query: "costco",
    expected: ["Costco Near", "Costco Ride"]
  },
  {
    name: "a prominence gap across a step boundary beats one band",
    places: [place({name: "Costco Near", latitude: NEAR_LATITUDE, prominence: PROMINENCE_BASE - 1}), place({name: "Costco Ride", latitude: RIDE_LATITUDE, prominence: PROMINENCE_BASE})],
    query: "costco",
    expected: ["Costco Ride", "Costco Near"]
  },
  {
    name: "a prominence step does not beat more bands than it is worth",
    places: [place({name: "Costco Near", latitude: NEAR_LATITUDE, prominence: PROMINENCE_BASE}), place({name: "Costco Metro", latitude: METRO_LATITUDE, prominence: PROMINENCE_BASE + PROMINENCE_STEP_POINTS})],
    query: "costco",
    expected: ["Costco Near", "Costco Metro"]
  },
  {
    name: "the nearer first where only the prominence differs inside one step",
    places: [place({name: "Costco Far", latitude: NEAR_LATITUDE + BLOCK_LATITUDE_DEGREES, prominence: PROMINENCE_BASE + PROMINENCE_STEP_POINTS - 1}), place({name: "Costco Near", latitude: NEAR_LATITUDE, prominence: PROMINENCE_BASE})],
    query: "costco",
    expected: ["Costco Near", "Costco Far"]
  },
  {
    name: "the nearer first where only the area differs",
    places: [place({name: "Costco Far", latitude: NEAR_LATITUDE + BLOCK_LATITUDE_DEGREES, area: AREA_MAX}), place({name: "Costco Near", latitude: NEAR_LATITUDE, area: 0})],
    query: "costco",
    expected: ["Costco Near", "Costco Far"]
  },
  {
    name: "the nearer first where every key but the distance ties",
    places: [place({name: "Costco B", latitude: RIDE_LATITUDE}), place({name: "Costco A", latitude: RIDE_LATITUDE - SHORT_RIDE_LATITUDE_DEGREES})],
    query: "costco",
    expected: ["Costco A", "Costco B"]
  },
  {
    name: "the table's order where the places tie in every key",
    places: [place({name: "Costco First"}), place({name: "Costco Second"})],
    query: "costco",
    expected: ["Costco First", "Costco Second"]
  }
]

for (const {name, places, query, expected} of rankCases) {
  const results = found({places, query})
  deepStrictEqual(namesOf(results), expected, name)
}

// The rank reads one place alone, so its order among places needs none of the others.
const stepAbove = placeRank({distanceMeters: HUNDRED_METERS, prominence: PROMINENCE_BASE})
const stepBelow = placeRank({distanceMeters: HUNDRED_METERS, prominence: PROMINENCE_BASE - PROMINENCE_STEP_POINTS})
deepStrictEqual(stepAbove < stepBelow, true, "the rank is lower for a place a step more prominent")

const bandCases = [
  {name: "the center", distanceMeters: 0, expected: 0},
  {name: "just inside the walk", distanceMeters: 1999, expected: 0},
  {name: "the walk's bound", distanceMeters: 2000, expected: 1},
  {name: "just inside the ride", distanceMeters: 9999, expected: 1},
  {name: "the metro area", distanceMeters: 39999, expected: 2},
  {name: "the last bound", distanceMeters: 40000, expected: 3},
  {name: "far away", distanceMeters: 1_000_000, expected: 3}
]

for (const {name, distanceMeters, expected} of bandCases) {
  deepStrictEqual(distanceBand(distanceMeters), expected, name)
}

const editCases = [
  {name: "equal words", source: "field", target: "field", limit: 2, expected: 0},
  {name: "a substitution", source: "field", target: "fiald", limit: 2, expected: 1},
  {name: "a transposition", source: "feild", target: "field", limit: 2, expected: 1},
  {name: "an insertion and a deletion", source: "fild", target: "fielda", limit: 2, expected: 2},
  {name: "past the limit", source: "abcdef", target: "zzzzzz", limit: 2, expected: 3},
  {name: "a length gap past the limit", source: "a", target: "abcd", limit: 2, expected: 3}
]

for (const {name, source, target, limit, expected} of editCases) {
  deepStrictEqual(editDistanceBounded({source, target, limit}), expected, name)
}

const allowedCases = [
  {word: "abc", expected: 0},
  {word: "abcd", expected: 1},
  {word: "abcdefg", expected: 1},
  {word: "abcdefgh", expected: 2}
]

for (const {word, expected} of allowedCases) {
  deepStrictEqual(editsAllowed(word), expected, `edits allowed in ${word}`)
}

// The bounds.
const longQuery = `lumen field${" ".repeat(QUERY_LENGTH_MAX)}zebra`
const longResults = found({places: [lumen], query: longQuery})
deepStrictEqual(namesOf(longResults), ["Lumen Field"], "characters past the length bound are ignored")
const manyWords = `lumen field ${"x ".repeat(QUERY_WORD_COUNT_MAX)}`
const manyResults = found({places: [lumen], query: manyWords})
deepStrictEqual(namesOf(manyResults), [], "a word within the word bound that no place holds refuses the place")
const wordCountOver = `${"lumen ".repeat(QUERY_WORD_COUNT_MAX)}zebra`
const overResults = found({places: [lumen], query: wordCountOver})
deepStrictEqual(namesOf(overResults), ["Lumen Field"], "a word past the word bound is ignored")

function crowdPlace(crowdIndex) {
  return place({name: `Costco ${crowdIndex}`, latitude: NEAR_LATITUDE + crowdIndex * CROWD_LATITUDE_DEGREES})
}

const crowd = Array.from({length: RESULT_COUNT_MAX + CROWD_OVER_COUNT}, (_, crowdIndex) => crowdPlace(crowdIndex))
const smallResults = found({places: crowd, query: "costco", resultCountMax: SMALL_RESULT_COUNT})
deepStrictEqual(smallResults.length, SMALL_RESULT_COUNT, "the results stop at the count asked")
const largestResults = found({places: crowd, query: "costco", resultCountMax: RESULT_COUNT_MAX})
deepStrictEqual(largestResults.length, RESULT_COUNT_MAX, "the results stop at the largest count")
const pairResults = found({places: crowd, query: "costco", resultCountMax: PAIR_RESULT_COUNT})
deepStrictEqual(namesOf(pairResults), ["Costco 0", "Costco 1"], "the results are the best of the matches")

// An empty query and a query of no word match nothing.
deepStrictEqual(found({places: [lumen], query: ""}), [], "an empty query")
deepStrictEqual(found({places: [lumen], query: "  --  "}), [], "a query of separators")
deepStrictEqual(found({places: [], query: "lumen"}), [], "a table of no place")

// A result names its place's category and its distance from the center.
const resultCase = found({places: [place({name: "Lumen Field", category: 1, latitude: NEAR_LATITUDE})], query: "lumen field"})
deepStrictEqual(resultCase.length, 1, "one result")
deepStrictEqual(resultCase[0].category, 1, "the result's category")
deepStrictEqual(resultCase[0].placeIndex, 0, "the result's place index")
const distanceHundreds = Math.round(resultCase[0].distanceMeters / HUNDRED_METERS)
deepStrictEqual(distanceHundreds, NEAR_DISTANCE_HUNDRED_METERS, "the result's distance, in hundreds of meters")

// Invalid input is refused.
const validTable = tableOf([lumen])
const validIndex = buildPlaceIndex(validTable)

const tableCases = [
  {name: "a place count that is not an integer", table: {...validTable, placeCount: 1.5}},
  {name: "names of another length", table: {...validTable, names: ["a", "b"]}},
  {name: "a name that is not a string", table: {...validTable, names: [NOT_A_STRING]}},
  {name: "alias starts of another length", table: {...validTable, aliasStarts: new Uint32Array(1)}},
  {name: "alias starts that end short of the aliases", table: {...validTable, aliasNames: ["extra"]}},
  {name: "alias starts that run backwards", table: {...tableOf([lumen, lumen]), aliasStarts: Uint32Array.from([0, 1, 0]), aliasNames: ["a"]}},
  {name: "latitudes of the wrong type", table: {...validTable, latitudeMicrodegrees: new Float64Array(1)}},
  {name: "longitudes of another length", table: {...validTable, longitudeMicrodegrees: new Int32Array(PAIR_RESULT_COUNT)}},
  {name: "a category past the names", table: {...validTable, categories: Uint8Array.from([CATEGORY_NAMES.length])}},
  {name: "prominences of the wrong type", table: {...validTable, prominences: new Uint16Array(1)}},
  {name: "an area past its largest", table: {...validTable, areas: Uint8Array.from([AREA_MAX + 1])}},
  {name: "a table that is no object", table: null}
]

for (const {name, table} of tableCases) {
  throws(() => buildPlaceIndex(table), AssertionError, name)
}

const searchCases = [
  {name: "a query that is not a string", options: {query: NOT_A_STRING, center: CENTER, resultCountMax: 1}},
  {name: "a center with no latitude", options: {query: "a", center: {longitude: 0}, resultCountMax: 1}},
  {name: "a center with a latitude out of range", options: {query: "a", center: {latitude: LATITUDE_OVER_DEGREES, longitude: 0}, resultCountMax: 1}},
  {name: "a center with a longitude out of range", options: {query: "a", center: {latitude: 0, longitude: LONGITUDE_OVER_DEGREES}, resultCountMax: 1}},
  {name: "a result count of zero", options: {query: "a", center: CENTER, resultCountMax: 0}},
  {name: "a result count that is not an integer", options: {query: "a", center: CENTER, resultCountMax: 1.5}},
  {name: "a result count past the largest", options: {query: "a", center: CENTER, resultCountMax: RESULT_COUNT_MAX + 1}}
]

for (const {name, options} of searchCases) {
  throws(() => searchPlaces({index: validIndex, ...options}), AssertionError, name)
}

throws(() => normalizedWords(NOT_A_STRING), AssertionError, "text that is not a string")
throws(() => editDistanceBounded({source: "a", target: "b", limit: -1}), AssertionError, "a negative edit limit")

console.log("place search checks passed")
