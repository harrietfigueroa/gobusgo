// Checks the rules of following a bus against cases written out by hand:
// each state's answer to a start, the stop button, a camera move, the
// location follow starting, the markers held with and without the followed
// vehicle and the grace before a missing vehicle ends the follow, and the
// saved schedule's markers replacing the live ones; what the stop button
// says; the zoom a follow starts at; what each frame of the follow does; which
// arrivals can be followed and how their buttons are named; and which marker
// an arrival's vehicle is. Run it with `node test/scripts/vehicle_follow_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  ABSENCE_MS_MAX,
  ArrivalFollowKind,
  OFF,
  PlacementKind,
  StepKind,
  VEHICLE_FOLLOW_ZOOM_MIN,
  VehicleEffectKind,
  VehicleFollowEventKind,
  VehicleFollowKind,
  VehicleLookupKind,
  VehicleNotice,
  arrivalFollow,
  arrivalFollowLabel,
  followStep,
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
const ZOOM_FAR = 10
const ZOOM_CLOSE = 16.5
const ABSENCE_MS = 30_000
const MARKER_ID = "1/1_4342"
const LABEL = "the 36 bus"
const CLOCK_MS = 100_000
const SOON_MS = 1_000

deepStrictEqual(VEHICLE_FOLLOW_ZOOM_MIN, ZOOM_MIN, "the zoom a follow starts at, at least")
deepStrictEqual(ABSENCE_MS_MAX, ABSENCE_MS, "how long a vehicle may be missing")

const following = {kind: VehicleFollowKind.following, markerId: MARKER_ID, label: LABEL, absentSinceMs: null}
const absent = {...following, absentSinceMs: CLOCK_MS}
const start = {kind: VehicleFollowEventKind.start, markerId: MARKER_ID, label: LABEL}

function notice(message) {
  return {kind: VehicleEffectKind.notice, message}
}

function held({isHeld, nowMs}) {
  return {kind: VehicleFollowEventKind.markersHeld, isHeld, nowMs}
}

const centerEffect = {kind: VehicleEffectKind.center}
const focusEffect = {kind: VehicleEffectKind.focusMap}

const transitions = [
  {name: "a start from off follows the marker, centers on it, and says so", state: OFF, event: start, expected: {state: following, effects: [centerEffect, notice(VehicleNotice.following(LABEL))]}},
  {name: "a start on the marker already followed changes nothing", state: following, event: start, expected: {state: following, effects: []}},
  {
    name: "a start on another marker moves the follow to it",
    state: following,
    event: {kind: VehicleFollowEventKind.start, markerId: "1/1_9", label: "the E bus"},
    expected: {state: {kind: VehicleFollowKind.following, markerId: "1/1_9", label: "the E bus", absentSinceMs: null}, effects: [centerEffect, notice(VehicleNotice.following("the E bus"))]}
  },
  {name: "the stop button ends the follow, says so, and gives the map the focus", state: following, event: {kind: VehicleFollowEventKind.stop}, expected: {state: OFF, effects: [notice(VehicleNotice.stopped(LABEL)), focusEffect]}},
  {name: "the stop button while off changes nothing", state: OFF, event: {kind: VehicleFollowEventKind.stop}, expected: {state: OFF, effects: []}},
  {name: "a camera move the follow did not make ends it and leaves the focus where it is", state: following, event: {kind: VehicleFollowEventKind.cameraMove}, expected: {state: OFF, effects: [notice(VehicleNotice.stopped(LABEL))]}},
  {name: "a camera move while off changes nothing", state: OFF, event: {kind: VehicleFollowEventKind.cameraMove}, expected: {state: OFF, effects: []}},
  {name: "the location follow starting ends the follow with no notice", state: following, event: {kind: VehicleFollowEventKind.locationFollow}, expected: {state: OFF, effects: []}},
  {name: "the location follow starting while off changes nothing", state: OFF, event: {kind: VehicleFollowEventKind.locationFollow}, expected: {state: OFF, effects: []}},
  {name: "markers that hold the vehicle leave the follow as it is", state: following, event: held({isHeld: true, nowMs: CLOCK_MS}), expected: {state: following, effects: []}},
  {name: "the first update that lacks the vehicle records when and keeps following", state: following, event: held({isHeld: false, nowMs: CLOCK_MS}), expected: {state: absent, effects: []}},
  {name: "an update that lacks the vehicle within the grace keeps following", state: absent, event: held({isHeld: false, nowMs: CLOCK_MS + SOON_MS}), expected: {state: absent, effects: []}},
  {name: "an update that lacks the vehicle one millisecond short of the grace keeps following", state: absent, event: held({isHeld: false, nowMs: CLOCK_MS + ABSENCE_MS - 1}), expected: {state: absent, effects: []}},
  {name: "an update that lacks the vehicle at the grace's end ends the follow and says it left the map", state: absent, event: held({isHeld: false, nowMs: CLOCK_MS + ABSENCE_MS}), expected: {state: OFF, effects: [notice(VehicleNotice.gone(LABEL))]}},
  {name: "an update that holds the vehicle again clears the absence", state: absent, event: held({isHeld: true, nowMs: CLOCK_MS + SOON_MS}), expected: {state: following, effects: []}},
  {name: "markers that lack a vehicle while off change nothing", state: OFF, event: held({isHeld: false, nowMs: CLOCK_MS}), expected: {state: OFF, effects: []}},
  {name: "the saved schedule's markers end the follow and say the page is offline", state: following, event: {kind: VehicleFollowEventKind.scheduleShown}, expected: {state: OFF, effects: [notice(VehicleNotice.offline(LABEL))]}},
  {name: "the saved schedule's markers end a follow whose vehicle is missing", state: absent, event: {kind: VehicleFollowEventKind.scheduleShown}, expected: {state: OFF, effects: [notice(VehicleNotice.offline(LABEL))]}},
  {name: "the saved schedule's markers while off change nothing", state: OFF, event: {kind: VehicleFollowEventKind.scheduleShown}, expected: {state: OFF, effects: []}}
]

for (const {name, state, event, expected} of transitions) {
  deepStrictEqual(transition({state, event}), expected, name)
}

function transitionOfUnknownEvent() {
  return transition({state: OFF, event: {kind: "unknown"}})
}

function transitionOfUnknownState() {
  return transition({state: {...OFF, kind: "unknown"}, event: start})
}

function transitionOfStartWithNoMarker() {
  return transition({state: OFF, event: {kind: VehicleFollowEventKind.start, markerId: "", label: LABEL}})
}

function transitionOfLookWithNoClock() {
  return transition({state: following, event: held({isHeld: false, nowMs: Number.NaN})})
}

throws(transitionOfUnknownEvent, AssertionError, "an event of unknown kind is refused")
throws(transitionOfUnknownState, AssertionError, "a state of unknown kind is refused")
throws(transitionOfStartWithNoMarker, AssertionError, "a start that names no marker is refused")
throws(transitionOfLookWithNoClock, AssertionError, "a look at the markers with no clock is refused")

deepStrictEqual(isFollowing(OFF), false, "off follows nothing")
deepStrictEqual(isFollowing(following), true, "a follow follows")

// Each notice is a headline that states the state and a caption with the
// next step, which the live region reads as two sentences.
deepStrictEqual(VehicleNotice.following(LABEL), {headline: "Following the 36 bus", caption: "Move the map or press Stop following to stop."}, "the following notice")
deepStrictEqual(VehicleNotice.stopped(LABEL), {headline: "Stopped following the 36 bus", caption: "Tap a bus to follow it again."}, "the stopped notice")
deepStrictEqual(VehicleNotice.gone(LABEL), {headline: "Stopped following the 36 bus", caption: "It is no longer on the map."}, "the gone notice")
deepStrictEqual(VehicleNotice.offline(LABEL), {headline: "Stopped following the 36 bus", caption: "You're offline, so the buses are not live."}, "the offline notice")
deepStrictEqual(VehicleNotice.unavailable(), {headline: "Can't follow that bus", caption: "It is not on the map right now."}, "the unavailable notice")

deepStrictEqual(labelOf({route: "36"}), "the 36 bus", "a vehicle on a route is named by it")
deepStrictEqual(labelOf({route: null}), "the bus", "a vehicle with no route is the bus")
deepStrictEqual(labelOf({route: ""}), "the bus", "a vehicle with an empty route is the bus")
deepStrictEqual(labelOf({route: undefined}), "the bus", "a vehicle with no route field is the bus")

deepStrictEqual(stopButtonOf(following), {label: "Stop following the 36 bus", isHidden: false}, "the stop button while following")
deepStrictEqual(stopButtonOf(OFF), {label: "Stop following the bus", isHidden: true}, "the stop button while off is hidden")

function startZoomOfNaN() {
  return startZoom(Number.NaN)
}

deepStrictEqual(startZoom(ZOOM_FAR), ZOOM_MIN, "a map farther out zooms in")
deepStrictEqual(startZoom(ZOOM_MIN), ZOOM_MIN, "a map at the zoom stays")
deepStrictEqual(startZoom(ZOOM_CLOSE), ZOOM_CLOSE, "a map closer in keeps its zoom")
throws(startZoomOfNaN, AssertionError, "a map with no zoom is refused")

const VIEW = {viewWidth: 1_000, viewHeight: 800, insets: {left: 0, bottom: 0}}
const CENTER_POINT = {x: 500, y: 400}
const NEAR_POINT = {x: 510, y: 410}
const FAR_POINT = {x: 800, y: 400}

const UNPLACED = {kind: PlacementKind.unplaced}

function placed(dotPoint) {
  return {kind: PlacementKind.placed, dotPoint}
}

const stepCases = [
  {name: "a frame while the camera moves waits, however far the marker stands", isMoving: true, placement: placed(FAR_POINT), expected: {kind: StepKind.wait}},
  {name: "a frame with the marker unplaced waits", isMoving: false, placement: UNPLACED, expected: {kind: StepKind.wait}},
  {name: "a frame with the marker unplaced and the camera moving waits", isMoving: true, placement: UNPLACED, expected: {kind: StepKind.wait}},
  {name: "a marker at the keep point stays", isMoving: false, placement: placed(CENTER_POINT), expected: {kind: StepKind.stay}},
  {name: "a marker within the threshold stays", isMoving: false, placement: placed(NEAR_POINT), expected: {kind: StepKind.stay}},
  {name: "a marker past the threshold moves the map by the keep offset", isMoving: false, placement: placed(FAR_POINT), expected: {kind: StepKind.move, offset: [0, 0]}}
]

for (const {name, isMoving, placement, expected} of stepCases) {
  deepStrictEqual(followStep({isMoving, placement, ...VIEW}), expected, name)
}

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

deepStrictEqual(markerForVehicle({markerLists, vehicleId: "1_4342"}), {kind: VehicleLookupKind.found, marker: {id: "1/1_4342", vehicle_id: "1_4342"}}, "a vehicle held by the second agency")
deepStrictEqual(markerForVehicle({markerLists, vehicleId: "1_9"}), {kind: VehicleLookupKind.missing}, "a vehicle no agency holds")
deepStrictEqual(markerForVehicle({markerLists: [], vehicleId: "1_4342"}), {kind: VehicleLookupKind.missing}, "a vehicle among no markers")
deepStrictEqual(isMarkerHeld({markerLists, markerId: "1/1_4342"}), true, "a marker held")
deepStrictEqual(isMarkerHeld({markerLists, markerId: "1/1_9"}), false, "a marker not held")

console.log("vehicle follow check passed")
