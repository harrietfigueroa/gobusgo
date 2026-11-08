// Checks the rules of the rider's position watch against cases written out
// by hand: what a hold and a release do to the holders, whether the watch
// starts, stops, or stays for each count of holders, visibility, and
// permission, the outcome each GeolocationPositionError code maps to, the
// permission a Permissions API state reads as, the plain value a fix is
// copied to, and how long the latest fix stays readable. It also reads the
// two source files of the watch and fails on any call that could carry a
// position out of the browser. Run it with
// `node test/scripts/rider_position_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {AssertionError} from "../../assets/js/assert.js"
import {
  FIX_AGE_MS_MAX,
  LatestKind,
  MeasureKind,
  NO_FIX,
  OutcomeKind,
  PermissionKind,
  WATCH_OPTIONS,
  WatchAction,
  errorOutcome,
  fixOf,
  freshFix,
  permissionOf,
  watchAction,
  withHolder,
  withoutHolder
} from "../../assets/js/position_watch.js"

const NOW_MS = 1_700_000_000_000
const WATCH_FIX_AGE_MS = 5 * 1000
const WATCH_TIMEOUT_MS = 10 * 1000
const READ_FIX_AGE_MS = 30 * 1000

deepStrictEqual(WATCH_OPTIONS, {enableHighAccuracy: true, maximumAge: WATCH_FIX_AGE_MS, timeout: WATCH_TIMEOUT_MS}, "the watch's options")
deepStrictEqual(FIX_AGE_MS_MAX, READ_FIX_AGE_MS, "the age bound of an on-demand read")

const holdCases = [
  {name: "a first holder", holders: [], holder: "trip", held: ["trip"]},
  {name: "a second holder", holders: ["trip"], holder: "follow", held: ["follow", "trip"]},
  {name: "a holder that takes the watch again", holders: ["trip"], holder: "trip", held: ["trip"]}
]

const releaseCases = [
  {name: "the last release", holders: ["trip"], holder: "trip", held: []},
  {name: "one of two releases", holders: ["follow", "trip"], holder: "trip", held: ["follow"]},
  {name: "a release by no holder", holders: ["follow"], holder: "trip", held: ["follow"]}
]

const actionCases = [
  {name: "a first holder", isWatching: false, holderCount: 1, isVisible: true, permission: PermissionKind.prompt, action: WatchAction.start},
  {name: "a second holder", isWatching: true, holderCount: 2, isVisible: true, permission: PermissionKind.granted, action: WatchAction.keep},
  {name: "one of two releases", isWatching: true, holderCount: 1, isVisible: true, permission: PermissionKind.granted, action: WatchAction.keep},
  {name: "the last release", isWatching: true, holderCount: 0, isVisible: true, permission: PermissionKind.granted, action: WatchAction.stop},
  {name: "no holder and no watch", isWatching: false, holderCount: 0, isVisible: true, permission: PermissionKind.prompt, action: WatchAction.keep},
  {name: "a page that is hidden", isWatching: true, holderCount: 2, isVisible: false, permission: PermissionKind.granted, action: WatchAction.stop},
  {name: "a page that is shown again", isWatching: false, holderCount: 2, isVisible: true, permission: PermissionKind.granted, action: WatchAction.start},
  {name: "a page shown again with no holder", isWatching: false, holderCount: 0, isVisible: true, permission: PermissionKind.granted, action: WatchAction.keep},
  {name: "a hold while the page is hidden", isWatching: false, holderCount: 1, isVisible: false, permission: PermissionKind.prompt, action: WatchAction.keep},
  {name: "a denied permission", isWatching: true, holderCount: 2, isVisible: true, permission: PermissionKind.denied, action: WatchAction.stop},
  {name: "a page shown again after a denial", isWatching: false, holderCount: 2, isVisible: true, permission: PermissionKind.denied, action: WatchAction.keep}
]

const errorCases = [
  {code: 1, outcome: {kind: OutcomeKind.denied}},
  {code: 2, outcome: {kind: OutcomeKind.unavailable}},
  {code: 3, outcome: {kind: OutcomeKind.timedOut}},
  {code: 0, outcome: {kind: OutcomeKind.unavailable}}
]

const permissionCases = [
  {state: "granted", permission: PermissionKind.granted},
  {state: "prompt", permission: PermissionKind.prompt},
  {state: "denied", permission: PermissionKind.denied},
  {state: undefined, permission: PermissionKind.prompt},
  {state: "unknown", permission: PermissionKind.prompt}
]

const moving = {
  timestamp: NOW_MS,
  coords: {latitude: 47.6062, longitude: -122.3321, accuracy: 12, heading: 90, speed: 5, altitude: 30}
}

const still = {
  timestamp: NOW_MS,
  coords: {latitude: 47.6062, longitude: -122.3321, accuracy: 40, heading: null, speed: null, altitude: null}
}

const stillNotANumber = {
  timestamp: NOW_MS,
  coords: {latitude: 47.6062, longitude: -122.3321, accuracy: 40, heading: Number.NaN, speed: 0, altitude: null}
}

const fixCases = [
  {
    name: "a moving fix",
    position: moving,
    fix: {
      latitude: 47.6062,
      longitude: -122.3321,
      accuracyM: 12,
      heading: {kind: MeasureKind.measured, value: 90},
      speed: {kind: MeasureKind.measured, value: 5},
      timeMs: NOW_MS
    }
  },
  {
    name: "a fix with no heading or speed",
    position: still,
    fix: {
      latitude: 47.6062,
      longitude: -122.3321,
      accuracyM: 40,
      heading: {kind: MeasureKind.none},
      speed: {kind: MeasureKind.none},
      timeMs: NOW_MS
    }
  },
  {
    name: "a still fix whose heading is not a number",
    position: stillNotANumber,
    fix: {
      latitude: 47.6062,
      longitude: -122.3321,
      accuracyM: 40,
      heading: {kind: MeasureKind.none},
      speed: {kind: MeasureKind.measured, value: 0},
      timeMs: NOW_MS
    }
  }
]

const freshCases = [
  {name: "no fix yet", ageMs: null, kind: LatestKind.none},
  {name: "a new fix", ageMs: 0, kind: LatestKind.fresh},
  {name: "a fix just inside the bound", ageMs: FIX_AGE_MS_MAX - 1, kind: LatestKind.fresh},
  {name: "a fix at the bound", ageMs: FIX_AGE_MS_MAX, kind: LatestKind.none},
  {name: "a fix from the future", ageMs: -1, kind: LatestKind.fresh}
]

// A position read by any of these would leave the browser or outlive the
// page: an event to the server, a request, storage, or a log line.
const leakPatterns = [/pushEvent/, /\bfetch\(/, /localStorage/, /sessionStorage/, /indexedDB/, /sendBeacon/, /XMLHttpRequest/, /WebSocket/, /\bconsole\.(log|info|debug)/]
const sourcePaths = ["assets/js/rider_position.js", "assets/js/position_watch.js"]

function holdNoName() {
  return withHolder({holders: [], holder: ""})
}

function actNegativeCount() {
  return watchAction({isWatching: false, holderCount: -1, isVisible: true, permission: PermissionKind.prompt})
}

function actUnknownPermission() {
  return watchAction({isWatching: false, holderCount: 1, isVisible: true, permission: "maybe"})
}

for (const {name, holders, holder, held} of holdCases) {
  const after = withHolder({holders, holder})
  const names = Array.from(after)
  deepStrictEqual(names.sort(), held, name)
}

for (const {name, holders, holder, held} of releaseCases) {
  const after = withoutHolder({holders, holder})
  const names = Array.from(after)
  deepStrictEqual(names.sort(), held, name)
}

throws(holdNoName, AssertionError, "a holder with no name")

for (const {name, action, ...state} of actionCases) {
  deepStrictEqual(watchAction(state), action, name)
}

throws(actNegativeCount, AssertionError, "a negative count of holders")
throws(actUnknownPermission, AssertionError, "a permission of no kind")

for (const {code, outcome} of errorCases) {
  deepStrictEqual(errorOutcome(code), outcome, `the outcome of error code ${code}`)
}

for (const {state, permission} of permissionCases) {
  deepStrictEqual(permissionOf(state), permission, `the permission state ${state}`)
}

for (const {name, position, fix} of fixCases) {
  const copied = fixOf(position)
  deepStrictEqual(copied, {kind: OutcomeKind.fix, fix}, name)
  ok(Object.isFrozen(copied.fix), `${name} is frozen`)
}

const source = structuredClone(moving)
const copied = fixOf(source)
source.coords.latitude = 0
deepStrictEqual(copied.fix.latitude, moving.coords.latitude, "a fix outlives a change to the position it was copied from")

for (const {name, ageMs, kind} of freshCases) {
  let latest = NO_FIX

  if (ageMs !== null) {
    latest = fixOf({...moving, timestamp: NOW_MS - ageMs})
  }

  deepStrictEqual(freshFix({latest, nowMs: NOW_MS}).kind, kind, name)
}

for (const path of sourcePaths) {
  const text = readFileSync(new URL(`../../${path}`, import.meta.url), "utf8")

  for (const pattern of leakPatterns) {
    ok(!pattern.test(text), `${path} holds ${pattern}, which could carry a position out of the browser`)
  }
}

console.log("rider position check passed")
