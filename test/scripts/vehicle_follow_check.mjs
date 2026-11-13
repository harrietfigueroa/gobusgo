// Checks the rules of following a bus against cases written out by hand:
// each state's answer to a start, the stop button, a camera move, the
// location follow starting, the markers held with and without the followed
// vehicle, and the saved schedule's markers replacing the live ones; what the
// stop button says; the zoom a follow starts at; which arrivals can be
// followed and how their buttons are named; and which marker an arrival's
// vehicle is. Run it with `node test/scripts/vehicle_follow_check.mjs`; it
// exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  ArrivalFollowKind,
  EffectKind,
  MarkerLookupKind,
  NoticeMessage,
  OFF,
  VEHICLE_FOLLOW_ZOOM_MIN,
  VehicleFollowEventKind,
  VehicleFollowKind,
  arrivalFollow,
  arrivalFollowLabel,
  isFollowing,
  isMarkerHeld,
  labelOf,
  markerForVehicle,
  startZoom,
  stopButtonOf,
  transition
} from "../../assets/js/vehicle_follow.js"
import {AssertionError} from "../../assets/js/core/assert.js"

const ZOOM_MIN = 14
const MARKER_ID = "1/1_4342"
const LABEL = "the 36 bus"

deepStrictEqual(VEHICLE_FOLLOW_ZOOM_MIN, ZOOM_MIN, "the zoom a follow starts at, at least")

const following = {kind: VehicleFollowKind.following, markerId: MARKER_ID, label: LABEL}
const start = {kind: VehicleFollowEventKind.start, markerId: MARKER_ID, label: LABEL}

function notice(message) {
  return {kind: EffectKind.notice, message}
}

const centerEffect = {kind: EffectKind.center}
const focusEffect = {kind: EffectKind.focusMap}

const transitions = [
  {name: "a start from off follows the marker, centers on it, and says so", state: OFF, event: start, expected: {state: following, effects: [centerEffect, notice(NoticeMessage.following(LABEL))]}},
  {name: "a start on the marker already followed changes nothing", state: following, event: start, expected: {state: following, effects: []}},
  {
    name: "a start on another marker moves the follow to it",
    state: following,
    event: {kind: VehicleFollowEventKind.start, markerId: "1/1_9", label: "the E bus"},
    expected: {state: {kind: VehicleFollowKind.following, markerId: "1/1_9", label: "the E bus"}, effects: [centerEffect, notice(NoticeMessage.following("the E bus"))]}
  },
  {name: "the stop button ends the follow, says so, and gives the map the focus", state: following, event: {kind: VehicleFollowEventKind.stop}, expected: {state: OFF, effects: [notice(NoticeMessage.stopped(LABEL)), focusEffect]}},
  {name: "the stop button while off changes nothing", state: OFF, event: {kind: VehicleFollowEventKind.stop}, expected: {state: OFF, effects: []}},
  {name: "a camera move the follow did not make ends it and leaves the focus where it is", state: following, event: {kind: VehicleFollowEventKind.cameraMove}, expected: {state: OFF, effects: [notice(NoticeMessage.stopped(LABEL))]}},
  {name: "a camera move while off changes nothing", state: OFF, event: {kind: VehicleFollowEventKind.cameraMove}, expected: {state: OFF, effects: []}},
  {name: "the location follow starting ends the follow with no notice", state: following, event: {kind: VehicleFollowEventKind.locationFollow}, expected: {state: OFF, effects: []}},
  {name: "the location follow starting while off changes nothing", state: OFF, event: {kind: VehicleFollowEventKind.locationFollow}, expected: {state: OFF, effects: []}},
  {name: "markers that hold the vehicle leave the follow as it is", state: following, event: {kind: VehicleFollowEventKind.markersHeld, isHeld: true}, expected: {state: following, effects: []}},
  {name: "markers that lack the vehicle end the follow and say it left the map", state: following, event: {kind: VehicleFollowEventKind.markersHeld, isHeld: false}, expected: {state: OFF, effects: [notice(NoticeMessage.gone(LABEL))]}},
  {name: "markers that lack a vehicle while off change nothing", state: OFF, event: {kind: VehicleFollowEventKind.markersHeld, isHeld: false}, expected: {state: OFF, effects: []}},
  {name: "the saved schedule's markers end the follow and say the page is offline", state: following, event: {kind: VehicleFollowEventKind.scheduleShown}, expected: {state: OFF, effects: [notice(NoticeMessage.offline(LABEL))]}},
  {name: "the saved schedule's markers while off change nothing", state: OFF, event: {kind: VehicleFollowEventKind.scheduleShown}, expected: {state: OFF, effects: []}}
]

for (const {name, state, event, expected} of transitions) {
  deepStrictEqual(transition({state, event}), expected, name)
}

throws(() => transition({state: OFF, event: {kind: "unknown"}}), AssertionError, "an event of unknown kind is refused")
throws(() => transition({state: {...OFF, kind: "unknown"}, event: start}), AssertionError, "a state of unknown kind is refused")
throws(() => transition({state: OFF, event: {kind: VehicleFollowEventKind.start, markerId: "", label: LABEL}}), AssertionError, "a start that names no marker is refused")

deepStrictEqual(isFollowing(OFF), false, "off follows nothing")
deepStrictEqual(isFollowing(following), true, "a follow follows")

// Each notice is a headline that states the state and a caption with the
// next step, which the live region reads as two sentences.
deepStrictEqual(NoticeMessage.following(LABEL), {headline: "Following the 36 bus", caption: "Move the map or press Stop following to stop."}, "the following notice")
deepStrictEqual(NoticeMessage.stopped(LABEL), {headline: "Stopped following the 36 bus", caption: "Tap a bus to follow it again."}, "the stopped notice")
deepStrictEqual(NoticeMessage.gone(LABEL), {headline: "Stopped following the 36 bus", caption: "It is no longer on the map."}, "the gone notice")
deepStrictEqual(NoticeMessage.offline(LABEL), {headline: "Stopped following the 36 bus", caption: "You're offline, so the buses are not live."}, "the offline notice")
deepStrictEqual(NoticeMessage.unavailable(), {headline: "Can't follow that bus", caption: "It is not on the map right now."}, "the unavailable notice")

deepStrictEqual(labelOf({route: "36"}), "the 36 bus", "a vehicle on a route is named by it")
deepStrictEqual(labelOf({route: null}), "the bus", "a vehicle with no route is the bus")
deepStrictEqual(labelOf({route: ""}), "the bus", "a vehicle with an empty route is the bus")
deepStrictEqual(labelOf({route: undefined}), "the bus", "a vehicle with no route field is the bus")

deepStrictEqual(stopButtonOf(following), {label: "Stop following the 36 bus", isHidden: false}, "the stop button while following")
deepStrictEqual(stopButtonOf(OFF), {label: "Stop following the bus", isHidden: true}, "the stop button while off is hidden")

deepStrictEqual(startZoom(10), ZOOM_MIN, "a map farther out zooms in")
deepStrictEqual(startZoom(ZOOM_MIN), ZOOM_MIN, "a map at the zoom stays")
deepStrictEqual(startZoom(16.5), 16.5, "a map closer in keeps its zoom")

const livePrediction = {route: "36", headsign: "Othello Station", predicted: true, vehicle_id: "1_4342"}
const arrivalCases = [
  {name: "a live arrival with a vehicle", arrival: livePrediction, expected: {kind: ArrivalFollowKind.followable, vehicleId: "1_4342"}},
  {name: "a scheduled arrival, whatever vehicle it names", arrival: {...livePrediction, predicted: false}, expected: {kind: ArrivalFollowKind.unfollowable}},
  {name: "a live arrival with a null vehicle", arrival: {...livePrediction, vehicle_id: null}, expected: {kind: ArrivalFollowKind.unfollowable}},
  {name: "a live arrival with an empty vehicle", arrival: {...livePrediction, vehicle_id: ""}, expected: {kind: ArrivalFollowKind.unfollowable}},
  {name: "an arrival of the saved schedules, which names no vehicle", arrival: {route: "36", headsign: "Othello Station", predicted: false}, expected: {kind: ArrivalFollowKind.unfollowable}}
]

for (const {name, arrival, expected} of arrivalCases) {
  deepStrictEqual(arrivalFollow(arrival), expected, name)
}

const labelCases = [
  {route: "36", headsign: "Othello Station", expected: "Follow the 36 bus to Othello Station"},
  {route: "36", headsign: null, expected: "Follow the 36 bus"},
  {route: null, headsign: "Othello Station", expected: "Follow the bus to Othello Station"},
  {route: null, headsign: null, expected: "Follow this bus"}
]

for (const {route, headsign, expected} of labelCases) {
  deepStrictEqual(arrivalFollowLabel({route, headsign}), expected, `the button of ${String(route)} to ${String(headsign)}`)
}

const markerLists = [[{id: "1/1_1", vehicle_id: "1_1"}], [{id: "1/1_4342", vehicle_id: "1_4342"}]]

deepStrictEqual(markerForVehicle({markerLists, vehicleId: "1_4342"}), {kind: MarkerLookupKind.found, marker: {id: "1/1_4342", vehicle_id: "1_4342"}}, "a vehicle held by the second agency")
deepStrictEqual(markerForVehicle({markerLists, vehicleId: "1_9"}), {kind: MarkerLookupKind.missing}, "a vehicle no agency holds")
deepStrictEqual(markerForVehicle({markerLists: [], vehicleId: "1_4342"}), {kind: MarkerLookupKind.missing}, "a vehicle among no markers")
deepStrictEqual(isMarkerHeld({markerLists, markerId: "1/1_4342"}), true, "a marker held")
deepStrictEqual(isMarkerHeld({markerLists, markerId: "1/1_9"}), false, "a marker not held")

console.log("vehicle follow check passed")
