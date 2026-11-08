// Checks the rules of the cone on the rider's dot against cases written out
// by hand: which fixes give a GPS heading, the compass readings of Safari on
// iOS and of an absolute orientation event with the screen's angle, the
// correction from magnetic to true north, which source the cone follows and
// when a reading is too old, when a turn redraws the cone, the way the cone
// turns across north, how long a turn eases, when the orientation listener
// runs, and when a click or the setting asks for the motion permission. It
// also reads the direction's source files and fails on any call that could
// carry a heading out of the browser. Run it with
// `node test/scripts/rider_heading_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {
  CONE_TURN_MS,
  CONE_WIDTH_DEGREES,
  CompassSource,
  HEADING_AGE_MS_MAX,
  HeadingSource,
  MOVING_SPEED_MPS_MIN,
  NO_READING,
  ReadingKind,
  SEATTLE_DECLINATION_DEGREES,
  TURN_DEGREES_MIN,
  asksMotionPermission,
  compassReading,
  compassSourceOf,
  coneHeading,
  coneTurnMs,
  gpsReading,
  isRedrawn,
  listensOrientation,
  turnedRotation
} from "../../assets/js/rider_heading.js"
import {FollowKind} from "../../assets/js/follow_state.js"
import {MeasureKind} from "../../assets/js/position_watch.js"

const DECLINATION = 14.86
const NOW_MS = 1_800_000_000_000
const CLOSE_DEGREES = 1e-9
const DEGREES_PER_TURN = 360
const WIDTH_DEGREES = 60
const SPEED_MPS_MIN = 1
const AGE_MS_MAX = 10 * 1000
const TURN_DEGREES = 2
const FIX_AGE_MS = 3 * 1000
const FIX_FIELDS = Object.freeze({latitude: 47.6, longitude: -122.3, accuracyM: 5})

deepStrictEqual(CONE_WIDTH_DEGREES, WIDTH_DEGREES, "the cone's width")
deepStrictEqual(MOVING_SPEED_MPS_MIN, SPEED_MPS_MIN, "the speed from which GPS gives the heading")
deepStrictEqual(HEADING_AGE_MS_MAX, AGE_MS_MAX, "the age past which a heading draws no cone")
deepStrictEqual(TURN_DEGREES_MIN, TURN_DEGREES, "the turn that redraws the cone")
deepStrictEqual(SEATTLE_DECLINATION_DEGREES, DECLINATION, "Seattle's declination east of true north")

// A measure of the position watch, none for null.
function measure(value) {
  if (value === null) {
    return {kind: MeasureKind.none}
  }

  return {kind: MeasureKind.measured, value}
}

function fix({heading, speed}) {
  return {...FIX_FIELDS, heading: measure(heading), speed: measure(speed), timeMs: NOW_MS}
}

// The reading of `degrees` at the check's time, none for null.
function reading(degrees) {
  if (degrees === null) {
    return NO_READING
  }

  return {kind: ReadingKind.measured, degrees, timeMs: NOW_MS}
}

// The reading of the magnetic heading `magneticDegrees` corrected to true
// north, none for null.
function trueReading(magneticDegrees) {
  if (magneticDegrees === null) {
    return NO_READING
  }

  return reading((magneticDegrees + DECLINATION) % DEGREES_PER_TURN)
}

function isClose({actual, expected}) {
  return Math.abs(actual - expected) < CLOSE_DEGREES
}

function assertReading({actual, expected, name}) {
  if (expected.kind === ReadingKind.none) {
    deepStrictEqual(actual, NO_READING, name)
    return
  }

  deepStrictEqual(actual.kind, ReadingKind.measured, name)
  deepStrictEqual(actual.timeMs, expected.timeMs, `${name}: time`)
  ok(isClose({actual: actual.degrees, expected: expected.degrees}), `${name}: ${actual.degrees} degrees, not ${expected.degrees}`)
}

const gpsCases = [
  {name: "a fix at 5 m/s heading east", heading: 90, speed: 5, degrees: 90},
  {name: "a fix at exactly 1 m/s", heading: 180, speed: 1, degrees: 180},
  {name: "a fix just under 1 m/s", heading: 180, speed: 0.99, degrees: null},
  {name: "a fix standing still", heading: 90, speed: 0, degrees: null},
  {name: "a fix with no heading", heading: null, speed: 5, degrees: null},
  {name: "a fix with no speed", heading: 90, speed: null, degrees: null},
  {name: "a heading of a whole turn", heading: 360, speed: 5, degrees: 0}
]

for (const gpsCase of gpsCases) {
  const actual = gpsReading(fix({heading: gpsCase.heading, speed: gpsCase.speed}))
  assertReading({actual, expected: reading(gpsCase.degrees), name: `GPS: ${gpsCase.name}`})
}

deepStrictEqual(compassSourceOf({hasAbsoluteEvent: true}), CompassSource.absolute, "a browser with the absolute event listens to it")
deepStrictEqual(compassSourceOf({hasAbsoluteEvent: false}), CompassSource.webkit, "a browser without it reads Safari's compass heading")

// Each case names the magnetic heading the event means, which the reading
// gives corrected by the declination.
const compassCases = [
  {name: "Safari facing magnetic north", source: CompassSource.webkit, event: {webkitCompassHeading: 0, webkitCompassAccuracy: 10}, screenAngle: 0, magnetic: 0},
  {name: "Safari facing magnetic east", source: CompassSource.webkit, event: {webkitCompassHeading: 90, webkitCompassAccuracy: 10}, screenAngle: 0, magnetic: 90},
  {name: "Safari past north once corrected", source: CompassSource.webkit, event: {webkitCompassHeading: 350, webkitCompassAccuracy: 10}, screenAngle: 0, magnetic: 350},
  {name: "Safari with no compass", source: CompassSource.webkit, event: {webkitCompassHeading: 0, webkitCompassAccuracy: -1}, screenAngle: 0, magnetic: null},
  {name: "Safari with no compass heading", source: CompassSource.webkit, event: {webkitCompassHeading: undefined, webkitCompassAccuracy: undefined}, screenAngle: 0, magnetic: null},
  {name: "absolute, portrait, facing magnetic north", source: CompassSource.absolute, event: {alpha: 0, absolute: true}, screenAngle: 0, magnetic: 0},
  {name: "absolute, portrait, turned a quarter left", source: CompassSource.absolute, event: {alpha: 90, absolute: true}, screenAngle: 0, magnetic: 270},
  {name: "absolute, landscape at 90, top to the west", source: CompassSource.absolute, event: {alpha: 90, absolute: true}, screenAngle: 90, magnetic: 0},
  {name: "absolute, landscape at 270, top to the east", source: CompassSource.absolute, event: {alpha: 270, absolute: true}, screenAngle: 270, magnetic: 0},
  {name: "absolute, upside down", source: CompassSource.absolute, event: {alpha: 0, absolute: true}, screenAngle: 180, magnetic: 180},
  {name: "an orientation that is not absolute", source: CompassSource.absolute, event: {alpha: 0, absolute: false}, screenAngle: 0, magnetic: null},
  {name: "an orientation with no alpha", source: CompassSource.absolute, event: {alpha: null, absolute: true}, screenAngle: 0, magnetic: null}
]

for (const compassCase of compassCases) {
  const actual = compassReading({source: compassCase.source, event: compassCase.event, screenAngle: compassCase.screenAngle, timeMs: NOW_MS})
  const expected = trueReading(compassCase.magnetic)
  assertReading({actual, expected, name: `compass: ${compassCase.name}`})
}

const gpsEast = Object.freeze({kind: ReadingKind.measured, degrees: 90, timeMs: NOW_MS})
const compassSouth = Object.freeze({kind: ReadingKind.measured, degrees: 180, timeMs: NOW_MS})
const ageMax = HEADING_AGE_MS_MAX
const coneCases = [
  {name: "GPS wins over the compass", gps: gpsEast, compass: compassSouth, isShown: true, expected: {source: HeadingSource.gps, degrees: 90}},
  {name: "the compass while still", gps: NO_READING, compass: compassSouth, isShown: true, expected: {source: HeadingSource.compass, degrees: 180}},
  {name: "the compass after a stale GPS heading", gps: {...gpsEast, timeMs: NOW_MS - ageMax - 1}, compass: compassSouth, isShown: true, expected: {source: HeadingSource.compass, degrees: 180}},
  {name: "a GPS heading exactly at the age bound", gps: {...gpsEast, timeMs: NOW_MS - ageMax}, compass: NO_READING, isShown: true, expected: {source: HeadingSource.gps, degrees: 90}},
  {name: "both readings stale", gps: {...gpsEast, timeMs: NOW_MS - ageMax - 1}, compass: {...compassSouth, timeMs: NOW_MS - ageMax - 1}, isShown: true, expected: null},
  {name: "no reading at all", gps: NO_READING, compass: NO_READING, isShown: true, expected: null},
  {name: "the setting off", gps: gpsEast, compass: compassSouth, isShown: false, expected: null}
]

for (const coneCase of coneCases) {
  const actual = coneHeading({gps: coneCase.gps, compass: coneCase.compass, isShown: coneCase.isShown, nowMs: NOW_MS})

  if (coneCase.expected === null) {
    deepStrictEqual(actual, NO_READING, `cone: ${coneCase.name}`)
  } else {
    deepStrictEqual(actual.kind, ReadingKind.measured, `cone: ${coneCase.name}`)
    deepStrictEqual(actual.source, coneCase.expected.source, `cone: ${coneCase.name}: source`)
    deepStrictEqual(actual.degrees, coneCase.expected.degrees, `cone: ${coneCase.name}: degrees`)
  }
}

{
  const fixTimeMs = NOW_MS - FIX_AGE_MS
  const cone = coneHeading({gps: {...gpsEast, timeMs: fixTimeMs}, compass: NO_READING, isShown: true, nowMs: NOW_MS})
  deepStrictEqual(cone.expiresAtMs, fixTimeMs + ageMax, "a cone names when its reading grows too old")
}

// The heading drawn last and the heading now, in degrees, none for null.
const redrawCases = [
  {name: "no cone stays none", drawn: null, heading: null, redrawn: false},
  {name: "a first heading", drawn: null, heading: 10, redrawn: true},
  {name: "a heading lost", drawn: 10, heading: null, redrawn: true},
  {name: "a turn under the threshold", drawn: 10, heading: 11.9, redrawn: false},
  {name: "a turn of the threshold", drawn: 10, heading: 12, redrawn: true},
  {name: "a turn back of the threshold", drawn: 10, heading: 8, redrawn: true},
  {name: "a turn across north of the threshold", drawn: 359, heading: 1, redrawn: true},
  {name: "a turn across north under it", drawn: 359.5, heading: 0.5, redrawn: false}
]

for (const redrawCase of redrawCases) {
  const redrawn = isRedrawn({drawn: reading(redrawCase.drawn), heading: reading(redrawCase.heading)})
  deepStrictEqual(redrawn, redrawCase.redrawn, `redraw: ${redrawCase.name}`)
}

const rotationCases = [
  {name: "clockwise across north", rotation: 350, degrees: 10, turned: 370},
  {name: "counterclockwise across north", rotation: 10, degrees: 350, turned: -10},
  {name: "a half turn goes clockwise", rotation: 0, degrees: 180, turned: 180},
  {name: "from a rotation past a turn", rotation: 725, degrees: 0, turned: 720},
  {name: "from a negative rotation", rotation: -30, degrees: 300, turned: -60}
]

for (const rotationCase of rotationCases) {
  const turned = turnedRotation({rotation: rotationCase.rotation, degrees: rotationCase.degrees})
  deepStrictEqual(turned, rotationCase.turned, `rotation: ${rotationCase.name}`)
}

deepStrictEqual(coneTurnMs({reducedMotion: false}), CONE_TURN_MS, "the cone eases a turn")
deepStrictEqual(coneTurnMs({reducedMotion: true}), 0, "the cone turns at once under reduced motion")

const listenCases = [
  {isDotDrawn: true, isVisible: true, isShown: true, listens: true},
  {isDotDrawn: false, isVisible: true, isShown: true, listens: false},
  {isDotDrawn: true, isVisible: false, isShown: true, listens: false},
  {isDotDrawn: true, isVisible: true, isShown: false, listens: false}
]

for (const listenCase of listenCases) {
  const {listens, ...conditions} = listenCase
  deepStrictEqual(listensOrientation(conditions), listens, `listener: ${JSON.stringify(conditions)}`)
}

const askBase = {previousKind: FollowKind.off, nextKind: FollowKind.following, isShown: true, isDenied: false, canRequest: true}
const askCases = [
  {name: "a click from Off to Following", fields: {}, asks: true},
  {name: "a click from Located to Following", fields: {previousKind: FollowKind.located}, asks: false},
  {name: "a click from Following to Off", fields: {previousKind: FollowKind.following, nextKind: FollowKind.off}, asks: false},
  {name: "the setting off", fields: {isShown: false}, asks: false},
  {name: "a denial stored", fields: {isDenied: true}, asks: false},
  {name: "a browser with no permission to ask for", fields: {canRequest: false}, asks: false}
]

for (const askCase of askCases) {
  deepStrictEqual(asksMotionPermission({...askBase, ...askCase.fields}), askCase.asks, `motion permission: ${askCase.name}`)
}

// A heading read by any of these would leave the browser or outlive the
// page: an event to the server, a request, storage reached directly, or a
// log line. The direction stores through the stored settings alone, and
// writes only the setting and a denial.
const leakPatterns = [/pushEvent/, /\bfetch\(/, /localStorage/, /sessionStorage/, /indexedDB/, /sendBeacon/, /XMLHttpRequest/, /WebSocket/, /\bconsole\.(log|info|debug)/]
const STORED_WRITE_PATTERN = /storedSettings\.write\w*\([^)]*\)/g
const sources = [
  {path: "assets/js/rider_heading.js", writes: []},
  {path: "assets/js/motion_permission.js", writes: ["storedSettings.writeMotionPermissionDenied()"]},
  {path: "assets/js/show_direction.js", writes: ["storedSettings.writeShowDirection(isShown)"]}
]

function firstMatch(match) {
  return match[0]
}

for (const source of sources) {
  const text = readFileSync(new URL(`../../${source.path}`, import.meta.url), "utf8")

  for (const pattern of leakPatterns) {
    ok(!pattern.test(text), `${source.path} holds ${pattern}, which could carry a heading out of the browser`)
  }

  const writes = Array.from(text.matchAll(STORED_WRITE_PATTERN), firstMatch)

  for (const write of writes) {
    ok(source.writes.includes(write), `${source.path} stores ${write}, where only the setting and a denial are stored`)
  }
}

console.log("rider heading check passed")
