// Checks what a page load does with the rider's location against cases
// written out by hand: the launch decision of the location button and of the
// trip panel from the rider's stated intent, the permission as the
// Permissions API reports it at load, and whether the page already offered
// the restore; the trip panel's intent from its recent trips; the resume
// state a restore falls back to when the browser answers nothing in time;
// and whether each state keeps the stored flag. WebKit reports `prompt` at
// load for a permission the rider granted or denied at a prompt, and reveals
// the state only once the page has called the Geolocation API, so a stated
// intent with `prompt` restores.
// https://github.com/WebKit/WebKit/commit/386b21db7bdc2fc5135138027639ef8bf8a0402b — checked 2026-11-20
// Run it with `node test/scripts/follow_launch_check.mjs`; it exits non-zero
// on the first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {
  ButtonClass,
  FixPlace,
  FollowEventKind,
  FollowKind,
  LAUNCH_WAIT_MS_MAX,
  LaunchIntent,
  LaunchKind,
  NoticeMessage,
  OFF,
  buttonOf,
  keepsFlag,
  launchDecision,
  transition,
  tripLaunchIntent
} from "../../assets/js/follow_state.js"
import {PermissionKind} from "../../assets/js/position_watch.js"

const {on, off, unstated} = LaunchIntent
const {granted, prompt, denied} = PermissionKind

const decisionCases = [
  {name: "an intent and a granted permission restore", intent: on, permission: granted, isRestoreOffered: false, expected: LaunchKind.restore},
  {name: "an intent and WebKit's prompt at load restore", intent: on, permission: prompt, isRestoreOffered: false, expected: LaunchKind.restore},
  {name: "an intent and a denied permission block", intent: on, permission: denied, isRestoreOffered: false, expected: LaunchKind.blocked},
  {name: "no intent and a granted permission stay off", intent: off, permission: granted, isRestoreOffered: false, expected: LaunchKind.off},
  {name: "no intent and a prompt stay off", intent: off, permission: prompt, isRestoreOffered: false, expected: LaunchKind.off},
  {name: "no intent and a denied permission block", intent: off, permission: denied, isRestoreOffered: false, expected: LaunchKind.blocked},
  {name: "an unstated intent and a granted permission restore", intent: unstated, permission: granted, isRestoreOffered: false, expected: LaunchKind.restore},
  {name: "an unstated intent and a prompt stay off", intent: unstated, permission: prompt, isRestoreOffered: false, expected: LaunchKind.off},
  {name: "an unstated intent and a denied permission block", intent: unstated, permission: denied, isRestoreOffered: false, expected: LaunchKind.blocked},
  {name: "an intent and a grant once the restore was offered stay off", intent: on, permission: granted, isRestoreOffered: true, expected: LaunchKind.off},
  {name: "an intent and a prompt once the restore was offered stay off", intent: on, permission: prompt, isRestoreOffered: true, expected: LaunchKind.off},
  {name: "a denial once the restore was offered still blocks", intent: on, permission: denied, isRestoreOffered: true, expected: LaunchKind.blocked}
]

for (const {name, expected, ...given} of decisionCases) {
  deepStrictEqual(launchDecision(given).kind, expected, name)
}

const invalidDecisions = [
  {name: "an intent of no kind", given: {intent: "maybe", permission: granted, isRestoreOffered: false}},
  {name: "a permission of no kind", given: {intent: on, permission: "unknown", isRestoreOffered: false}},
  {name: "an offer that is not a boolean", given: {intent: on, permission: granted, isRestoreOffered: "no"}}
]

for (const {name, given} of invalidDecisions) {
  throws(() => launchDecision(given), `a launch decision refuses ${name}`)
}

const LOCATION_FROM = {kind: "location"}
const STOP_FROM = {kind: "stop", stopId: "1_100", name: "Pine St & 3rd Ave"}
const POINT_TO = {kind: "point", name: "Pike Place Market", lat: 47.6094, lon: -122.3422}

const intentCases = [
  {name: "no recent trip leaves the intent unstated", recentTrips: [], expected: unstated},
  {name: "a last trip from My location states the intent", recentTrips: [{from: LOCATION_FROM, to: POINT_TO}, {from: STOP_FROM, to: POINT_TO}], expected: on},
  {name: "a last trip from a stop leaves the intent unstated", recentTrips: [{from: STOP_FROM, to: POINT_TO}, {from: LOCATION_FROM, to: POINT_TO}], expected: unstated}
]

for (const {name, recentTrips, expected} of intentCases) {
  deepStrictEqual(tripLaunchIntent({recentTrips}), expected, name)
}

throws(readIntentOfNoList, "a trip intent refuses recent trips that are not a list")

function readIntentOfNoList() {
  return tripLaunchIntent({recentTrips: null})
}

function state(fields) {
  return {...OFF, ...fields}
}

const restored = state({kind: FollowKind.following, isLaunchWaiting: true})
const waiting = state({kind: FollowKind.following, isNoticeOwed: true})
const following = state({kind: FollowKind.following, isCentered: true, place: FixPlace.inside})
const resume = state({kind: FollowKind.resume})
const blocked = state({kind: FollowKind.blocked})
const launchTimeout = {kind: FollowEventKind.launchTimeout}

ok(Number.isSafeInteger(LAUNCH_WAIT_MS_MAX), `the launch wait of ${LAUNCH_WAIT_MS_MAX} ms is a whole number`)
ok(LAUNCH_WAIT_MS_MAX > 0, `the launch wait of ${LAUNCH_WAIT_MS_MAX} ms is positive`)

const transitionCases = [
  {name: "a restore follows and waits on the launch", from: OFF, event: {kind: FollowEventKind.restore}, to: restored, effects: []},
  {name: "a launch with no answer in time falls back to resume", from: restored, event: launchTimeout, to: resume, effects: [{kind: "notice", message: NoticeMessage.resume}]},
  {name: "a launch answered with a fix ends the wait", from: restored, event: {kind: FollowEventKind.fix, place: FixPlace.inside}, to: state({kind: FollowKind.following, isCentered: true, place: FixPlace.inside}), effects: [{kind: "center", zoom: "first"}]},
  {name: "a launch answered with a failure ends the wait", from: restored, event: {kind: FollowEventKind.failed}, to: state({kind: FollowKind.following, isStale: true}), effects: []},
  {name: "a launch answered with a denial blocks", from: restored, event: {kind: FollowEventKind.denied}, to: blocked, effects: []},
  {name: "a timeout after a fix changes nothing", from: following, event: launchTimeout, to: following, effects: []},
  {name: "a timeout of a follow the rider pressed changes nothing", from: waiting, event: launchTimeout, to: waiting, effects: []},
  {name: "a timeout while off changes nothing", from: OFF, event: launchTimeout, to: OFF, effects: []},
  {name: "a press in resume follows and asks", from: resume, event: {kind: FollowEventKind.click}, to: waiting, effects: [{kind: "notice", message: NoticeMessage.following}]},
  {name: "a fix in resume is stray", from: resume, event: {kind: FollowEventKind.fix, place: FixPlace.inside}, to: resume, effects: []},
  {name: "a restore in resume changes nothing", from: resume, event: {kind: FollowEventKind.restore}, to: resume, effects: []}
]

for (const {name, from, event, to, effects} of transitionCases) {
  deepStrictEqual(transition({state: from, event}), {state: to, effects}, name)
}

deepStrictEqual(
  buttonOf(resume),
  {label: "Resume following my location", pressed: false, disabled: false, className: ButtonClass.none},
  "the button in resume"
)

const flagCases = [
  {name: "Off", given: OFF, expected: false},
  {name: "a restored follow", given: restored, expected: true},
  {name: "Following", given: following, expected: true},
  {name: "Located", given: state({kind: FollowKind.located, place: FixPlace.inside}), expected: true},
  {name: "resume", given: resume, expected: true},
  {name: "blocked", given: blocked, expected: false}
]

for (const {name, given, expected} of flagCases) {
  deepStrictEqual(keepsFlag(given), expected, `the flag is kept in ${name}`)
}

console.log("follow launch check passed")
