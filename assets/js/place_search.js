// Searches the named places of an OpenStreetMap extract in the browser, so
// what a rider types never leaves the device and the search works offline.
// Everything here is pure: it reads no DOM, no clock, and no storage, which
// is what lets a fixture of a query's top candidates rank them exactly as
// the whole file does.
//
// A query matches a place when each of its words matches a word of one of
// the place's names: the same word, a word it begins, or a word within the
// edits its length allows. The last word, still being typed, also matches
// a beginning of a word within those edits.
//
// A match ranks by a sort key computed from that match alone, never from
// the other matches, so the order is total and a subset of the places
// ranks its members as the whole table does. The key is, in order:
//
// 1. The tier: a name the query spells out whole, then every word matched
//    as written, then a word matched through a typo.
// 2. The rank, lower first: the distance band of the place from the
//    center, less PROMINENCE_STEP_BANDS bands for each whole step of
//    PROMINENCE_STEP_POINTS of the place's prominence. A step is wider
//    than the gap between the category bases of two shops of one chain, so
//    those rank by distance, and a place a step more prominent outranks
//    one a band nearer, so a hospital 7 km away outranks a museum of the
//    same name words in the walking band. The area column does not enter
//    the rank: places that differ only by area rank by distance.
// 3. The distance from the center, then the index of the place, so two
//    places that tie in everything above keep the table's order.
//
// The index is columnar, typed arrays and one flat posting list, so a place
// costs the heap its strings and a few dozen bytes.

import {assertCondition} from "./assert.js"
import {METERS_PER_DEGREE, metersPerDegreeLongitude} from "./math/geodesy.js"

/** The tier of a place one of whose names the query spells out whole. */
export const TIER_NAME = 1

/** The tier of a place whose words all match as written, the same word or a word it begins. */
export const TIER_WRITTEN = 2

/** The tier of a place one of whose words matches only within an edit distance. */
export const TIER_TYPO = 3

const TIER_NONE = 0

const WALK_METERS_MAX = 2000
const RIDE_METERS_MAX = 10000
const METRO_METERS_MAX = 40000

/**
 * The upper bounds of the distance bands, in meters: a walk, a short ride,
 * and the metro area. A place past the last bound is in a band of its own.
 */
export const DISTANCE_BAND_BOUNDS_METERS = Object.freeze([WALK_METERS_MAX, RIDE_METERS_MAX, METRO_METERS_MAX])

/**
 * The width of a prominence step, in prominence points. Two entries of one
 * chain whose categories' bases differ by 5 points share a step and rank by
 * distance; a place across a step boundary from another outranks it from a
 * band farther, so a hospital of prominence 190 outranks a museum of the
 * same name words at 185 in the walking band.
 */
export const PROMINENCE_STEP_POINTS = 10

/** The distance bands a whole prominence step is worth in the rank. */
export const PROMINENCE_STEP_BANDS = 2

/** The most an `areas` entry holds: a score of the place's area, from 0 up. */
export const AREA_MAX = 40

/** The most words of a query that match; the rest are ignored. */
export const QUERY_WORD_COUNT_MAX = 8

/** The most characters of a query that match; the rest are ignored. */
export const QUERY_LENGTH_MAX = 100

/** The most results a search returns. */
export const RESULT_COUNT_MAX = 50

const EDIT_FREE_LENGTH_MAX = 3
const ONE_EDIT_LENGTH_MAX = 7
const EDITS_MAX = 2
const FNV_OFFSET = 0x811c9dc5
const FNV_PRIME = 0x01000193
const SPACE_CODE = 0x20
const LATITUDE_DEGREES_MAX = 90
const LONGITUDE_DEGREES_MAX = 180
const MICRODEGREES_PER_DEGREE = 1_000_000
const HALF = 2
// A transposition spans two letters of each word.
const SWAP_SPAN = 2

/**
 * Words a rider abbreviates: a query word on the left also matches the
 * words on the right.
 */
const QUERY_WORD_ALTERNATIVES = new Map([
  ["st", ["saint", "street"]],
  ["mt", ["mount"]],
  ["ave", ["avenue"]],
  ["ctr", ["center"]],
  ["hosp", ["hospital"]],
  ["univ", ["university"]]
])

/** Spellings that name one word, folded to one before indexing and matching. */
const WORD_SPELLINGS = new Map([
  ["centre", "center"],
  ["theatre", "theater"]
])

const DIACRITICS = /\p{M}/gu
const SEPARATORS = /[^\p{L}\p{N}]+/u
const APOSTROPHES = /['’]/g

/**
 * Returns the words of `text` as the index compares them: decomposed with
 * diacritics dropped, lowercase, "&" read as "and", apostrophes dropped,
 * split on everything that is not a letter or a digit, and "centre" and
 * "theatre" folded to "center" and "theater". The build of the places file
 * normalizes with the same rules.
 */
export function normalizedWords(text) {
  assertCondition(typeof text === "string", `place search: text is not a string: ${typeof text}`)
  const decomposed = text.normalize("NFD")
  const bare = decomposed.replace(DIACRITICS, "")
  const lower = bare.toLowerCase()
  const anded = lower.replaceAll("&", " and ")
  const joined = anded.replace(APOSTROPHES, "")
  const parts = joined.split(SEPARATORS)
  const words = []

  for (const part of parts) {
    if (part.length === 0) {
      continue
    }

    const spelling = WORD_SPELLINGS.get(part)

    if (spelling === undefined) {
      words.push(part)
    } else {
      words.push(spelling)
    }
  }

  return words
}

function wordsHash(words) {
  let hash = FNV_OFFSET

  for (let wordIndex = 0; wordIndex < words.length; wordIndex++) {
    const word = words[wordIndex]

    if (wordIndex > 0) {
      hash = Math.imul(hash ^ SPACE_CODE, FNV_PRIME)
    }

    for (let charIndex = 0; charIndex < word.length; charIndex++) {
      hash = Math.imul(hash ^ word.charCodeAt(charIndex), FNV_PRIME)
    }
  }

  return hash >>> 0
}

/** Returns the names of the place `placeIndex` of `table`: its name, then its aliases. */
export function placeNames({table, placeIndex}) {
  const names = [table.names[placeIndex]]
  const aliasStart = table.aliasStarts[placeIndex]
  const aliasEnd = table.aliasStarts[placeIndex + 1]

  for (let aliasIndex = aliasStart; aliasIndex < aliasEnd; aliasIndex++) {
    names.push(table.aliasNames[aliasIndex])
  }

  return names
}

function assertColumn({table, column, type, length}) {
  const values = table[column]
  assertCondition(values instanceof type, `place search: ${column} is not a ${type.name}`)
  assertCondition(values.length === length, `place search: ${values.length} ${column} for ${length} places`)
}

function assertStrings({values, label}) {
  assertCondition(Array.isArray(values), `place search: ${label} is not an array`)

  for (let index = 0; index < values.length; index++) {
    assertCondition(typeof values[index] === "string", `place search: ${label} ${index} is not a string`)
  }
}

function assertAliasStarts(table) {
  const {placeCount, aliasStarts, aliasNames} = table
  assertCondition(aliasStarts[0] === 0, `place search: the aliases start at ${aliasStarts[0]}, not 0`)
  assertCondition(aliasStarts[placeCount] === aliasNames.length, `place search: the aliases end at ${aliasStarts[placeCount]} of ${aliasNames.length}`)

  for (let placeIndex = 0; placeIndex < placeCount; placeIndex++) {
    const isOrdered = aliasStarts[placeIndex] <= aliasStarts[placeIndex + 1]
    assertCondition(isOrdered, `place search: the aliases of place ${placeIndex} end before they start`)
  }
}

function assertCodes(table) {
  const {placeCount, categories, areas, categoryNames} = table

  for (let placeIndex = 0; placeIndex < placeCount; placeIndex++) {
    const category = categories[placeIndex]
    assertCondition(category < categoryNames.length, `place search: place ${placeIndex} has category ${category} of ${categoryNames.length}`)
    const area = areas[placeIndex]
    assertCondition(area <= AREA_MAX, `place search: place ${placeIndex} has area ${area} over ${AREA_MAX}`)
  }
}

function assertTable(table) {
  assertCondition(typeof table === "object", `place search: the table is not an object: ${typeof table}`)
  assertCondition(table !== null, "place search: the table is null")
  const {placeCount} = table
  assertCondition(Number.isSafeInteger(placeCount), `place search: the place count is not an integer: ${placeCount}`)
  assertCondition(placeCount >= 0, `place search: the place count is negative: ${placeCount}`)
  assertStrings({values: table.names, label: "name"})
  assertCondition(table.names.length === placeCount, `place search: ${table.names.length} names for ${placeCount} places`)
  assertStrings({values: table.aliasNames, label: "alias"})
  assertStrings({values: table.categoryNames, label: "category name"})
  assertColumn({table, column: "aliasStarts", type: Uint32Array, length: placeCount + 1})
  assertColumn({table, column: "latitudeMicrodegrees", type: Int32Array, length: placeCount})
  assertColumn({table, column: "longitudeMicrodegrees", type: Int32Array, length: placeCount})
  assertColumn({table, column: "categories", type: Uint8Array, length: placeCount})
  assertColumn({table, column: "prominences", type: Uint8Array, length: placeCount})
  assertColumn({table, column: "areas", type: Uint8Array, length: placeCount})
  assertAliasStarts(table)
  assertCodes(table)
}

function addPlaceWords({postingsByWord, words, placeIndex}) {
  for (const word of words) {
    const postings = postingsByWord.get(word)

    if (postings === undefined) {
      postingsByWord.set(word, [placeIndex])
      continue
    }

    const lastIndex = postings.length - 1
    const isNewPlace = postings[lastIndex] !== placeIndex

    if (isNewPlace) {
      postings.push(placeIndex)
    }
  }
}

function compareNameKeys(left, right) {
  if (left.hash !== right.hash) {
    return left.hash - right.hash
  }

  return left.placeIndex - right.placeIndex
}

/**
 * Returns the index of `table`, a place table: `placeCount`; `names`, one
 * per place; `aliasStarts` and `aliasNames`, where the aliases of place `i`
 * are `aliasNames[aliasStarts[i]..aliasStarts[i + 1])`; the columns
 * `latitudeMicrodegrees` and `longitudeMicrodegrees` (Int32Array),
 * `categories`, `prominences`, and `areas` (Uint8Array), one entry per
 * place, with `areas` from 0 to AREA_MAX; and `categoryNames`, which
 * `categories` indexes. The index holds every word of every name in sorted
 * order with one flat list of the places that hold each, and a hash of each
 * whole name. It holds `table` itself and copies none of it.
 */
export function buildPlaceIndex(table) {
  assertTable(table)
  const {placeCount} = table
  const postingsByWord = new Map()
  const nameKeys = []

  for (let placeIndex = 0; placeIndex < placeCount; placeIndex++) {
    const names = placeNames({table, placeIndex})

    for (const name of names) {
      const words = normalizedWords(name)
      addPlaceWords({postingsByWord, words, placeIndex})
      nameKeys.push({hash: wordsHash(words), placeIndex})
    }
  }

  const words = Array.from(postingsByWord.keys())
  // The default order is by UTF-16 code unit, the order `lowerBound` and `startsWith` assume.
  words.sort()
  let postingCount = 0

  for (const word of words) {
    postingCount += postingsByWord.get(word).length
  }

  const postingStarts = new Uint32Array(words.length + 1)
  const postings = new Uint32Array(postingCount)
  let postingIndex = 0

  for (let wordIndex = 0; wordIndex < words.length; wordIndex++) {
    postingStarts[wordIndex] = postingIndex

    for (const placeIndex of postingsByWord.get(words[wordIndex])) {
      postings[postingIndex] = placeIndex
      postingIndex++
    }
  }

  postingStarts[words.length] = postingIndex
  assertCondition(postingIndex === postingCount, `place search: wrote ${postingIndex} postings of ${postingCount}`)
  nameKeys.sort(compareNameKeys)
  const nameHashes = new Uint32Array(nameKeys.length)
  const namePlaces = new Uint32Array(nameKeys.length)

  for (let keyIndex = 0; keyIndex < nameKeys.length; keyIndex++) {
    nameHashes[keyIndex] = nameKeys[keyIndex].hash
    namePlaces[keyIndex] = nameKeys[keyIndex].placeIndex
  }

  return {table, placeCount, words, postingStarts, postings, nameHashes, namePlaces}
}

function lowerBound({sorted, target}) {
  let low = 0
  let high = sorted.length

  while (low < high) {
    const middle = Math.floor((low + high) / HALF)

    if (sorted[middle] < target) {
      low = middle + 1
    } else {
      high = middle
    }
  }

  return low
}

/**
 * Returns the edits the optimal string alignment distance needs between
 * `source` and `target`, or `limit + 1` once every alignment needs more
 * than `limit`. A transposition of two neighbors is one edit.
 */
export function editDistanceBounded({source, target, limit}) {
  assertCondition(Number.isSafeInteger(limit), `place search: the edit limit is not an integer: ${limit}`)
  assertCondition(limit >= 0, `place search: the edit limit is negative: ${limit}`)
  const lengthGap = Math.abs(source.length - target.length)

  if (lengthGap > limit) {
    return limit + 1
  }

  const width = target.length + 1
  let before = new Uint8Array(width)
  let previous = new Uint8Array(width)
  let current = new Uint8Array(width)

  for (let column = 0; column < width; column++) {
    previous[column] = column
  }

  for (let row = 1; row <= source.length; row++) {
    current[0] = row
    let rowMinimum = row

    for (let column = 1; column < width; column++) {
      let cost = 1
      const isSameLetter = source[row - 1] === target[column - 1]

      if (isSameLetter) {
        cost = 0
      }

      let best = Math.min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
      const isPastStart = row > 1 && column > 1
      const isTransposed = isPastStart && source[row - 1] === target[column - SWAP_SPAN]
      const isSwap = isTransposed && source[row - SWAP_SPAN] === target[column - 1]

      if (isSwap) {
        best = Math.min(best, before[column - SWAP_SPAN] + 1)
      }

      current[column] = best

      if (best < rowMinimum) {
        rowMinimum = best
      }
    }

    if (rowMinimum > limit) {
      return limit + 1
    }

    const spare = before
    before = previous
    previous = current
    current = spare
  }

  return previous[target.length]
}

/** The edits a query word of this length allows: none up to 3 letters, one up to 7, two beyond. */
export function editsAllowed(word) {
  if (word.length <= EDIT_FREE_LENGTH_MAX) {
    return 0
  }

  if (word.length <= ONE_EDIT_LENGTH_MAX) {
    return 1
  }

  return EDITS_MAX
}

// The words that begin with `word` are contiguous in the sorted words, and so
// are their postings, so the range of postings is one slice of the list.
function writtenPostingRange({index, word}) {
  const first = lowerBound({sorted: index.words, target: word})
  let last = first

  while (last < index.words.length) {
    const indexWord = index.words[last]

    if (!indexWord.startsWith(word)) {
      break
    }

    last++
  }

  return {postingStart: index.postingStarts[first], postingEnd: index.postingStarts[last]}
}

function typoDistance({word, indexWord, limit, isLastWord}) {
  const whole = editDistanceBounded({source: word, target: indexWord, limit})

  if (!isLastWord) {
    return whole
  }

  // A word still being typed may hold a dropped or an extra letter, so it is
  // compared with each beginning of the index word within the edits allowed.
  let best = whole
  const prefixLengthMin = Math.max(1, word.length - limit)
  const prefixLengthMax = Math.min(indexWord.length, word.length + limit)

  for (let prefixLength = prefixLengthMin; prefixLength <= prefixLengthMax; prefixLength++) {
    const prefix = indexWord.slice(0, prefixLength)
    const begun = editDistanceBounded({source: word, target: prefix, limit})
    best = Math.min(best, begun)
  }

  return best
}

function typoWordIndexes({index, word, isLastWord}) {
  const wordIndexes = []
  const limit = editsAllowed(word)

  if (limit === 0) {
    return wordIndexes
  }

  const firstLetter = word[0]

  for (let wordIndex = 0; wordIndex < index.words.length; wordIndex++) {
    const indexWord = index.words[wordIndex]
    const isTooShort = indexWord.length < word.length - limit
    const isTooLong = !isLastWord && indexWord.length > word.length + limit
    const isOutOfReach = isTooShort || isTooLong

    if (isOutOfReach) {
      continue
    }

    // A typo in the first letter is rare, and one swapped with the second
    // is a transposition, so an index word whose first two letters both
    // differ from the query's first is never within reach.
    const isOtherFirstLetter = indexWord[0] !== firstLetter && indexWord[1] !== firstLetter

    if (isOtherFirstLetter) {
      continue
    }

    const distance = typoDistance({word, indexWord, limit, isLastWord})

    if (distance <= limit) {
      wordIndexes.push(wordIndex)
    }
  }

  return wordIndexes
}

// The tier of every place for one query word: the better of the tiers of the
// index words it matches, none for a place no matching word is in.
function wordMarks({index, word, isLastWord}) {
  const marks = new Uint8Array(index.placeCount)
  const spellings = [word]
  const alternatives = QUERY_WORD_ALTERNATIVES.get(word)

  if (alternatives !== undefined) {
    for (const alternative of alternatives) {
      spellings.push(alternative)
    }
  }

  const ranges = []

  for (const spelling of spellings) {
    const {postingStart, postingEnd} = writtenPostingRange({index, word: spelling})
    ranges.push({tier: TIER_WRITTEN, postingStart, postingEnd})
  }

  const typos = typoWordIndexes({index, word, isLastWord})

  for (const wordIndex of typos) {
    ranges.push({tier: TIER_TYPO, postingStart: index.postingStarts[wordIndex], postingEnd: index.postingStarts[wordIndex + 1]})
  }

  for (const {tier, postingStart, postingEnd} of ranges) {
    for (let postingIndex = postingStart; postingIndex < postingEnd; postingIndex++) {
      const placeIndex = index.postings[postingIndex]
      const mark = marks[placeIndex]
      const isUnmarked = mark === TIER_NONE
      const isBetter = isUnmarked || tier < mark

      if (isBetter) {
        marks[placeIndex] = tier
      }
    }
  }

  return marks
}

function hasNameSpelledOut({index, placeIndex, words}) {
  const names = placeNames({table: index.table, placeIndex})
  const query = words.join(" ")

  for (const name of names) {
    const nameWords = normalizedWords(name)
    const spelled = nameWords.join(" ")

    if (spelled === query) {
      return true
    }
  }

  return false
}

function spelledOutPlaces({index, words}) {
  const hash = wordsHash(words)
  const places = new Set()
  let keyIndex = lowerBound({sorted: index.nameHashes, target: hash})

  while (keyIndex < index.nameHashes.length) {
    if (index.nameHashes[keyIndex] !== hash) {
      break
    }

    const placeIndex = index.namePlaces[keyIndex]
    // Two names can share a hash, so the name itself decides.
    const isSpelledOut = hasNameSpelledOut({index, placeIndex, words})

    if (isSpelledOut) {
      places.add(placeIndex)
    }

    keyIndex++
  }

  return places
}

/** The index of the distance band of a place `distanceMeters` from the center, 0 for the nearest. */
export function distanceBand(distanceMeters) {
  for (let bandIndex = 0; bandIndex < DISTANCE_BAND_BOUNDS_METERS.length; bandIndex++) {
    if (distanceMeters < DISTANCE_BAND_BOUNDS_METERS[bandIndex]) {
      return bandIndex
    }
  }

  return DISTANCE_BAND_BOUNDS_METERS.length
}

/**
 * The rank of a place, lower first: its distance band less
 * PROMINENCE_STEP_BANDS for each whole step of its prominence. It reads the
 * place alone.
 */
export function placeRank({distanceMeters, prominence}) {
  const band = distanceBand(distanceMeters)
  const prominenceSteps = Math.floor(prominence / PROMINENCE_STEP_POINTS)
  return band - prominenceSteps * PROMINENCE_STEP_BANDS
}

function compareMatches(left, right) {
  if (left.tier !== right.tier) {
    return left.tier - right.tier
  }

  if (left.rank !== right.rank) {
    return left.rank - right.rank
  }

  if (left.distanceMeters !== right.distanceMeters) {
    return left.distanceMeters - right.distanceMeters
  }

  return left.placeIndex - right.placeIndex
}

function assertCenter(center) {
  assertCondition(typeof center === "object", `place search: the center is not an object: ${typeof center}`)
  assertCondition(center !== null, "place search: the center is null")
  const {latitude, longitude} = center
  assertCondition(Number.isFinite(latitude), `place search: the center's latitude is not a number: ${latitude}`)
  assertCondition(Number.isFinite(longitude), `place search: the center's longitude is not a number: ${longitude}`)
  assertCondition(Math.abs(latitude) <= LATITUDE_DEGREES_MAX, `place search: the center's latitude is out of range: ${latitude}`)
  assertCondition(Math.abs(longitude) <= LONGITUDE_DEGREES_MAX, `place search: the center's longitude is out of range: ${longitude}`)
}

function placeTier({marksByWord, placeIndex}) {
  let tier = TIER_NONE

  for (const marks of marksByWord) {
    const mark = marks[placeIndex]

    if (mark === TIER_NONE) {
      return TIER_NONE
    }

    if (mark > tier) {
      tier = mark
    }
  }

  return tier
}

function queryWords(query) {
  const trimmed = query.slice(0, QUERY_LENGTH_MAX)
  const allWords = normalizedWords(trimmed)
  return allWords.slice(0, QUERY_WORD_COUNT_MAX)
}

/**
 * Returns at most `resultCountMax` matches of `query` in `index`, ranked as
 * the module header says, each `{placeIndex, name, category, tier,
 * distanceMeters}` with `category` an index into the table's
 * `categoryNames`. `center` is `{latitude, longitude}` in degrees. A query
 * with no word returns no match. A query longer than QUERY_LENGTH_MAX
 * characters or QUERY_WORD_COUNT_MAX words matches by the part within the
 * bound.
 */
export function searchPlaces({index, query, center, resultCountMax}) {
  assertCenter(center)
  assertCondition(typeof query === "string", `place search: the query is not a string: ${typeof query}`)
  assertCondition(Number.isSafeInteger(resultCountMax), `place search: the result count is not an integer: ${resultCountMax}`)
  assertCondition(resultCountMax > 0, `place search: the result count is not positive: ${resultCountMax}`)
  assertCondition(resultCountMax <= RESULT_COUNT_MAX, `place search: the result count ${resultCountMax} is over ${RESULT_COUNT_MAX}`)
  const words = queryWords(query)

  if (words.length === 0) {
    return []
  }

  const lastWordIndex = words.length - 1
  const marksByWord = []

  for (let wordIndex = 0; wordIndex < words.length; wordIndex++) {
    const isLastWord = wordIndex === lastWordIndex
    const marks = wordMarks({index, word: words[wordIndex], isLastWord})
    marksByWord.push(marks)
  }

  const spelledOut = spelledOutPlaces({index, words})
  const table = index.table
  const metersPerDegreeLon = metersPerDegreeLongitude(center.latitude)
  const matches = []

  for (let placeIndex = 0; placeIndex < index.placeCount; placeIndex++) {
    let tier = placeTier({marksByWord, placeIndex})

    if (tier === TIER_NONE) {
      continue
    }

    if (spelledOut.has(placeIndex)) {
      tier = TIER_NAME
    }

    const latitude = table.latitudeMicrodegrees[placeIndex] / MICRODEGREES_PER_DEGREE
    const longitude = table.longitudeMicrodegrees[placeIndex] / MICRODEGREES_PER_DEGREE
    const northMeters = (latitude - center.latitude) * METERS_PER_DEGREE
    const eastMeters = (longitude - center.longitude) * metersPerDegreeLon
    const distanceMeters = Math.hypot(northMeters, eastMeters)
    const prominence = table.prominences[placeIndex]
    const rank = placeRank({distanceMeters, prominence})
    matches.push({placeIndex, tier, rank, distanceMeters})
  }

  matches.sort(compareMatches)
  const results = []

  for (const match of matches) {
    if (results.length === resultCountMax) {
      break
    }

    const {placeIndex, tier, distanceMeters} = match
    results.push({placeIndex, name: table.names[placeIndex], category: table.categories[placeIndex], tier, distanceMeters})
  }

  return results
}
