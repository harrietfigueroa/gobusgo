// Checks the line a ride is drawn along: a trip's path cut from its
// boarding stop's distance along it to its alighting stop's, with the cut
// points interpolated, over paths written out by hand. It covers a whole
// path, a ride from the middle of a segment, a ride that ends at a corner,
// and each reason a ride keeps the line through its stops: a leg whose stop
// count is not the hops it names, a pattern shorter than the leg, two stops
// at one distance, a distance past the path's end, a path of one point, a
// stop far from the path's cut, and a stop with no position. Run it with
// `node test/scripts/ride_path_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {distanceMeters} from "../../assets/js/core/math/geodesy.js"
import {DISTANCE_SLACK_METERS, FallbackReason, RideLineKind, ridePathLine} from "../../assets/js/core/ride_path.js"

const HALF = 2
const COORDINATE_DECIMALS = 1000000

// A road east along 47.60 and then north along -122.32: four points.
const POINTS = Object.freeze([[-122.34, 47.6], [-122.33, 47.6], [-122.32, 47.6], [-122.32, 47.61]])
const FIRST_SEGMENT_MIDDLE = [-122.335, 47.6]

function cumulativeOf(points) {
  const cumulative = [0]

  for (let index = 1; index < points.length; index++) {
    cumulative.push(cumulative[index - 1] + distanceMeters(points[index - 1], points[index]))
  }

  return cumulative
}

const CUMULATIVE = cumulativeOf(POINTS)
const PATH_LENGTH_METERS = CUMULATIVE[CUMULATIVE.length - 1]
const MIDDLE_METERS = CUMULATIVE[1] / HALF

function stopAt(meters) {
  return {distanceMeters: meters, arrivalSeconds: 0, departureSeconds: 0}
}

// Four stops: the first point, the middle of the first segment, the corner,
// and the last point.
const PATH = Object.freeze({
  points: POINTS,
  stops: Object.freeze([stopAt(0), stopAt(MIDDLE_METERS), stopAt(CUMULATIVE[2]), stopAt(PATH_LENGTH_METERS)])
})

function position([lon, lat]) {
  return {lon, lat}
}

const STOP_POSITIONS = Object.freeze({
  first: position(POINTS[0]),
  middle: position(FIRST_SEGMENT_MIDDLE),
  corner: position(POINTS[2]),
  last: position(POINTS[3])
})
const STOP_IDS_BY_INDEX = ["first", "middle", "corner", "last"]

// The leg that boards the pattern's stop `boardIndex` and leaves it at
// `alightIndex`, with the hops the router names.
function legOf({boardIndex, alightIndex}) {
  const stopIds = STOP_IDS_BY_INDEX.slice(boardIndex, alightIndex + 1)
  return {boardSequence: boardIndex, alightSequence: alightIndex - 1, stopIds, fromStopId: stopIds[0], toStopId: stopIds[stopIds.length - 1]}
}

function lineOf({path = PATH, leg, stopPositions = STOP_POSITIONS}) {
  return ridePathLine({path, leg, stopPositions})
}

function roundedCoordinate([lon, lat]) {
  return [Math.round(lon * COORDINATE_DECIMALS) / COORDINATE_DECIMALS, Math.round(lat * COORDINATE_DECIMALS) / COORDINATE_DECIMALS]
}

function sliceOf(line) {
  deepStrictEqual(line.kind, RideLineKind.slice, "the ride follows the path")
  return Array.from(line.coordinates, roundedCoordinate)
}

function reasonOf(line) {
  deepStrictEqual(line.kind, RideLineKind.fallback, "the ride keeps the line through its stops")
  return line.reason
}

deepStrictEqual(sliceOf(lineOf({leg: legOf({boardIndex: 0, alightIndex: 3})})), [...POINTS], "a ride of the whole path follows every point")
deepStrictEqual(
  sliceOf(lineOf({leg: legOf({boardIndex: 1, alightIndex: 3})})),
  [FIRST_SEGMENT_MIDDLE, POINTS[1], POINTS[2], POINTS[3]],
  "a ride from the middle of a segment starts at the interpolated cut and leaves out the points before it"
)
deepStrictEqual(sliceOf(lineOf({leg: legOf({boardIndex: 0, alightIndex: 2})})), [POINTS[0], POINTS[1], POINTS[2]], "a ride that ends at a corner stops at it")
deepStrictEqual(sliceOf(lineOf({leg: legOf({boardIndex: 0, alightIndex: 1})})), [POINTS[0], FIRST_SEGMENT_MIDDLE], "a ride of one hop has its two cut points")

const mismatched = {...legOf({boardIndex: 0, alightIndex: 3}), stopIds: ["first", "last"]}
deepStrictEqual(reasonOf(lineOf({leg: mismatched})), FallbackReason.stopCountMismatch, "a stop count that is not the leg's hops")

const shortPath = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(0), stopAt(MIDDLE_METERS)])})
deepStrictEqual(reasonOf(lineOf({path: shortPath, leg: legOf({boardIndex: 0, alightIndex: 3})})), FallbackReason.indexOutOfRange, "a pattern shorter than the leg")

const oneHop = legOf({boardIndex: 0, alightIndex: 1})
const sameDistance = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(MIDDLE_METERS), stopAt(MIDDLE_METERS)])})
deepStrictEqual(reasonOf(lineOf({path: sameDistance, leg: oneHop})), FallbackReason.noDistance, "two stops at one distance")

const pastEnd = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(0), stopAt(PATH_LENGTH_METERS + DISTANCE_SLACK_METERS * HALF)])})
const lastHop = {...oneHop, toStopId: "last"}
deepStrictEqual(reasonOf(lineOf({path: pastEnd, leg: lastHop})), FallbackReason.distanceOutOfRange, "a distance past the path's end")

const withinSlack = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(0), stopAt(PATH_LENGTH_METERS + DISTANCE_SLACK_METERS / HALF)])})
const clamped = sliceOf(lineOf({path: withinSlack, leg: lastHop}))
deepStrictEqual(clamped[clamped.length - 1], POINTS[3], "a distance within the slack ends at the path's end")

const onePoint = Object.freeze({points: Object.freeze([POINTS[0]]), stops: PATH.stops})
deepStrictEqual(reasonOf(lineOf({path: onePoint, leg: legOf({boardIndex: 0, alightIndex: 3})})), FallbackReason.pathTooShort, "a path of one point")

// A stop far from where its distance cuts the path means the pattern is not
// the trip's: the ride keeps its stops.
const farAlighting = {...STOP_POSITIONS, last: position([-122.2, 47.7])}
deepStrictEqual(reasonOf(lineOf({leg: legOf({boardIndex: 0, alightIndex: 3}), stopPositions: farAlighting})), FallbackReason.detached, "an alighting stop far from the cut")
const farBoarding = {...STOP_POSITIONS, first: position([-122.2, 47.7])}
deepStrictEqual(reasonOf(lineOf({leg: legOf({boardIndex: 0, alightIndex: 3}), stopPositions: farBoarding})), FallbackReason.detached, "a boarding stop far from the cut")

function withoutLast({first, middle, corner}) {
  return {first, middle, corner}
}

deepStrictEqual(reasonOf(lineOf({leg: legOf({boardIndex: 0, alightIndex: 3}), stopPositions: withoutLast(STOP_POSITIONS)})), FallbackReason.unplaced, "an alighting stop with no position")

function unsequenced() {
  const {alightSequence, ...rest} = legOf({boardIndex: 0, alightIndex: 3})
  deepStrictEqual(alightSequence, 2, "the sequence left out is the last hop's")
  return lineOf({leg: rest})
}

throws(unsequenced, AssertionError, "a leg with no alighting sequence")

function fractionalSequence() {
  return lineOf({leg: {...legOf({boardIndex: 0, alightIndex: 3}), boardSequence: 0.5}})
}

throws(fractionalSequence, AssertionError, "a fractional sequence")

console.log("ride path: every case holds")
