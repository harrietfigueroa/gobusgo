// Checks the rules of the location button against cases written out by
// hand: each state's answer to a click, a load with the flag stored, a fix
// inside and outside the archive, a fix that fails, a denial, a camera move,
// and an opened details view; what the button says and shows in each state;
// which camera moves end following; when a fix moves the map; where the map
// keeps the dot beside the sheet; the zoom of the first fix; and the size of
// the accuracy circle. It also reads the button's two source files and fails
// on any call that could carry a position out of the browser. Run it with
// `node test/scripts/follow_location_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {
  ButtonClass,
  CenterZoom,
  EffectKind,
  FOLLOW_DISTANCE_PIXELS_MAX,
  FOLLOW_EASE_MS,
  FOLLOW_ZOOM_MAX,
  FixPlace,
  FollowEventKind,
  FollowKind,
  NoticeText,
  OFF,
  accuracyDiameterPixels,
  buttonOf,
  endsFollowing,
  firstZoom,
  followMove,
  isActive,
  isInside,
  keepOffset,
  moveDurationMs,
  transition
} from "../../assets/js/follow_state.js"

const THRESHOLD_PIXELS = 24
const ZOOM_MAX = 15
const EASE_MS = 500
const SEATTLE_LATITUDE = 47.6062

deepStrictEqual(FOLLOW_DISTANCE_PIXELS_MAX, THRESHOLD_PIXELS, "the distance a fix may stand from the keep point")
deepStrictEqual(FOLLOW_ZOOM_MAX, ZOOM_MAX, "the zoom of the first fix at most")

function state(fields) {
  return {...OFF, ...fields}
}

const waiting = state({kind: FollowKind.following, isNoticeOwed: true})
const restored = state({kind: FollowKind.following})
const following = state({kind: FollowKind.following, isCentered: true, place: FixPlace.inside})
const followingStale = state({kind: FollowKind.following, isCentered: true, place: FixPlace.inside, isStale: true})
const located = state({kind: FollowKind.located, place: FixPlace.inside})
const locatedOutside = state({kind: FollowKind.located, place: FixPlace.outside})
const locatedNoFix = state({kind: FollowKind.located})
const blocked = state({kind: FollowKind.blocked})

const click = {kind: FollowEventKind.click}
const restore = {kind: FollowEventKind.restore}
const fixInside = {kind: FollowEventKind.fix, place: FixPlace.inside}
const fixOutside = {kind: FollowEventKind.fix, place: FixPlace.outside}
const failed = {kind: FollowEventKind.failed}
const denied = {kind: FollowEventKind.denied}
const cameraMove = {kind: FollowEventKind.cameraMove}
const detailOpen = {kind: FollowEventKind.detailOpen}

function notice(text) {
  return {kind: EffectKind.notice, text}
}

const centerFirst = {kind: EffectKind.center, zoom: CenterZoom.first}
const centerKept = {kind: EffectKind.center, zoom: CenterZoom.kept}
const follow = {kind: EffectKind.follow}

const transitionCases = [
  {name: "a click in Off follows and owes a notice", from: OFF, event: click, to: waiting, effects: [notice(NoticeText.following)]},
  {name: "a click in Following turns the button off", from: following, event: click, to: OFF, effects: [notice(NoticeText.stopped)]},
  {name: "a click in Following before the first fix turns the button off", from: waiting, event: click, to: OFF, effects: [notice(NoticeText.stopped)]},
  {
    name: "a click in Located centers again and follows",
    from: located,
    event: click,
    to: state({kind: FollowKind.following, isCentered: true, place: FixPlace.inside, isNoticeOwed: true}),
    effects: [centerKept, notice(NoticeText.following)]
  },
  {name: "a click in Located outside the archive explains and stays", from: locatedOutside, event: click, to: locatedOutside, effects: [notice(NoticeText.outside)]},
  {
    name: "a click in Located with no fix follows and waits",
    from: locatedNoFix,
    event: click,
    to: state({kind: FollowKind.following, isNoticeOwed: true}),
    effects: [notice(NoticeText.following)]
  },
  {name: "a click on a blocked button does nothing", from: blocked, event: click, to: blocked, effects: []},
  {name: "a load with the flag stored follows with no notice owed", from: OFF, event: restore, to: restored, effects: []},
  {name: "a load in a state other than Off changes nothing", from: following, event: restore, to: following, effects: []},
  {
    name: "the first fix inside the archive centers at the first zoom",
    from: waiting,
    event: fixInside,
    to: following,
    effects: [centerFirst]
  },
  {
    name: "the first fix outside the archive explains after a click and stops following",
    from: waiting,
    event: fixOutside,
    to: locatedOutside,
    effects: [notice(NoticeText.outside)]
  },
  {
    name: "the first fix outside the archive on load says only that following stopped",
    from: restored,
    event: fixOutside,
    to: locatedOutside,
    effects: [notice(NoticeText.stopped)]
  },
  {name: "a later fix inside asks for a follow move", from: following, event: fixInside, to: following, effects: [follow]},
  {name: "a fix after a failure draws the dot fresh", from: followingStale, event: fixInside, to: following, effects: [follow]},
  {name: "a later fix outside stops following", from: following, event: fixOutside, to: locatedOutside, effects: [notice(NoticeText.stopped)]},
  {name: "a fix in Located moves only the dot", from: located, event: fixInside, to: located, effects: []},
  {name: "a fix outside in Located stays Located", from: located, event: fixOutside, to: locatedOutside, effects: []},
  {name: "a fix in Off is a stray and changes nothing", from: OFF, event: fixInside, to: OFF, effects: []},
  {
    name: "a failure after a click keeps following, fades the dot, and explains",
    from: waiting,
    event: failed,
    to: state({kind: FollowKind.following, isStale: true}),
    effects: [notice(NoticeText.unavailable)]
  },
  {name: "a failure with no notice owed keeps following silently", from: following, event: failed, to: followingStale, effects: []},
  {name: "a failure in Located keeps Located", from: located, event: failed, to: state({kind: FollowKind.located, place: FixPlace.inside, isStale: true}), effects: []},
  {name: "a failure in Off changes nothing", from: OFF, event: failed, to: OFF, effects: []},
  {name: "a denial after a click blocks the button and explains", from: waiting, event: denied, to: blocked, effects: [notice(NoticeText.denied)]},
  {name: "a denial on load blocks the button silently", from: restored, event: denied, to: blocked, effects: []},
  {name: "a permission read as denied blocks the button in Off", from: OFF, event: denied, to: blocked, effects: []},
  {name: "a camera move in Following moves to Located", from: following, event: cameraMove, to: located, effects: [notice(NoticeText.stopped)]},
  {name: "a camera move before the first fix keeps following", from: waiting, event: cameraMove, to: waiting, effects: []},
  {name: "a camera move in Located changes nothing", from: located, event: cameraMove, to: located, effects: []},
  {name: "an opened details view in Following moves to Located", from: following, event: detailOpen, to: located, effects: [notice(NoticeText.stopped)]},
  {name: "an opened details view in Off changes nothing", from: OFF, event: detailOpen, to: OFF, effects: []}
]

for (const {name, from, event, to, effects} of transitionCases) {
  deepStrictEqual(transition({state: from, event}), {state: to, effects}, name)
}

const activeCases = [
  {state: OFF, active: false},
  {state: waiting, active: true},
  {state: following, active: true},
  {state: located, active: true},
  {state: blocked, active: false}
]

for (const {state: given, active} of activeCases) {
  deepStrictEqual(isActive(given), active, `whether ${given.kind} holds the watch`)
}

const buttonCases = [
  {name: "Off", state: OFF, button: {label: "Follow my location", pressed: false, disabled: false, className: ButtonClass.none}},
  {name: "Following before the first fix", state: waiting, button: {label: "Stop following my location", pressed: true, disabled: false, className: ButtonClass.waiting}},
  {name: "Following", state: following, button: {label: "Stop following my location", pressed: true, disabled: false, className: ButtonClass.active}},
  {name: "Following after a failure", state: followingStale, button: {label: "Stop following my location", pressed: true, disabled: false, className: ButtonClass.activeError}},
  {name: "Located", state: located, button: {label: "Center on my location", pressed: false, disabled: false, className: ButtonClass.background}},
  {
    name: "Located after a failure",
    state: state({kind: FollowKind.located, isStale: true}),
    button: {label: "Center on my location", pressed: false, disabled: false, className: ButtonClass.backgroundError}
  },
  {name: "blocked", state: blocked, button: {label: "Follow my location", pressed: false, disabled: true, className: ButtonClass.none}}
]

for (const {name, state: given, button} of buttonCases) {
  deepStrictEqual(buttonOf(given), button, `the button in ${name}`)
}

const endCases = [
  {name: "a pan by the rider", move: {isOwnMove: false, isResize: false, isZooming: false, isFit: false}, ends: true},
  {name: "a zoom by the rider", move: {isOwnMove: false, isResize: false, isZooming: true, isFit: false}, ends: false},
  {name: "the button's own move", move: {isOwnMove: true, isResize: false, isZooming: false, isFit: false}, ends: false},
  {name: "the button's own move that zooms", move: {isOwnMove: true, isResize: false, isZooming: true, isFit: false}, ends: false},
  {name: "a resize of the map", move: {isOwnMove: false, isResize: true, isZooming: false, isFit: false}, ends: false},
  {name: "a reveal of the details view's item", move: {isOwnMove: false, isResize: false, isZooming: false, isFit: false}, ends: true},
  {name: "a fit that zooms, such as a filter's or a journey's", move: {isOwnMove: false, isResize: false, isZooming: true, isFit: true}, ends: true},
  {name: "a fit that only pans", move: {isOwnMove: false, isResize: false, isZooming: false, isFit: true}, ends: true}
]

for (const {name, move, ends} of endCases) {
  deepStrictEqual(endsFollowing(move), ends, name)
}

// A phone of 390 by 844 px under a sheet 300 px high keeps the dot at
// (195, 272), 150 px above the map's middle; a desktop of 1280 by 800 px
// beside a panel 400 px wide keeps it at (840, 400), 200 px right of it.
const PHONE_WIDTH_PIXELS = 390
const PHONE_HEIGHT_PIXELS = 844
const PHONE_SHEET_HEIGHT_PIXELS = 300
const PHONE_KEEP_X_PIXELS = 195
const PHONE_KEEP_Y_PIXELS = 272
const PHONE_KEEP_OFFSET_Y_PIXELS = -150
const DESKTOP_WIDTH_PIXELS = 1280
const DESKTOP_HEIGHT_PIXELS = 800
const DESKTOP_PANEL_WIDTH_PIXELS = 400
const DESKTOP_KEEP_X_PIXELS = 840
const DESKTOP_KEEP_Y_PIXELS = 400
const DESKTOP_KEEP_OFFSET_X_PIXELS = 200
// Each step of a diagonal past the threshold, 20 px, puts the dot 28 px
// away; each step inside it, 16 px, puts it 23 px away.
const DIAGONAL_STEP_PAST_PIXELS = 20
const DIAGONAL_STEP_INSIDE_PIXELS = 16

const phone = {viewWidth: PHONE_WIDTH_PIXELS, viewHeight: PHONE_HEIGHT_PIXELS, insets: {left: 0, bottom: PHONE_SHEET_HEIGHT_PIXELS}}
const desktop = {viewWidth: DESKTOP_WIDTH_PIXELS, viewHeight: DESKTOP_HEIGHT_PIXELS, insets: {left: DESKTOP_PANEL_WIDTH_PIXELS, bottom: 0}}
const phoneOffset = [0, PHONE_KEEP_OFFSET_Y_PIXELS]
const desktopOffset = [DESKTOP_KEEP_OFFSET_X_PIXELS, 0]

deepStrictEqual(keepOffset(phone), phoneOffset, "the keep point above a bottom sheet")
deepStrictEqual(keepOffset(desktop), desktopOffset, "the keep point beside a side panel")

const moveCases = [
  {name: "a dot on the keep point", view: phone, dotPoint: {x: PHONE_KEEP_X_PIXELS, y: PHONE_KEEP_Y_PIXELS}, move: {kind: "stay"}},
  {name: "a dot at the threshold", view: phone, dotPoint: {x: PHONE_KEEP_X_PIXELS + THRESHOLD_PIXELS, y: PHONE_KEEP_Y_PIXELS}, move: {kind: "stay"}},
  {
    name: "a dot past the threshold",
    view: phone,
    dotPoint: {x: PHONE_KEEP_X_PIXELS + THRESHOLD_PIXELS + 1, y: PHONE_KEEP_Y_PIXELS},
    move: {kind: "move", offset: phoneOffset}
  },
  {
    name: "a dot past the threshold on a diagonal",
    view: desktop,
    dotPoint: {x: DESKTOP_KEEP_X_PIXELS + DIAGONAL_STEP_PAST_PIXELS, y: DESKTOP_KEEP_Y_PIXELS + DIAGONAL_STEP_PAST_PIXELS},
    move: {kind: "move", offset: desktopOffset}
  },
  {
    name: "a dot inside the threshold on a diagonal",
    view: desktop,
    dotPoint: {x: DESKTOP_KEEP_X_PIXELS + DIAGONAL_STEP_INSIDE_PIXELS, y: DESKTOP_KEEP_Y_PIXELS + DIAGONAL_STEP_INSIDE_PIXELS},
    move: {kind: "stay"}
  }
]

for (const {name, view, dotPoint, move} of moveCases) {
  deepStrictEqual(followMove({...view, dotPoint}), move, name)
}

const bounds = {south: 46.8, west: -123.5, north: 48.4, east: -121.5}
deepStrictEqual(isInside({bounds, latitude: SEATTLE_LATITUDE, longitude: -122.3321}), true, "Seattle inside the archive")
deepStrictEqual(isInside({bounds, latitude: 40.7128, longitude: -74.006}), false, "New York outside the archive")
deepStrictEqual(isInside({bounds, latitude: 48.4, longitude: -121.5}), true, "a corner of the archive")

deepStrictEqual(firstZoom({latitude: SEATTLE_LATITUDE, accuracyM: 10, sidePixels: PHONE_WIDTH_PIXELS}), ZOOM_MAX, "a precise fix is capped at the first zoom")
deepStrictEqual(firstZoom({latitude: SEATTLE_LATITUDE, accuracyM: 0, sidePixels: PHONE_WIDTH_PIXELS}), ZOOM_MAX, "a fix of no accuracy radius is capped at the first zoom")
// A circle 4 km across fits 390 px at about 10.3 m per pixel, which in
// Seattle is zoom 12.3.
const COARSE_ACCURACY_M = 2000
const COARSE_ZOOM_MIN = 12.3
const COARSE_ZOOM_MAX = 12.4
const coarseZoom = firstZoom({latitude: SEATTLE_LATITUDE, accuracyM: COARSE_ACCURACY_M, sidePixels: PHONE_WIDTH_PIXELS})
const isCoarseZoomAbove = coarseZoom > COARSE_ZOOM_MIN
const isCoarseZoomBelow = coarseZoom < COARSE_ZOOM_MAX
ok(isCoarseZoomAbove, `a coarse fix zooms out to show its circle, to ${coarseZoom}`)
ok(isCoarseZoomBelow, `a coarse fix zooms out to show its circle, to ${coarseZoom}`)

// A radius of a quarter of the equator is a circle half the world across,
// and the world at zoom 0 is 512 px.
const EQUATOR_M = 40_075_016.686
const QUARTERS_PER_TURN = 4
const quarterEquatorM = EQUATOR_M / QUARTERS_PER_TURN
const HALF_WORLD_PIXELS = 256
const diameter = accuracyDiameterPixels({latitude: 0, zoom: 0, accuracyM: quarterEquatorM})
deepStrictEqual(diameter, HALF_WORLD_PIXELS, "the circle of a quarter of the equator at zoom 0 is half the world")

deepStrictEqual(moveDurationMs({reducedMotion: false}), FOLLOW_EASE_MS, "a follow move eases")
deepStrictEqual(FOLLOW_EASE_MS, EASE_MS, "the length of a follow move")
deepStrictEqual(moveDurationMs({reducedMotion: true}), 0, "a follow move jumps under reduced motion")

// A position read by any of these would leave the browser or outlive the
// page: an event to the server, a request, storage reached directly, or a
// log line. The hook stores through the stored settings alone, and writes
// only whether the button is on.
const leakPatterns = [/pushEvent/, /\bfetch\(/, /localStorage/, /sessionStorage/, /indexedDB/, /sendBeacon/, /XMLHttpRequest/, /WebSocket/, /\bconsole\.(log|info|debug)/]
const sourcePaths = ["assets/js/follow_location.js", "assets/js/follow_state.js"]
const STORED_WRITE_PATTERN = /storedSettings\.write\w*\([^)]*\)/g

for (const path of sourcePaths) {
  const text = readFileSync(new URL(`../../${path}`, import.meta.url), "utf8")

  for (const pattern of leakPatterns) {
    ok(!pattern.test(text), `${path} holds ${pattern}, which could carry a position out of the browser`)
  }

  const writes = Array.from(text.matchAll(STORED_WRITE_PATTERN), firstMatch)

  for (const write of writes) {
    ok(write === "storedSettings.writeLocationFollow(isOn)", `${path} stores ${write}, where only the flag is stored`)
  }
}

function firstMatch(match) {
  return match[0]
}

console.log("follow location check passed")
