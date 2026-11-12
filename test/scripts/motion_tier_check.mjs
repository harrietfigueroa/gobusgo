// Checks when the vehicle page moves its markers continuously, and at what
// rate, under the settings the server hands the page: the zoom band with
// its hysteresis at both edges, the cap on vehicles in view, reduced
// motion, a hidden page, and which markers stand inside the map's bounds.
// The cases run under the default settings and under a band of 13 to 17
// with other rates and another cap. Each case runs one pure function over
// values written here. Run it with `node test/scripts/motion_tier_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {MotionTierKind, STILL_TIER, isPositionInBounds, markerIdsInBounds, motionSettingsOf, motionTier} from "../../assets/js/motion_tier.js"

// The rates of each band's steps.
const DEFAULT_SLOW_RATE_HZ = 4
const DEFAULT_FAST_RATE_HZ = 8
const WIDE_SLOW_RATE_HZ = 2
const WIDE_MIDDLE_RATE_HZ = 6
const WIDE_FAST_RATE_HZ = 12
const DEFAULT_CAP = 100
const WIDE_CAP = 60
const FEW_VEHICLES = 40
const IN_BAND_ZOOM = 15

// The settings as the server's data attribute carries them.
const defaultSettings = motionSettingsOf({
  zoom_min: 14,
  zoom_max: 16,
  hysteresis: 0.25,
  vehicle_count_max: DEFAULT_CAP,
  rates: [{zoom: 14, rate_hz: DEFAULT_SLOW_RATE_HZ}, {zoom: 15, rate_hz: DEFAULT_FAST_RATE_HZ}]
})

const wideSettings = motionSettingsOf({
  zoom_min: 13,
  zoom_max: 17,
  hysteresis: 0.5,
  vehicle_count_max: WIDE_CAP,
  rates: [{zoom: 13, rate_hz: WIDE_SLOW_RATE_HZ}, {zoom: 14.5, rate_hz: WIDE_MIDDLE_RATE_HZ}, {zoom: 16, rate_hz: WIDE_FAST_RATE_HZ}]
})

function animating(rateHz) {
  return {kind: MotionTierKind.animating, rateHz}
}

const SLOW = animating(DEFAULT_SLOW_RATE_HZ)
const FAST = animating(DEFAULT_FAST_RATE_HZ)
const WIDE_SLOW = animating(WIDE_SLOW_RATE_HZ)
const WIDE_MIDDLE = animating(WIDE_MIDDLE_RATE_HZ)
const WIDE_FAST = animating(WIDE_FAST_RATE_HZ)

function tierAt({settings, zoom, previous}) {
  return motionTier({settings, zoom, vehicleCountInView: FEW_VEHICLES, isReducedMotion: false, isVisible: true, previous})
}

deepStrictEqual(defaultSettings, {
  zoomMin: 14,
  zoomMax: 16,
  hysteresis: 0.25,
  vehicleCountMax: DEFAULT_CAP,
  rates: [{zoom: 14, rateHz: DEFAULT_SLOW_RATE_HZ}, {zoom: 15, rateHz: DEFAULT_FAST_RATE_HZ}]
}, "the default settings read from the server's form")

// The zoom band and its hysteresis: a still map starts inside the band, and
// a running one keeps going to the hysteresis past each edge.
const defaultZoomCases = [
  {name: "a still map below the band stays still", zoom: 13.9, previous: STILL_TIER, expected: STILL_TIER},
  {name: "a still map at 14 starts at 4 Hz", zoom: 14, previous: STILL_TIER, expected: SLOW},
  {name: "a still map at 14.5 starts at 4 Hz", zoom: 14.5, previous: STILL_TIER, expected: SLOW},
  {name: "a still map at 15 starts at 8 Hz", zoom: 15, previous: STILL_TIER, expected: FAST},
  {name: "a still map at 15.99 starts at 8 Hz", zoom: 15.99, previous: STILL_TIER, expected: FAST},
  {name: "a still map at 16 stays still", zoom: 16, previous: STILL_TIER, expected: STILL_TIER},
  {name: "a still map at 16.1 stays still", zoom: 16.1, previous: STILL_TIER, expected: STILL_TIER},
  {name: "a still map at 13.8 stays still", zoom: 13.8, previous: STILL_TIER, expected: STILL_TIER},
  {name: "a running map at 13.8 keeps going at 4 Hz", zoom: 13.8, previous: SLOW, expected: SLOW},
  {name: "a running map at 13.75 keeps going at 4 Hz", zoom: 13.75, previous: SLOW, expected: SLOW},
  {name: "a running map below 13.75 stops", zoom: 13.74, previous: SLOW, expected: STILL_TIER},
  {name: "a running map at 16.1 keeps going at 8 Hz", zoom: 16.1, previous: FAST, expected: FAST},
  {name: "a running map just under 16.25 keeps going", zoom: 16.249, previous: FAST, expected: FAST},
  {name: "a running map at 16.25 stops", zoom: 16.25, previous: FAST, expected: STILL_TIER},
  {name: "a running map at 17 stops", zoom: 17, previous: FAST, expected: STILL_TIER},
  {name: "a running map that zooms from 14 to 15 speeds up", zoom: 15.2, previous: SLOW, expected: FAST},
  {name: "a running map that zooms from 15 to 14 slows down", zoom: 14.2, previous: FAST, expected: SLOW}
]

const wideZoomCases = [
  {name: "a still map at 12.9 stays still", zoom: 12.9, previous: STILL_TIER, expected: STILL_TIER},
  {name: "a still map at 13 starts at 2 Hz", zoom: 13, previous: STILL_TIER, expected: WIDE_SLOW},
  {name: "a still map at 14.5 starts at 6 Hz", zoom: 14.5, previous: STILL_TIER, expected: WIDE_MIDDLE},
  {name: "a still map at 16.5 starts at 12 Hz", zoom: 16.5, previous: STILL_TIER, expected: WIDE_FAST},
  {name: "a still map at 17 stays still", zoom: 17, previous: STILL_TIER, expected: STILL_TIER},
  {name: "a running map at 12.5 keeps going at 2 Hz", zoom: 12.5, previous: WIDE_SLOW, expected: WIDE_SLOW},
  {name: "a running map below 12.5 stops", zoom: 12.49, previous: WIDE_SLOW, expected: STILL_TIER},
  {name: "a running map at 17.49 keeps going at 12 Hz", zoom: 17.49, previous: WIDE_FAST, expected: WIDE_FAST},
  {name: "a running map at 17.5 stops", zoom: 17.5, previous: WIDE_FAST, expected: STILL_TIER},
  {name: "the default band's upper edge animates in the wide band", zoom: 16.25, previous: STILL_TIER, expected: WIDE_FAST}
]

for (const {name, zoom, previous, expected} of defaultZoomCases) {
  deepStrictEqual(tierAt({settings: defaultSettings, zoom, previous}), expected, `default: ${name}`)
}

for (const {name, zoom, previous, expected} of wideZoomCases) {
  deepStrictEqual(tierAt({settings: wideSettings, zoom, previous}), expected, `13 to 17: ${name}`)
}

// The count of vehicles in view, at most the cap, with no hysteresis.
const countCases = [
  {name: "the default cap of vehicles animates", settings: defaultSettings, count: DEFAULT_CAP, previous: STILL_TIER, expected: FAST},
  {name: "one past the default cap does not start", settings: defaultSettings, count: DEFAULT_CAP + 1, previous: STILL_TIER, expected: STILL_TIER},
  {name: "one past the default cap stops a running map", settings: defaultSettings, count: DEFAULT_CAP + 1, previous: FAST, expected: STILL_TIER},
  {name: "no vehicle in view animates", settings: defaultSettings, count: 0, previous: STILL_TIER, expected: FAST},
  {name: "a cap of 60 animates 60", settings: wideSettings, count: WIDE_CAP, previous: STILL_TIER, expected: WIDE_MIDDLE},
  {name: "a cap of 60 stops at 61", settings: wideSettings, count: WIDE_CAP + 1, previous: WIDE_MIDDLE, expected: STILL_TIER}
]

for (const {name, settings, count, previous, expected} of countCases) {
  const tier = motionTier({settings, zoom: IN_BAND_ZOOM, vehicleCountInView: count, isReducedMotion: false, isVisible: true, previous})
  deepStrictEqual(tier, expected, name)
}

// Reduced motion and a hidden page never animate.
for (const settings of [defaultSettings, wideSettings]) {
  for (const previous of [STILL_TIER, FAST]) {
    const reduced = motionTier({settings, zoom: IN_BAND_ZOOM, vehicleCountInView: FEW_VEHICLES, isReducedMotion: true, isVisible: true, previous})
    deepStrictEqual(reduced, STILL_TIER, `reduced motion is still after ${previous.kind}`)
    const hidden = motionTier({settings, zoom: IN_BAND_ZOOM, vehicleCountInView: FEW_VEHICLES, isReducedMotion: false, isVisible: false, previous})
    deepStrictEqual(hidden, STILL_TIER, `a hidden page is still after ${previous.kind}`)
  }
}

// Invalid inputs are programmer errors.
const invalidTiers = [
  {name: "a zoom that is not a number", zoom: Number.NaN, vehicleCountInView: 1},
  {name: "a negative count", zoom: IN_BAND_ZOOM, vehicleCountInView: -1},
  {name: "a fractional count", zoom: IN_BAND_ZOOM, vehicleCountInView: 1.5}
]

function invalidTier({zoom, vehicleCountInView}) {
  return motionTier({settings: defaultSettings, zoom, vehicleCountInView, isReducedMotion: false, isVisible: true, previous: STILL_TIER})
}

for (const {name, zoom, vehicleCountInView} of invalidTiers) {
  throws(() => invalidTier({zoom, vehicleCountInView}), AssertionError, name)
}

function tierAfterNoKind() {
  return tierAt({settings: defaultSettings, zoom: IN_BAND_ZOOM, previous: {kind: "spinning"}})
}

throws(tierAfterNoKind, AssertionError, "a previous tier of no kind")

const invalidSettings = [
  {name: "a maximum at the minimum", raw: {zoom_min: 14, zoom_max: 14, hysteresis: 0, vehicle_count_max: 1, rates: [{zoom: 14, rate_hz: 4}]}},
  {name: "a hysteresis of half the band", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 1, vehicle_count_max: 1, rates: [{zoom: 14, rate_hz: 4}]}},
  {name: "a cap of zero", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 0, vehicle_count_max: 0, rates: [{zoom: 14, rate_hz: 4}]}},
  {name: "a cap past the canvas's", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 0, vehicle_count_max: 101, rates: [{zoom: 14, rate_hz: 4}]}},
  {name: "no rate", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 0, vehicle_count_max: 1, rates: []}},
  {name: "a rate of 61 Hz", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 0, vehicle_count_max: 1, rates: [{zoom: 14, rate_hz: 61}]}},
  {name: "a rate's zoom outside the band", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 0, vehicle_count_max: 1, rates: [{zoom: 16, rate_hz: 4}]}},
  {name: "rates out of order", raw: {zoom_min: 14, zoom_max: 16, hysteresis: 0, vehicle_count_max: 1, rates: [{zoom: 15, rate_hz: 8}, {zoom: 14, rate_hz: 4}]}}
]

for (const {name, raw} of invalidSettings) {
  throws(() => motionSettingsOf(raw), AssertionError, `settings: ${name}`)
}

// Which markers stand inside the bounds, edges included.
const bounds = {west: -122.4, south: 47.5, east: -122.3, north: 47.7}
const places = [
  {markerId: "inside", lon: -122.35, lat: 47.6, isInside: true},
  {markerId: "west edge", lon: -122.4, lat: 47.6, isInside: true},
  {markerId: "north edge", lon: -122.35, lat: 47.7, isInside: true},
  {markerId: "east of", lon: -122.29, lat: 47.6, isInside: false},
  {markerId: "south of", lon: -122.35, lat: 47.49, isInside: false}
]

function placeEntry({markerId, lon, lat}) {
  return [markerId, [lon, lat]]
}

const placeEntries = Array.from(places, placeEntry)
const positions = new Map(placeEntries)

deepStrictEqual(markerIdsInBounds({positions, bounds}), ["inside", "west edge", "north edge"], "the markers in bounds")
deepStrictEqual(markerIdsInBounds({positions: new Map(), bounds}), [], "no markers")
const flippedBounds = {west: -122.3, south: 47.5, east: -122.4, north: 47.7}
function idsInFlippedBounds() {
  return markerIdsInBounds({positions, bounds: flippedBounds})
}

throws(idsInFlippedBounds, AssertionError, "bounds whose west is east of their east")

// One position against the bounds, as a glide's ends are judged.
for (const {markerId, lon, lat, isInside} of places) {
  deepStrictEqual(isPositionInBounds({position: [lon, lat], bounds}), isInside, `the ${markerId} position against the bounds`)
}

console.log("motion tier check passed")
