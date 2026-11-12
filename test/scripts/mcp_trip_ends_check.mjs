// Checks what the trip planner app decides of one end from the "Where to?"
// search's results, as pure functions over results written out by hand: one
// result in all resolves the end, several of one kind or of several kinds are
// the rider's to choose between, none is a miss, and the end a result sets is
// the one the Trip tab would set. Run it with `node
// test/scripts/mcp_trip_ends_check.mjs`; it exits non-zero on the first case
// that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {FallbackKind, ResolutionKind, fallbackWords, resolution} from "../../assets/js/mcp_trip_ends.js"
import {TripEnd, pointEnd, stopEnd} from "../../assets/js/core/trip_plan.js"
import {GROUP_COUNT_MAX, GroupKind} from "../../assets/js/where_to.js"

const none = {places: [], addresses: [], intersections: [], stops: []}
const westlake = {stopId: "1_75403", name: "Westlake Station", code: "75403"}
const pikePlace = {name: "Pike Place Market", detail: "Market", lat: 47.6094, lon: -122.3422}
const pikeCrossing = {label: "PIKE ST & 3RD AVE", lat: 47.6107, lon: -122.3372}
const pikeAddress = {label: "85 PIKE ST, SEATTLE", city: "SEATTLE", lat: 47.6091, lon: -122.3407}

const TWO_STOPS_COUNT = 2
const EXTRA_STOP_COUNT = 4

function kindOf(group) {
  return group.kind
}

function stopAt(_unused, index) {
  return {stopId: `1_${index}`, name: `Stop ${index}`, code: String(index)}
}

function resolveTo(found) {
  return resolution({text: "pike", end: TripEnd.to, found})
}

// One stop in all names the end on its own, as the stop the Trip tab sets.
const oneStop = resolveTo({...none, stops: [westlake]})
deepStrictEqual(oneStop.kind, ResolutionKind.resolved, "one stop resolves")
deepStrictEqual(oneStop.end, stopEnd({stopId: westlake.stopId, name: westlake.name}), "the stop's end")
deepStrictEqual(oneStop.option.text, "Westlake Station", "the stop's option")

// One place in all names a point end, with the place's position.
const onePlace = resolveTo({...none, places: [pikePlace]})
deepStrictEqual(onePlace.kind, ResolutionKind.resolved, "one place resolves")
deepStrictEqual(onePlace.end, pointEnd({name: pikePlace.name, lat: pikePlace.lat, lon: pikePlace.lon}), "the place's end")

// One crossing and one address each resolve too.
deepStrictEqual(resolveTo({...none, intersections: [pikeCrossing]}).kind, ResolutionKind.resolved, "one crossing resolves")
deepStrictEqual(resolveTo({...none, addresses: [pikeAddress]}).kind, ResolutionKind.resolved, "one address resolves")

// Two results of one kind are a choice, with their group.
const twoStops = resolveTo({...none, stops: [westlake, {stopId: "1_75404", name: "Westlake Station", code: "75404"}]})
deepStrictEqual(twoStops.kind, ResolutionKind.choices, "two stops are a choice")
const twoStopsKinds = Array.from(twoStops.groups, kindOf)
deepStrictEqual(twoStopsKinds, [GroupKind.stops], "the choice's groups")
deepStrictEqual(twoStops.groups[0].options.length, TWO_STOPS_COUNT, "both stops are offered")

// Results of several kinds are a choice, in the list's group order, and a credited group sets the credit.
const several = resolveTo({places: [pikePlace], addresses: [pikeAddress], intersections: [pikeCrossing], stops: [westlake]})
deepStrictEqual(several.kind, ResolutionKind.choices, "four kinds are a choice")
const severalKinds = Array.from(several.groups, kindOf)
deepStrictEqual(severalKinds, [GroupKind.places, GroupKind.addresses, GroupKind.intersections, GroupKind.stops], "the groups' order")
deepStrictEqual(several.isCredited, true, "places and intersections carry the credit")
deepStrictEqual(twoStops.isCredited, false, "stops alone carry no credit")

// No result is a miss.
deepStrictEqual(resolveTo(none), {kind: ResolutionKind.none}, "no result")

// A group is bounded as the search's list is, so a long result list stays bounded.
const manyStops = Array.from({length: GROUP_COUNT_MAX[GroupKind.stops] + EXTRA_STOP_COUNT}, stopAt)
const bounded = resolveTo({...none, stops: manyStops})
deepStrictEqual(bounded.groups[0].options.length, GROUP_COUNT_MAX[GroupKind.stops], "the stop group's bound")

// Every option of a choice sets an end.
for (const group of several.groups) {
  for (const option of group.options) {
    deepStrictEqual(typeof option.choice.end.kind, "string", `the end of ${option.key}`)
  }
}

// The From end's search resolves the same, and offers no location of its own.
const fromStop = resolution({text: "westlake", end: TripEnd.from, found: {...none, stops: [westlake]}})
deepStrictEqual(fromStop.kind, ResolutionKind.resolved, "one stop resolves a From end")

// Blank words are a programmer error: the caller checks them before searching.
throws(() => resolution({text: "   ", end: TripEnd.to, found: none}), AssertionError)

// The words as given decide the end when they find any result; the stripped
// words are searched only when the words as given find none and differ.
const foundOne = resolveTo({...none, stops: [westlake]})
const foundMany = twoStops
const foundNone = resolveTo(none)

const fallbackCases = [
  {name: "one result settles on the words as given", first: foundOne, text: "A, B", words: "A", expected: {kind: FallbackKind.settled, resolution: foundOne}},
  {name: "several results settle on the words as given", first: foundMany, text: "A, B", words: "A", expected: {kind: FallbackKind.settled, resolution: foundMany}},
  {name: "no result and different words search the stripped words", first: foundNone, text: "A, B", words: "A", expected: {kind: FallbackKind.search, words: "A"}},
  {name: "no result and the same words settle on none with one search", first: foundNone, text: "A", words: "A", expected: {kind: FallbackKind.settled, resolution: foundNone}},
]

for (const {name, first, text, words, expected} of fallbackCases) {
  deepStrictEqual(fallbackWords({first, text, words}), expected, name)
}

console.log("mcp_trip_ends_check: all cases passed")
