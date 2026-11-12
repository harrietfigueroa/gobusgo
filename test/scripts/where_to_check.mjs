// Checks what the Trip tab's "Where to?" search decides as pure functions
// over results and stops written out by hand: the merged list's groups,
// their order and bounds, the empty search, the options a From search adds,
// the OpenStreetMap credit, the stop search by name and by code, the recent
// trips a text matches, the labels of the address and intersection results,
// the announcement of the count, the keyboard's moves, and the bounded
// cache of decoded shards. Run it with `node test/scripts/where_to_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {EndKind, LOCATION_END, TripEnd, pointEnd, stopEnd} from "../../assets/js/trip_plan.js"
import {
  ChoiceKind,
  GROUP_COUNT_MAX,
  GroupKind,
  OptionMove,
  ShardCacheKind,
  SuggestionKind,
  buildStopIndex,
  createShardCache,
  distanceText,
  movedOptionIndex,
  placeDetail,
  recentMatches,
  searchStops,
  streetLabelText,
  suggestionList,
  suggestionsAnnouncement,
} from "../../assets/js/where_to.js"

const MICRODEGREES = 1_000_000
const NEAR = {lat: 47.6097, lon: -122.3331}
const MANY_RESULTS = 9
const STOP_COUNT_MAX = 5
const STOP_COUNT_BOUNDED = 2
const OPTION_COUNT = 4
const NONE_INDEX = -1
const FIRST_INDEX = 0
const SECOND_INDEX = 1
const THIRD_INDEX = 2
const LAST_INDEX = OPTION_COUNT - 1
const NO_OPTIONS = 0
const ONE_OPTION = 1
const SEVEN_OPTIONS = 7
const CACHE_COUNT_MAX = 2
const FROM_LEADING_COUNT = 1
const TRAILING_COUNT = 1
const LATITUDE_OFF_GLOBE = 91
const LONGITUDE_ZERO = 0

// Distances and the texts they read as: a rounding to ten meters, a
// kilometer reached by rounding, tenths under ten kilometers, and whole
// kilometers beyond.
const DISTANCE_CASES = Object.freeze([
  {meters: 0, text: "0 m"},
  {meters: 44, text: "40 m"},
  {meters: 346, text: "350 m"},
  {meters: 999, text: "1.0 km"},
  {meters: 1000, text: "1.0 km"},
  {meters: 1260, text: "1.3 km"},
  {meters: 9949, text: "9.9 km"},
  {meters: 12400, text: "12 km"},
])

function micro(degrees) {
  return Math.round(degrees * MICRODEGREES)
}

function latOf(position) {
  return micro(position.lat)
}

function lonOf(position) {
  return micro(position.lon)
}

function kindOf(item) {
  return item.kind
}

function labelOf(group) {
  return group.label
}

function textOf(option) {
  return option.text
}

function detailOf(option) {
  return option.detail
}

function keyOf(option) {
  return option.key
}

function stopIdOf(stop) {
  return stop.stopId
}

function optionsOf(group) {
  return group.options
}

function place(name) {
  return {name, detail: "Tourism · 300 m", lat: 47.6, lon: -122.3}
}

function address(label) {
  return {label, city: "SEATTLE", lat: 47.61, lon: -122.34}
}

function intersection(label) {
  return {label, lat: 47.61, lon: -122.338}
}

function stopResult(stopId) {
  return {stopId, name: `Stop ${stopId}`, code: stopId}
}

function recentTo(name) {
  const to = pointEnd({name: `Pike ${name}`, lat: 47.6, lon: -122.3})
  return {from: LOCATION_END, to}
}

function numberText(_value, index) {
  return String(index)
}

function numbered({count, of}) {
  const names = Array.from({length: count}, numberText)
  return Array.from(names, of)
}

const pike = pointEnd({name: "Pike Place Market", lat: 47.6094, lon: -122.3422})
const westlake = stopEnd({stopId: "1_100", name: "Westlake Station"})
const tripToPike = {from: LOCATION_END, to: pike}
const tripToWestlake = {from: pike, to: westlake}
const noResults = {places: [], addresses: [], intersections: [], stops: []}
const oneOfEach = {places: [place("Pike Place Market")], addresses: [address("85 PIKE ST, SEATTLE")], intersections: [intersection("PIKE ST & 1ST AVE")], stops: [stopResult("575")]}

// The groups stand in their fixed order, and a group with no result is left out.
{
  const list = suggestionList({text: "pike", end: TripEnd.to, recents: [tripToPike], favorites: [], found: oneOfEach})
  const kinds = Array.from(list.groups, kindOf)
  const labels = Array.from(list.groups, labelOf)
  deepStrictEqual(kinds, [GroupKind.recent, GroupKind.places, GroupKind.addresses, GroupKind.intersections, GroupKind.stops])
  deepStrictEqual(labels, ["Recent", "Places", "Addresses", "Intersections", "Stops"])

  const addressOnly = {...noResults, addresses: [address("85 PIKE ST, SEATTLE")]}
  const sparse = suggestionList({text: "85 pike", end: TripEnd.to, recents: [], favorites: [], found: addressOnly})
  const sparseKinds = Array.from(sparse.groups, kindOf)
  deepStrictEqual(sparseKinds, [GroupKind.addresses])
}

// Each group holds at most its bound, the first of its results, and the
// count is every option shown.
{
  const found = {
    places: numbered({count: MANY_RESULTS, of: place}),
    addresses: numbered({count: MANY_RESULTS, of: address}),
    intersections: numbered({count: MANY_RESULTS, of: intersection}),
    stops: numbered({count: MANY_RESULTS, of: stopResult}),
  }
  const recents = numbered({count: MANY_RESULTS, of: recentTo})
  const list = suggestionList({text: "pike", end: TripEnd.to, recents, favorites: [], found})
  let shownCount = TRAILING_COUNT

  for (const group of list.groups) {
    deepStrictEqual(group.options.length, GROUP_COUNT_MAX[group.kind], group.kind)
    shownCount += group.options.length
  }

  const placeTexts = Array.from(list.groups[SECOND_INDEX].options, textOf)
  deepStrictEqual(placeTexts, ["0", "1", "2", "3", "4"])
  deepStrictEqual(list.count, shownCount)
}

// A To search ends with picking on the map; a From search starts with the
// rider's location as well.
{
  const to = suggestionList({text: "", end: TripEnd.to, recents: [], favorites: [], found: noResults})
  const trailingKinds = Array.from(to.trailing, kindOf)
  deepStrictEqual(to.leading, [])
  deepStrictEqual(trailingKinds, [SuggestionKind.pick])
  deepStrictEqual(to.trailing[FIRST_INDEX].choice, {kind: ChoiceKind.pick})

  const from = suggestionList({text: "", end: TripEnd.from, recents: [], favorites: [], found: noResults})
  const leadingKinds = Array.from(from.leading, kindOf)
  deepStrictEqual(leadingKinds, [SuggestionKind.location])
  deepStrictEqual(from.leading[FIRST_INDEX].choice, {kind: ChoiceKind.end, end: LOCATION_END})
  deepStrictEqual(from.count, FROM_LEADING_COUNT + TRAILING_COUNT)
}

// An empty search lists the recent trips and the favorites as stops.
{
  const favorites = [{stopId: "1_100", name: "Westlake Station"}, {stopId: "1_200", name: "Pine St & 3rd Ave"}]
  const list = suggestionList({text: "  ", end: TripEnd.to, recents: [tripToPike, tripToWestlake], favorites, found: noResults})
  const [recentGroup, stopGroup] = list.groups
  const kinds = Array.from(list.groups, kindOf)
  const recentTexts = Array.from(recentGroup.options, textOf)
  const recentDetails = Array.from(recentGroup.options, detailOf)
  const stopTexts = Array.from(stopGroup.options, textOf)
  deepStrictEqual(kinds, [GroupKind.recent, GroupKind.stops])
  deepStrictEqual(recentTexts, ["Pike Place Market", "Westlake Station"])
  deepStrictEqual(recentDetails, ["from My location", "from Pike Place Market"])
  deepStrictEqual(recentGroup.options[FIRST_INDEX].choice, {kind: ChoiceKind.trip, trip: tripToPike})
  deepStrictEqual(stopTexts, ["★ Westlake Station", "★ Pine St & 3rd Ave"])
  deepStrictEqual(stopGroup.options[FIRST_INDEX].choice, {kind: ChoiceKind.end, end: westlake})
}

// The credit shows under the place and intersection results and nowhere else.
{
  const withPlaces = suggestionList({text: "x", end: TripEnd.to, recents: [], favorites: [], found: {...noResults, places: [place("A")]}})
  const withCrossings = suggestionList({text: "x", end: TripEnd.to, recents: [], favorites: [], found: {...noResults, intersections: [intersection("A & B")]}})
  const withStops = suggestionList({text: "x", end: TripEnd.to, recents: [], favorites: [], found: {...noResults, stops: [stopResult("1")], addresses: [address("1 A ST")]}})
  deepStrictEqual([withPlaces.isCredited, withCrossings.isCredited, withStops.isCredited], [true, true, false])
}

// Each result's option ends the trip at its point or its stop, and the
// option keys are distinct across groups.
{
  const list = suggestionList({text: "pike", end: TripEnd.to, recents: [], favorites: [], found: oneOfEach})
  const options = list.groups.flatMap(optionsOf)
  const texts = Array.from(options, textOf)
  const details = Array.from(options, detailOf)
  const [placeOption, addressOption, intersectionOption, stopOption] = options
  deepStrictEqual(texts, ["Pike Place Market", "85 Pike St", "Pike St & 1st Ave", "Stop 575"])
  deepStrictEqual(details, ["Tourism · 300 m", "Seattle", "Intersection", "Stop #575"])
  deepStrictEqual(placeOption.choice.end, pointEnd({name: "Pike Place Market", lat: 47.6, lon: -122.3}))
  deepStrictEqual(addressOption.choice.end, pointEnd({name: "85 Pike St", lat: 47.61, lon: -122.34}))
  deepStrictEqual(intersectionOption.choice.end, pointEnd({name: "Pike St & 1st Ave", lat: 47.61, lon: -122.338}))
  deepStrictEqual(stopOption.choice.end, stopEnd({stopId: "575", name: "Stop 575"}))
  const keys = Array.from([...options, ...list.trailing], keyOf)
  const distinctKeys = new Set(keys)
  deepStrictEqual(distinctKeys.size, keys.length)
}

// A search for an end that is neither From nor To is a program error.
{
  throws(() => suggestionList({text: "x", end: "sideways", recents: [], favorites: [], found: noResults}), AssertionError)
}

// Street labels read in title case with directionals and ordinals as people write them.
{
  deepStrictEqual(streetLabelText("85 PIKE ST"), "85 Pike St")
  deepStrictEqual(streetLabelText("1200 NE 45TH ST"), "1200 NE 45th St")
  deepStrictEqual(streetLabelText("3RD AVE & PINE ST"), "3rd Ave & Pine St")
  deepStrictEqual(streetLabelText("MARTIN LUTHER KING JR WAY S"), "Martin Luther King Jr Way S")
}

// Distances read in meters under a kilometer and in kilometers beyond.
for (const {meters, text} of DISTANCE_CASES) {
  deepStrictEqual(distanceText(meters), text, `distance: ${meters} m`)
}

// The stop search: a code typed whole comes first, then the names that
// hold every word, nearest first; a stop with no name is found by neither.
{
  const positions = [
    {lat: 47.6097, lon: -122.3375},
    {lat: 47.6099, lon: -122.3377},
    {lat: 47.6087, lon: -122.3404},
    {lat: 47.6, lon: -122.3},
    {lat: 47.611, lon: -122.336},
  ]
  const stops = {
    stopIds: ["1_575", "1_576", "1_700", "1_800", "1_900"],
    names: ["3rd Ave & Pike St", "3rd Ave & Pike St", "Pike St & 1st Ave", null, "Pine St & 3rd Ave"],
    codes: ["575", "576", "700", "800", null],
    latMicrodegrees: Int32Array.from(positions, latOf),
    lonMicrodegrees: Int32Array.from(positions, lonOf),
  }
  const index = buildStopIndex(stops)
  const byName = searchStops({index, text: "pike st", near: NEAR, countMax: STOP_COUNT_MAX})
  const byNameIds = Array.from(byName, stopIdOf)
  deepStrictEqual(byNameIds, ["1_575", "1_576", "1_700"])
  deepStrictEqual(byName[FIRST_INDEX], {stopId: "1_575", name: "3rd Ave & Pike St", code: "575"})

  const byCode = searchStops({index, text: "700", near: NEAR, countMax: STOP_COUNT_MAX})
  const byCodeIds = Array.from(byCode, stopIdOf)
  deepStrictEqual(byCodeIds, ["1_700"])

  const bounded = searchStops({index, text: "3rd", near: NEAR, countMax: STOP_COUNT_BOUNDED})
  deepStrictEqual(bounded.length, STOP_COUNT_BOUNDED)
  deepStrictEqual(searchStops({index, text: "", near: NEAR, countMax: STOP_COUNT_MAX}), [])
  deepStrictEqual(searchStops({index, text: "800", near: NEAR, countMax: STOP_COUNT_MAX}), [])
  throws(() => buildStopIndex({...stops, codes: ["575"]}), AssertionError)
}

// A recent trip matches when every typed word begins a word of either end's name.
{
  const recents = [tripToPike, tripToWestlake]
  deepStrictEqual(recentMatches({recents, text: "pike pl"}), [tripToPike, tripToWestlake])
  deepStrictEqual(recentMatches({recents, text: "westl"}), [tripToWestlake])
  deepStrictEqual(recentMatches({recents, text: "ballard"}), [])
  deepStrictEqual(recentMatches({recents, text: ""}), recents)
}

// The polite status says how many suggestions the list holds.
{
  deepStrictEqual(suggestionsAnnouncement(NO_OPTIONS), "No suggestions")
  deepStrictEqual(suggestionsAnnouncement(ONE_OPTION), "1 suggestion")
  deepStrictEqual(suggestionsAnnouncement(SEVEN_OPTIONS), "7 suggestions")
}

// Down and Up wrap around, Home and End go to the ends, and from no active
// option Down reaches the first and Up the last.
{
  deepStrictEqual(movedOptionIndex({move: OptionMove.down, index: NONE_INDEX, count: OPTION_COUNT}), FIRST_INDEX)
  deepStrictEqual(movedOptionIndex({move: OptionMove.up, index: NONE_INDEX, count: OPTION_COUNT}), LAST_INDEX)
  deepStrictEqual(movedOptionIndex({move: OptionMove.down, index: LAST_INDEX, count: OPTION_COUNT}), FIRST_INDEX)
  deepStrictEqual(movedOptionIndex({move: OptionMove.up, index: FIRST_INDEX, count: OPTION_COUNT}), LAST_INDEX)
  deepStrictEqual(movedOptionIndex({move: OptionMove.home, index: THIRD_INDEX, count: OPTION_COUNT}), FIRST_INDEX)
  deepStrictEqual(movedOptionIndex({move: OptionMove.end, index: FIRST_INDEX, count: OPTION_COUNT}), LAST_INDEX)
  deepStrictEqual(movedOptionIndex({move: OptionMove.down, index: NONE_INDEX, count: NO_OPTIONS}), NONE_INDEX)
}

// The shard cache keeps the most recently used shards, at most its bound.
{
  const cache = createShardCache({countMax: CACHE_COUNT_MAX})
  cache.put({path: "a", table: "A"})
  cache.put({path: "b", table: "B"})
  deepStrictEqual(cache.get("a"), {kind: ShardCacheKind.cached, table: "A"})
  cache.put({path: "c", table: "C"})
  deepStrictEqual(cache.get("b"), {kind: ShardCacheKind.missing})
  deepStrictEqual(cache.get("a"), {kind: ShardCacheKind.cached, table: "A"})
  deepStrictEqual(cache.get("c"), {kind: ShardCacheKind.cached, table: "C"})
  deepStrictEqual(cache.size(), CACHE_COUNT_MAX)
  throws(() => createShardCache({countMax: NO_OPTIONS}), AssertionError)
}

// A place's detail line is its category, then its locality, then its distance, and drops the locality when the place has none.
const PLACE_DETAIL_CASES = [
  {name: "with a locality", given: {categoryName: "shop", locality: "Denny Triangle, Seattle", distanceMeters: 300}, expected: "Shop · Denny Triangle, Seattle · 300 m"},
  {name: "with a street address", given: {categoryName: "food", locality: "400 Pine Street", distanceMeters: 1_500}, expected: "Food · 400 Pine Street · 1.5 km"},
  {name: "with no locality", given: {categoryName: "tourism", locality: "", distanceMeters: 300}, expected: "Tourism · 300 m"}
]

for (const {name, given, expected} of PLACE_DETAIL_CASES) {
  deepStrictEqual(placeDetail(given), expected, `place detail: ${name}`)
}

// A point end keeps its kind, and one off the globe is refused.
{
  deepStrictEqual(pike.kind, EndKind.point)
  throws(() => pointEnd({name: "Nowhere", lat: LATITUDE_OFF_GLOBE, lon: LONGITUDE_ZERO}), AssertionError)
}

console.log("where_to_check: every case passed")
