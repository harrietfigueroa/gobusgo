// Checks the tie between a vehicle's last report and its marker: which
// vehicles show one, the line from the ring along the trip's path to the
// marker as time passes and when a report puts the marker ahead of it, the
// vehicles that show none, the line cut where the marker covers it, the
// ring left out under the marker, the strokes the ties are drawn in, and
// when the ties are drawn again, and the casing that edges every ring and
// line against the land of each theme's basemap. Each case runs the pure
// functions over a straight street and points written here. Run it with
// `node test/scripts/report_tie_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, ok, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {METERS_PER_DEGREE, distanceMeters, metersPerDegreeLongitude} from "../../assets/js/core/math/geodesy.js"
import {preparePath} from "../../assets/js/vehicle_prediction.js"
import {drawnVehicle, trackedVehicle} from "../../assets/js/vehicle_motion.js"
import {TIE_ZOOM_MIN, TieKind, reportTie, tiedMarkerIds} from "../../assets/js/report_tie.js"
import {isTieRedrawDue, markerCoverPixels, screenTie, tieStrokes, trimmedLine} from "../../assets/js/report_tie_layout.js"
import {MarkerKind} from "../../assets/js/vehicle_overlay_layout.js"
import {contrastRatio} from "../../assets/js/core/math/color_contrast.js"
import {Theme, mapColors} from "../../assets/js/theme.js"

const LON_ORIGIN = -122.33
const LAT_ORIGIN = 47.6
const METERS_PER_DEGREE_LON = metersPerDegreeLongitude(LAT_ORIGIN)
const SERVICE_DATE_MS = 1794038400000
const MS_PER_SECOND = 1000
const TOLERANCE_METERS = 1
const TRIP_ID = "1_100"
// The schedule drives an L-shaped street at 5 m/s from 10:00: 500 m east,
// then 500 m north.
const START_SECONDS = 36000
const CORNER_METERS = 500
const REPORT_OFF_PATH_METERS = 8
const TRIM_PIXELS = 10
const INTERVAL_MS = 1000
const ROUND_COVER_PIXELS = 7.5
const GLYPH_COVER_PIXELS = 11
const NON_TEXT_CONTRAST_MIN = 3

function at({east, north = 0}) {
  return [LON_ORIGIN + east / METERS_PER_DEGREE_LON, LAT_ORIGIN + north / METERS_PER_DEGREE]
}

function msAt({seconds}) {
  return SERVICE_DATE_MS + (START_SECONDS + seconds) * MS_PER_SECOND
}

function isNear({position, expected, message}) {
  const offset = distanceMeters(position, expected)
  ok(offset <= TOLERANCE_METERS, `${message}: ${offset} m from where it belongs`)
}

const street = preparePath({
  tripId: TRIP_ID,
  serviceDateMs: SERVICE_DATE_MS,
  points: [at({east: 0}), at({east: CORNER_METERS}), at({east: CORNER_METERS, north: 500})],
  stops: [
    {distanceMeters: 0, arrivalSeconds: START_SECONDS, departureSeconds: START_SECONDS},
    {distanceMeters: 1000, arrivalSeconds: START_SECONDS + 200, departureSeconds: START_SECONDS + 200}
  ]
})

// A marker as the server sends it, reported at `position` at `seconds`
// past 10:00.
function marker({position, seconds, status = "reported"}) {
  const [lon, lat] = position
  return {
    id: "1_bus",
    lat,
    lon,
    status,
    report: {lon, lat, time_ms: msAt({seconds})},
    trip_id: TRIP_ID,
    route_id: "1_7",
    service_date_ms: SERVICE_DATE_MS
  }
}

// A report 8 m off the street, 400 m along it, on the schedule; 40 s on the
// schedule has driven it round the corner to 600 m.
const reportPosition = at({east: 400, north: -REPORT_OFF_PATH_METERS})
const tracked = trackedVehicle({tracked: null, marker: marker({position: reportPosition, seconds: 80}), path: street, atMs: msAt({seconds: 80})})
const roundCorner = drawnVehicle({tracked, atMs: msAt({seconds: 120})})
const tie = reportTie(roundCorner)
deepStrictEqual(tie.kind, TieKind.tie, "a vehicle predicted along its path has a tie")
deepStrictEqual(tie.ring, reportPosition, "the ring stands at the report itself")
const [ringPoint, joinPoint, cornerPoint, markerPoint, ...beyond] = tie.line
deepStrictEqual(beyond, [], "the line runs from the ring to the path, round the corner, to the marker")
deepStrictEqual(ringPoint, reportPosition, "the line starts at the ring")
isNear({position: joinPoint, expected: at({east: 400}), message: "the line joins the path where the report projects"})
isNear({position: cornerPoint, expected: at({east: CORNER_METERS}), message: "the line turns the corner"})
isNear({position: markerPoint, expected: roundCorner.drawn.position, message: "the line ends at the marker"})

// A report ahead of the marker speeds it up, and the line runs back from
// the ring to the marker until it has.
const aheadReport = at({east: CORNER_METERS, north: 300})
const caught = trackedVehicle({tracked: roundCorner, marker: marker({position: aheadReport, seconds: 120}), path: street, atMs: msAt({seconds: 120})})
const caughtTie = reportTie(caught)
deepStrictEqual(caughtTie.kind, TieKind.tie, "a vehicle speeding up has a tie")
isNear({position: caughtTie.line[caughtTie.line.length - 1], expected: caught.drawn.position, message: "a backward line ends at the marker"})

// A stale vehicle, one with no path, and one gliding off its path have none.
const stale = trackedVehicle({tracked: null, marker: marker({position: reportPosition, seconds: 80, status: "stale"}), path: street, atMs: msAt({seconds: 80})})
const noPath = trackedVehicle({tracked: null, marker: marker({position: reportPosition, seconds: 80}), path: null, atMs: msAt({seconds: 80})})
const gliding = trackedVehicle({tracked: noPath, marker: marker({position: reportPosition, seconds: 80}), path: street, atMs: msAt({seconds: 81})})
const noneCases = [
  {name: "a stale vehicle", input: stale},
  {name: "a vehicle with no path", input: noPath},
  {name: "a vehicle gliding onto its path", input: gliding}
]

for (const {name, input} of noneCases) {
  deepStrictEqual(reportTie(input).kind, TieKind.none, `${name} has no tie`)
}

// Which vehicles show their ties: from zoom 15 every one in view, and below
// it none of them, with the selected one at any zoom, wherever it is.
const DECIDED_TIE_ZOOM_MIN = 15
deepStrictEqual(TIE_ZOOM_MIN, DECIDED_TIE_ZOOM_MIN, "every vehicle in view shows its tie from zoom 15")
const ZOOM_BELOW = 14.5
const ZOOM_ABOVE = 15.5
const ZOOM_PAST_MOTION = 17

const tiedCases = [
  {name: "at zoom 15", given: {inView: ["a", "b"], zoom: TIE_ZOOM_MIN, selectedId: null}, ids: ["a", "b"]},
  {name: "above zoom 15, with none selected", given: {inView: ["a", "b"], zoom: ZOOM_ABOVE, selectedId: null}, ids: ["a", "b"]},
  {name: "above zoom 15, with one selected in view", given: {inView: ["a", "b"], zoom: ZOOM_ABOVE, selectedId: "b"}, ids: ["a", "b"]},
  {name: "above zoom 15, with one selected out of view", given: {inView: ["a"], zoom: ZOOM_ABOVE, selectedId: "c"}, ids: ["a", "c"]},
  {name: "past the band of motion", given: {inView: ["a", "b"], zoom: ZOOM_PAST_MOTION, selectedId: null}, ids: ["a", "b"]},
  {name: "below zoom 15, with one selected", given: {inView: ["a", "b"], zoom: ZOOM_BELOW, selectedId: "b"}, ids: ["b"]},
  {name: "below zoom 15, with none selected", given: {inView: ["a", "b"], zoom: ZOOM_BELOW, selectedId: null}, ids: []}
]

for (const {name, given, ids} of tiedCases) {
  deepStrictEqual(tiedMarkerIds(given), ids, name)
}

// A line on the screen loses its last `trimPixels`, the part the marker
// covers, and a line no longer than that loses all of it.
const trimCases = [
  {name: "a straight line", points: [{x: 0, y: 0}, {x: 50, y: 0}], trimmed: [{x: 0, y: 0}, {x: 40, y: 0}]},
  {name: "a line whose last segment is shorter than the cut", points: [{x: 0, y: 0}, {x: 30, y: 0}, {x: 30, y: 6}], trimmed: [{x: 0, y: 0}, {x: 26, y: 0}]},
  {name: "a line under the marker", points: [{x: 0, y: 0}, {x: 6, y: 8}], trimmed: []},
  {name: "a line of one point", points: [{x: 0, y: 0}], trimmed: []}
]

for (const {name, points, trimmed} of trimCases) {
  deepStrictEqual(trimmedLine({points, trimPixels: TRIM_PIXELS}), trimmed, name)
}

// The ring is left out where the marker covers it.
const clearTie = screenTie({color: "#b91c1c", ring: {x: 0, y: 0}, line: [{x: 0, y: 0}, {x: 60, y: 0}], reachPixels: TRIM_PIXELS})
deepStrictEqual(clearTie, {color: "#b91c1c", rings: [{x: 0, y: 0}], line: [{x: 0, y: 0}, {x: 50, y: 0}]}, "a ring clear of its marker")
const coveredTie = screenTie({color: "#b91c1c", ring: {x: 0, y: 0}, line: [{x: 0, y: 0}, {x: 9, y: 0}], reachPixels: TRIM_PIXELS})
deepStrictEqual(coveredTie, {color: "#b91c1c", rings: [], line: []}, "a ring under its marker")

// Every casing is one stroke, and each route color one dashed stroke and
// one ring stroke, in the order the colors come.
const strokes = tieStrokes([
  {color: "#b91c1c", rings: [{x: 0, y: 0}], line: [{x: 0, y: 0}, {x: 50, y: 0}]},
  {color: "#1d4ed8", rings: [], line: []},
  {color: "#b91c1c", rings: [{x: 9, y: 9}], line: [{x: 9, y: 9}, {x: 30, y: 9}]}
])
deepStrictEqual(strokes, {
  lines: [[{x: 0, y: 0}, {x: 50, y: 0}], [{x: 9, y: 9}, {x: 30, y: 9}]],
  rings: [{x: 0, y: 0}, {x: 9, y: 9}],
  colors: [{color: "#b91c1c", lines: [[{x: 0, y: 0}, {x: 50, y: 0}], [{x: 9, y: 9}, {x: 30, y: 9}]], rings: [{x: 0, y: 0}, {x: 9, y: 9}]}]
}, "ties batched by color")

// The ties are drawn again once their interval has passed since the last
// draw, and at every draw for an interval of none.
const dueCases = [
  {name: "before the interval", given: {drawnAtMs: 1000, nowMs: 1500, intervalMs: INTERVAL_MS}, isDue: false},
  {name: "at the interval", given: {drawnAtMs: 1000, nowMs: 2000, intervalMs: INTERVAL_MS}, isDue: true},
  {name: "never drawn", given: {drawnAtMs: null, nowMs: 1500, intervalMs: INTERVAL_MS}, isDue: true},
  {name: "an interval of none", given: {drawnAtMs: 1000, nowMs: 1001, intervalMs: 0}, isDue: true}
]

for (const {name, given, isDue} of dueCases) {
  deepStrictEqual(isTieRedrawDue(given), isDue, name)
}

throws(negativeTrim, AssertionError, "a negative cut")

// The casing edges every ring and line, so whatever the route's color each
// stands at 3:1 or more against the land, WCAG 2.2 1.4.11. The light land
// colors are the commonest of the light basemap downtown at zoom 14 and 16,
// sampled from screenshots; the dark ones are the vendored dark flavor's
// earth, buildings, background, minor roads, and water.
// https://www.w3.org/TR/WCAG22/#non-text-contrast — checked 2026-11-10
const landColors = new Map([
  [Theme.light, ["#e2dfda", "#d7d6d3", "#d2d1d0"]],
  [Theme.dark, ["#1f1f1f", "#111111", "#34373d", "#3d3d3d", "#31353f"]]
])

for (const [theme, lands] of landColors) {
  const casing = mapColors(theme).routeCasing.color

  for (const land of lands) {
    const ratio = contrastRatio({foreground: casing, background: land})
    ok(ratio >= NON_TEXT_CONTRAST_MIN, `the ${theme} casing ${casing} on ${land} is ${ratio}:1`)
  }
}

// A dot covers a tie to the outside of its stroke, and a glyph to its edge.
deepStrictEqual(markerCoverPixels(MarkerKind.round), ROUND_COVER_PIXELS, "a dot's cover")
deepStrictEqual(markerCoverPixels(MarkerKind.glyph), GLYPH_COVER_PIXELS, "a glyph's cover")

function negativeTrim() {
  trimmedLine({points: [{x: 0, y: 0}, {x: 1, y: 0}], trimPixels: -1})
}

console.log("report tie check passed")
