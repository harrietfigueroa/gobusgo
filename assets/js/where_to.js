// What the Trip tab's "Where to?" search decides, as pure functions: the
// one list of suggestions merged from the rider's recent trips and the
// searches of places, addresses, intersections, and stops, its groups in a
// fixed order and each bounded, the stop search by name and by code, the
// labels the results read as, the count a screen reader is told, the moves
// of the keyboard, and the bounded cache of decoded shards. Nothing here
// reads the document, the network, storage, or a clock.
//
// Each source's results stay its own: the list puts them side by side and
// never joins, removes, renames, or moves one result by another, the
// condition on which the OpenStreetMap places and intersections stand
// beside the agencies' stops as a Collective Database under the ODbL.

import {assertCondition, unreachable} from "./assert.js"
import {distanceMeters} from "./math/geodesy.js"
import {normalizedWords} from "./place_search.js"
import {EndKind, LOCATION_END, TripEnd, pointEnd, stopEnd} from "./trip_plan.js"

/** The groups of the list, in the order they stand. */
export const GroupKind = Object.freeze({
  recent: "recent",
  places: "places",
  addresses: "addresses",
  intersections: "intersections",
  stops: "stops",
})

/** The kinds of an option of the list. */
export const SuggestionKind = Object.freeze({
  location: "location",
  recent: "recent",
  place: "place",
  address: "address",
  intersection: "intersection",
  stop: "stop",
  favorite: "favorite",
  pick: "pick",
})

/** What choosing an option does: sets the searched end, replays a recent trip, or picks a stop on the map. */
export const ChoiceKind = Object.freeze({end: "end", trip: "trip", pick: "pick"})

/** The moves of the active option from the keyboard. */
export const OptionMove = Object.freeze({down: "down", up: "up", home: "home", end: "end"})

/** The most options each group shows. */
export const GROUP_COUNT_MAX = Object.freeze({
  [GroupKind.recent]: 3,
  [GroupKind.places]: 5,
  [GroupKind.addresses]: 3,
  [GroupKind.intersections]: 3,
  [GroupKind.stops]: 6,
})

/** The most recent trips the browser keeps. */
export const RECENT_TRIP_COUNT_MAX = 8

/** The center a search ranks by before it knows where the rider is: downtown Seattle. */
export const SEARCH_CENTER_DEFAULT = Object.freeze({lat: 47.6062, lon: -122.3321})

/** The most decoded shards of one kind the session keeps. */
export const SHARD_CACHE_COUNT_MAX = 16

/** The credit the place and intersection results carry, as the ODbL's notice for a Produced Work asks. */
export const OSM_CREDIT = Object.freeze({text: "Places ©", linkText: "OpenStreetMap", href: "https://www.openstreetmap.org/copyright"})

const GROUP_ORDER = Object.freeze([GroupKind.recent, GroupKind.places, GroupKind.addresses, GroupKind.intersections, GroupKind.stops])
const GROUP_LABELS = Object.freeze({
  [GroupKind.recent]: "Recent",
  [GroupKind.places]: "Places",
  [GroupKind.addresses]: "Addresses",
  [GroupKind.intersections]: "Intersections",
  [GroupKind.stops]: "Stops",
})
const CREDITED_GROUPS = Object.freeze([GroupKind.places, GroupKind.intersections])
const LOCATION_TEXT = "My location"
const PICK_TEXT = "Pick a stop on the map"
const FAVORITE_MARK = "★ "
const INTERSECTION_DETAIL = "Intersection"
const STOP_DETAIL = "Stop"
const DIRECTIONALS = new Set(["N", "S", "E", "W", "NE", "NW", "SE", "SW"])
const ORDINAL = /^(?<digits>\d+)(?<suffix>[A-Z]+)$/
const METERS_PER_KILOMETER = 1000
const METERS_ROUNDING = 10
const KILOMETERS_WHOLE_MIN = 10
const KILOMETER_DECIMALS = 1
const MICRODEGREES_PER_DEGREE = 1_000_000
const NONE_INDEX = -1
const CODE_PATTERN = /^\d+$/
const CachedKind = Object.freeze({cached: "cached", missing: "missing"})

// How a stop matches a text, best first.
const StopMatchRank = Object.freeze({code: 0, wholeName: 1, words: 2})

function isTripEnd(end) {
  return end === TripEnd.from || end === TripEnd.to
}

/** `text`, a street, an address, or two streets as the county or OpenStreetMap keys them, in title case with directionals and ordinals as people write them. */
export function streetLabelText(text) {
  const words = []

  for (const word of text.split(" ")) {
    const ordinal = ORDINAL.exec(word)

    if (DIRECTIONALS.has(word)) {
      words.push(word)
    } else if (ordinal === null) {
      words.push(word.charAt(0) + word.slice(1).toLowerCase())
    } else {
      words.push(ordinal.groups.digits + ordinal.groups.suffix.toLowerCase())
    }
  }

  return words.join(" ")
}

/** `meters`, a distance, as text: tens of meters under a kilometer, tenths of a kilometer under ten, and whole kilometers beyond. */
export function distanceText(meters) {
  assertCondition(meters >= 0, "where to: a distance is negative: " + meters)
  const rounded = Math.round(meters / METERS_ROUNDING) * METERS_ROUNDING

  if (rounded < METERS_PER_KILOMETER) {
    return `${rounded} m`
  }

  const kilometers = meters / METERS_PER_KILOMETER

  if (kilometers < KILOMETERS_WHOLE_MIN) {
    return `${kilometers.toFixed(KILOMETER_DECIMALS)} km`
  }

  return `${Math.round(kilometers)} km`
}

/** The detail line of a place: its category and its distance from the search's center. */
export function placeDetail({categoryName, distanceMeters: meters}) {
  const category = categoryName.charAt(0).toUpperCase() + categoryName.slice(1)
  return `${category} · ${distanceText(meters)}`
}

/** The name an end reads as in a recent trip. */
function endName(end) {
  switch (end.kind) {
    case EndKind.location:
      return LOCATION_TEXT
    case EndKind.stop:
    case EndKind.point:
      return end.name
    case EndKind.none:
      return assertCondition(false, "where to: a recent trip with no end")
    default:
      return unreachable(end.kind, "where to: an end of unknown kind")
  }
}

// Whether every word of `query` begins a word of `words`.
function isEveryWordBegun({query, words}) {
  for (const queryWord of query) {
    const isBegun = words.some((word) => word.startsWith(queryWord))

    if (!isBegun) {
      return false
    }
  }

  return true
}

/**
 * The recent trips `recents`, most recent first, that `text` matches: every
 * word of it begins a word of the name of either end. An empty text
 * matches every trip.
 */
export function recentMatches({recents, text}) {
  const query = normalizedWords(text)
  const matched = []

  for (const trip of recents) {
    const words = [...normalizedWords(endName(trip.from)), ...normalizedWords(endName(trip.to))]

    if (isEveryWordBegun({query, words})) {
      matched.push(trip)
    }
  }

  return matched
}

/**
 * The index the stop search reads, over a routing snapshot's stops:
 * `stopIds`, the stops file, `names` and `codes` by stop index from its
 * names file, each a string or null, and the positions file's
 * `latMicrodegrees` and `lonMicrodegrees`. The stops file holds the stops
 * a trip calls at and no parent station, so the search lists none.
 */
export function buildStopIndex({stopIds, names, codes, latMicrodegrees, lonMicrodegrees}) {
  const count = stopIds.length
  assertCondition(names.length === count, `where to: ${names.length} stop names for ${count} stops`)
  assertCondition(codes.length === count, `where to: ${codes.length} stop codes for ${count} stops`)
  assertCondition(latMicrodegrees.length === count, `where to: ${latMicrodegrees.length} stop positions for ${count} stops`)
  assertCondition(lonMicrodegrees.length === count, `where to: ${lonMicrodegrees.length} stop positions for ${count} stops`)
  const words = new Array(count)

  for (let stop = 0; stop < count; stop++) {
    const name = names[stop]

    if (typeof name === "string") {
      words[stop] = normalizedWords(name)
    } else {
      words[stop] = []
    }
  }

  return Object.freeze({stopIds, names, codes, words, latMicrodegrees, lonMicrodegrees})
}

function isSameWords({left, right}) {
  const isSameLength = left.length === right.length
  return isSameLength && left.every((word, index) => word === right[index])
}

// How the stop `stop` of `index` matches `query`, the words of `text`, or
// none.
function stopMatchRank({index, stop, query, text}) {
  const isNamed = typeof index.names[stop] === "string"

  if (!isNamed) {
    return NONE_INDEX
  }

  const isCode = CODE_PATTERN.test(text) && index.codes[stop] === text

  if (isCode) {
    return StopMatchRank.code
  } else if (isSameWords({left: index.words[stop], right: query})) {
    return StopMatchRank.wholeName
  } else if (isEveryWordBegun({query, words: index.words[stop]})) {
    return StopMatchRank.words
  }

  return NONE_INDEX
}

function byStopRank(left, right) {
  if (left.rank !== right.rank) {
    return left.rank - right.rank
  }

  if (left.distanceM !== right.distanceM) {
    return left.distanceM - right.distanceM
  }

  return left.stop - right.stop
}

/**
 * The stops of `index` that `text` names, at most `countMax`, best first,
 * each `{stopId, name, code}`: a code typed whole, then a name typed
 * whole, then the names each word of the text begins a word of, the
 * nearest `near`, `{lat, lon}` in degrees, first within each. A stop with
 * no name matches nothing, and an empty text matches no stop.
 */
export function searchStops({index, text, near, countMax}) {
  assertCondition(Number.isInteger(countMax), "where to: the stop bound is not whole: " + countMax)
  const trimmed = text.trim()
  const query = normalizedWords(trimmed)

  if (query.length === 0) {
    return []
  }

  const matches = []

  for (let stop = 0; stop < index.stopIds.length; stop++) {
    const rank = stopMatchRank({index, stop, query, text: trimmed})

    if (rank === NONE_INDEX) {
      continue
    }

    const position = [index.lonMicrodegrees[stop] / MICRODEGREES_PER_DEGREE, index.latMicrodegrees[stop] / MICRODEGREES_PER_DEGREE]
    matches.push({stop, rank, distanceM: distanceMeters([near.lon, near.lat], position)})
  }

  matches.sort(byStopRank)
  const kept = matches.slice(0, countMax)
  return Array.from(kept, (match) => ({stopId: index.stopIds[match.stop], name: index.names[match.stop], code: index.codes[match.stop]}))
}

function endOption({key, kind, text, detail, end}) {
  return {key, kind, text, detail, choice: {kind: ChoiceKind.end, end}}
}

function recentOption(trip, index) {
  const choice = {kind: ChoiceKind.trip, trip}
  return {key: `${SuggestionKind.recent}:${index}`, kind: SuggestionKind.recent, text: endName(trip.to), detail: `from ${endName(trip.from)}`, choice}
}

function placeOption(place, index) {
  const end = pointEnd({name: place.name, lat: place.lat, lon: place.lon})
  return endOption({key: `${SuggestionKind.place}:${index}`, kind: SuggestionKind.place, text: place.name, detail: place.detail, end})
}

function addressOption(address, index) {
  const [street] = address.label.split(",")
  const text = streetLabelText(street)
  const end = pointEnd({name: text, lat: address.lat, lon: address.lon})
  return endOption({key: `${SuggestionKind.address}:${index}`, kind: SuggestionKind.address, text, detail: streetLabelText(address.city), end})
}

function intersectionOption(intersection, index) {
  const text = streetLabelText(intersection.label)
  const end = pointEnd({name: text, lat: intersection.lat, lon: intersection.lon})
  return endOption({key: `${SuggestionKind.intersection}:${index}`, kind: SuggestionKind.intersection, text, detail: INTERSECTION_DETAIL, end})
}

function stopDetail(code) {
  if (typeof code === "string") {
    return `${STOP_DETAIL} #${code}`
  }

  return STOP_DETAIL
}

function stopOption(stop) {
  const end = stopEnd({stopId: stop.stopId, name: stop.name})
  return endOption({key: `${SuggestionKind.stop}:${stop.stopId}`, kind: SuggestionKind.stop, text: stop.name, detail: stopDetail(stop.code), end})
}

function favoriteOption(favorite) {
  const end = stopEnd({stopId: favorite.stopId, name: favorite.name})
  return endOption({key: `${SuggestionKind.favorite}:${favorite.stopId}`, kind: SuggestionKind.favorite, text: FAVORITE_MARK + favorite.name, detail: "", end})
}

function isCreditedGroup(group) {
  return CREDITED_GROUPS.includes(group.kind)
}

// The options of each group for a text, before the bounds.
function groupOptions({text, recents, favorites, found}) {
  const isEmpty = text.trim() === ""
  const options = {
    [GroupKind.recent]: Array.from(recentMatches({recents, text}), recentOption),
    [GroupKind.places]: Array.from(found.places, placeOption),
    [GroupKind.addresses]: Array.from(found.addresses, addressOption),
    [GroupKind.intersections]: Array.from(found.intersections, intersectionOption),
    [GroupKind.stops]: Array.from(found.stops, stopOption),
  }

  if (isEmpty) {
    options[GroupKind.stops] = Array.from(favorites, favoriteOption)
  }

  return options
}

/**
 * The list a search for the `end` of the trip, TripEnd.from or TripEnd.to,
 * shows for `text`: `groups`, each `{kind, label, options}` in the order
 * Recent, Places, Addresses, Intersections, Stops, a group with no option
 * left out and each at most its GROUP_COUNT_MAX; `leading`, the rider's
 * location for a From search; `trailing`, picking a stop on the map;
 * `count`, every option of the three; and `isCredited`, whether a group
 * of OpenStreetMap's results shows. `recents` are the recent trips, most
 * recent first; `favorites` the favorite stops, which an empty text lists
 * as its stops; and `found` the results of each search, best first:
 * `places` as `{name, detail, lat, lon}`, `addresses` and `intersections`
 * as their lookups return them, and `stops` as `searchStops` does.
 *
 * Each option is `{key, kind, text, detail, choice}`, its key distinct in
 * the list and `choice` a ChoiceKind member.
 */
export function suggestionList({text, end, recents, favorites, found}) {
  assertCondition(isTripEnd(end), "where to: a search for an end of unknown kind: " + end)
  const options = groupOptions({text, recents, favorites, found})
  const groups = []

  for (const kind of GROUP_ORDER) {
    const kept = options[kind].slice(0, GROUP_COUNT_MAX[kind])

    if (kept.length > 0) {
      groups.push({kind, label: GROUP_LABELS[kind], options: kept})
    }
  }

  const leading = []

  if (end === TripEnd.from) {
    leading.push(endOption({key: SuggestionKind.location, kind: SuggestionKind.location, text: LOCATION_TEXT, detail: "", end: LOCATION_END}))
  }

  const trailing = [{key: SuggestionKind.pick, kind: SuggestionKind.pick, text: PICK_TEXT, detail: "", choice: {kind: ChoiceKind.pick}}]
  let count = leading.length + trailing.length

  for (const group of groups) {
    count += group.options.length
  }

  const isCredited = groups.some(isCreditedGroup)
  return {groups, leading, trailing, count, isCredited}
}

/** The sentence the list's polite status holds for `count` options. */
export function suggestionsAnnouncement(count) {
  assertCondition(Number.isInteger(count), "where to: a count is not whole: " + count)

  if (count === 0) {
    return "No suggestions"
  } else if (count === 1) {
    return "1 suggestion"
  }

  return `${count} suggestions`
}

/**
 * The index of the option `move`, an OptionMove member, makes active from
 * `index` among `count` options, -1 for none: Down and Up wrap around, and
 * from no active option Down reaches the first and Up the last.
 */
export function movedOptionIndex({move, index, count}) {
  if (count === 0) {
    return NONE_INDEX
  }

  switch (move) {
    case OptionMove.down:
      return (index + 1) % count
    case OptionMove.up:
      if (index <= 0) {
        return count - 1
      }

      return index - 1
    case OptionMove.home:
      return 0
    case OptionMove.end:
      return count - 1
    default:
      return unreachable(move, "where to: a move of unknown kind")
  }
}

/**
 * A cache of decoded shards by path, keeping the `countMax` used last. Its
 * get of a path gives `{kind: "cached", table}` and marks it used, or
 * `{kind: "missing"}`; its put of a path and a table keeps the table and
 * lets the shard used longest ago go past the bound.
 */
export function createShardCache({countMax}) {
  assertCondition(Number.isInteger(countMax), "where to: the cache bound is not whole: " + countMax)
  assertCondition(countMax > 0, "where to: the cache bound is not positive: " + countMax)
  // A Map iterates in insertion order, so the first key is the one used
  // longest ago once each use deletes and inserts its key again.
  const tables = new Map()

  return Object.freeze({
    get(path) {
      if (!tables.has(path)) {
        return {kind: CachedKind.missing}
      }

      const table = tables.get(path)
      tables.delete(path)
      tables.set(path, table)
      return {kind: CachedKind.cached, table}
    },

    put({path, table}) {
      tables.delete(path)
      tables.set(path, table)

      while (tables.size > countMax) {
        const [oldest] = tables.keys()
        tables.delete(oldest)
      }
    },

    size() {
      return tables.size
    },
  })
}

/** The kinds `createShardCache`'s `get` returns. */
export const ShardCacheKind = CachedKind
