// Checks which vehicles dim while routes' lines are emphasized, and how a
// list of routes moves the emphasis, as pure functions of values written out
// by hand: nothing dims without an emphasized route, only the vehicles of
// other routes dim, a vehicle with no route dims, the paint expression keeps
// a status's own opacity under the dimming, a list opens emphasizing every
// route it names, an entry narrows it and leaving the entry widens it again,
// closing and a hold that expires empty it, and one source withdrawing its
// claim leaves another's. Run it with
// `node test/scripts/route_emphasis_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  EmphasisOwner,
  listEmphasisClosed,
  ListEvent,
  VEHICLE_DIM_FACTOR,
  claimEmphasis,
  dimmedOpacity,
  emphasizedBy,
  emphasizedRoutesOf,
  listEmphasisStep,
  markerAlpha,
  routeIn
} from "../../assets/js/route_emphasis.js"

const alphaCases = [
  {name: "no route emphasized", given: {emphasizedRouteIds: [], routeId: "1_40"}, alpha: 1},
  {name: "the emphasized route's vehicle", given: {emphasizedRouteIds: ["1_40"], routeId: "1_40"}, alpha: 1},
  {name: "one of two emphasized routes' vehicle", given: {emphasizedRouteIds: ["1_40", "1_41"], routeId: "1_41"}, alpha: 1},
  {name: "another route's vehicle", given: {emphasizedRouteIds: ["1_40"], routeId: "1_41"}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a route outside two emphasized", given: {emphasizedRouteIds: ["1_40", "1_41"], routeId: "1_42"}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a vehicle with no route", given: {emphasizedRouteIds: ["1_40"], routeId: null}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a vehicle with no route field", given: {emphasizedRouteIds: ["1_40"], routeId: undefined}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a route whose id differs only in case", given: {emphasizedRouteIds: ["1_40a"], routeId: "1_40A"}, alpha: VEHICLE_DIM_FACTOR},
  {name: "a vehicle with no route and no emphasis", given: {emphasizedRouteIds: [], routeId: null}, alpha: 1}
]

for (const {name, given, alpha} of alphaCases) {
  deepStrictEqual(markerAlpha(given), alpha, name)
}

const STALE_OPACITY = 0.6
const statusOpacity = ["match", ["get", "status"], "live", 1, "stale", STALE_OPACITY, 1]

const expressionCases = [
  {name: "a number with no emphasis", given: {emphasizedRouteIds: [], opacity: 1}, expected: 1},
  {name: "an expression with no emphasis", given: {emphasizedRouteIds: [], opacity: statusOpacity}, expected: statusOpacity},
  {
    name: "a number under emphasis",
    given: {emphasizedRouteIds: ["1_40"], opacity: 1},
    expected: ["case", routeIn(["1_40"]), 1, ["*", 1, VEHICLE_DIM_FACTOR]]
  },
  {
    name: "an expression under emphasis of two routes",
    given: {emphasizedRouteIds: ["1_40", "1_41"], opacity: statusOpacity},
    expected: ["case", routeIn(["1_40", "1_41"]), statusOpacity, ["*", statusOpacity, VEHICLE_DIM_FACTOR]]
  }
]

for (const {name, given, expected} of expressionCases) {
  deepStrictEqual(dimmedOpacity(given), expected, name)
}

deepStrictEqual(
  routeIn(["1_40", "1_41"]),
  ["in", ["to-string", ["get", "routeId"]], ["literal", ["1_40", "1_41"]]],
  "the route filter reads a feature with no route as the empty text"
)

const eventCases = [
  {name: "two routes", detail: {routeIds: ["1_40", "1_41"]}, routeIds: ["1_40", "1_41"]},
  {name: "a cleared emphasis", detail: {routeIds: []}, routeIds: []}
]

for (const {name, detail, routeIds} of eventCases) {
  deepStrictEqual(emphasizedRoutesOf(detail), routeIds, name)
}

const refusedDetails = [
  {name: "a lone route", detail: {routeIds: "1_40"}},
  {name: "null", detail: {routeIds: null}},
  {name: "an empty identifier", detail: {routeIds: [""]}}
]

for (const {name, detail} of refusedDetails) {
  throws(() => emphasizedRoutesOf(detail), name)
}

const LISTED = ["1_40", "1_41"]
const OPENED = {listed: LISTED, emphasized: LISTED}
const NARROWED = {listed: LISTED, emphasized: ["1_41"]}

const stepCases = [
  {name: "open emphasizes every listed route", state: listEmphasisClosed, event: {kind: ListEvent.open, routeIds: LISTED}, expected: OPENED},
  {name: "open on one route emphasizes it", state: listEmphasisClosed, event: {kind: ListEvent.open, routeIds: ["1_40"]}, expected: {listed: ["1_40"], emphasized: ["1_40"]}},
  {name: "an entry narrows to its route", state: OPENED, event: {kind: ListEvent.entryEnter, routeId: "1_41"}, expected: NARROWED},
  {name: "leaving the entry returns to every listed route", state: NARROWED, event: {kind: ListEvent.entryLeave}, expected: OPENED},
  {name: "close empties the emphasis", state: OPENED, event: {kind: ListEvent.close}, expected: listEmphasisClosed},
  {name: "close on a narrowed list empties the emphasis", state: NARROWED, event: {kind: ListEvent.close}, expected: listEmphasisClosed},
  {name: "an expired hold closes the list, which empties the emphasis", state: OPENED, event: {kind: ListEvent.close}, expected: listEmphasisClosed},
  {name: "leaving an entry of a closed list emphasizes none", state: listEmphasisClosed, event: {kind: ListEvent.entryLeave}, expected: listEmphasisClosed},
  {name: "close of a closed list stays closed", state: listEmphasisClosed, event: {kind: ListEvent.close}, expected: listEmphasisClosed}
]

for (const {name, state, event, expected} of stepCases) {
  deepStrictEqual(listEmphasisStep({state, event}), expected, name)
}

function stepUnknownEvent() {
  return listEmphasisStep({state: OPENED, event: {kind: "hover"}})
}

throws(stepUnknownEvent, "an unknown event is refused")

const hoverClaim = {owner: EmphasisOwner.hover, routeIds: ["1_40"]}
const keysClaim = {owner: EmphasisOwner.keys, routeIds: ["1_41", "1_42"]}

const claimCases = [
  {name: "a first claim", claims: [], owner: EmphasisOwner.hover, routeIds: ["1_40"], expected: [hoverClaim]},
  {name: "a later claim is the latest", claims: [hoverClaim], owner: EmphasisOwner.keys, routeIds: ["1_41", "1_42"], expected: [hoverClaim, keysClaim]},
  {name: "an owner's new claim replaces its own", claims: [hoverClaim, keysClaim], owner: EmphasisOwner.hover, routeIds: ["1_43"], expected: [keysClaim, {owner: EmphasisOwner.hover, routeIds: ["1_43"]}]},
  {name: "a withdrawn claim leaves the other's", claims: [keysClaim, hoverClaim], owner: EmphasisOwner.hover, routeIds: [], expected: [keysClaim]},
  {name: "a withdrawal with no claim changes nothing", claims: [keysClaim], owner: EmphasisOwner.hover, routeIds: [], expected: [keysClaim]},
  {name: "the last withdrawal leaves none", claims: [hoverClaim], owner: EmphasisOwner.hover, routeIds: [], expected: []}
]

for (const {name, claims, owner, routeIds, expected} of claimCases) {
  deepStrictEqual(claimEmphasis({claims, owner, routeIds}), expected, name)
}

deepStrictEqual(emphasizedBy([]), [], "no claim emphasizes no route")
deepStrictEqual(emphasizedBy([hoverClaim, keysClaim]), ["1_41", "1_42"], "the latest claim emphasizes")

const caseCount =
  alphaCases.length +
  expressionCases.length +
  eventCases.length +
  refusedDetails.length +
  stepCases.length +
  claimCases.length

console.log(`route emphasis: ${caseCount} cases hold`)
