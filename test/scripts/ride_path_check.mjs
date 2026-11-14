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
const CORNER_INDEX = 2
const LAST_INDEX = 3
const STOP_COUNT_TWO = 2
const NORTH_LAT = 47.6
const FAR_NORTH_LAT = 47.61
const WEST_LON = -122.34
const MIDDLE_LON = -122.335
const CENTER_LON = -122.33
const EAST_LON = -122.32
const FAR_LAT = 47.7
const FAR_LON = -122.2
const BAD_SEQUENCE = 0.5

// A road east along 47.60 and then north along -122.32: four points.
const POINTS = Object.freeze([[WEST_LON, NORTH_LAT], [CENTER_LON, NORTH_LAT], [EAST_LON, NORTH_LAT], [EAST_LON, FAR_NORTH_LAT]])
const FIRST_SEGMENT_MIDDLE = [MIDDLE_LON, NORTH_LAT]

function cumulativeOf(points) {
  const cumulative = [0]

  for (let index = 1; index < points.length; index++) {
    cumulative.push(cumulative[index - 1] + distanceMeters(points[index - 1], points[index]))
  }

  return cumulative
}

const CUMULATIVE = cumulativeOf(POINTS)
const PATH_LENGTH_METERS = CUMULATIVE[LAST_INDEX]
const MIDDLE_METERS = CUMULATIVE[1] / HALF

function stopAt(meters) {
  return {distanceMeters: meters, arrivalSeconds: 0, departureSeconds: 0}
}

// Four stops: the first point, the middle of the first segment, the corner,
// and the last point.
const PATH = Object.freeze({
  points: POINTS,
  stops: Object.freeze([stopAt(0), stopAt(MIDDLE_METERS), stopAt(CUMULATIVE[CORNER_INDEX]), stopAt(PATH_LENGTH_METERS)])
})

function position([lon, lat]) {
  return {lon, lat}
}

const STOP_POSITIONS = Object.freeze({
  first: position(POINTS[0]),
  middle: position(FIRST_SEGMENT_MIDDLE),
  corner: position(POINTS[CORNER_INDEX]),
  last: position(POINTS[LAST_INDEX])
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

const wholeLeg = legOf({boardIndex: 0, alightIndex: LAST_INDEX})
const wholeLine = lineOf({leg: wholeLeg})
deepStrictEqual(sliceOf(wholeLine), [...POINTS], "a ride of the whole path follows every point")

const middleLeg = legOf({boardIndex: 1, alightIndex: LAST_INDEX})
const middleLine = lineOf({leg: middleLeg})
deepStrictEqual(
  sliceOf(middleLine),
  [FIRST_SEGMENT_MIDDLE, POINTS[1], POINTS[CORNER_INDEX], POINTS[LAST_INDEX]],
  "a ride from the middle of a segment starts at the interpolated cut and leaves out the points before it"
)

const cornerLeg = legOf({boardIndex: 0, alightIndex: CORNER_INDEX})
const cornerLine = lineOf({leg: cornerLeg})
deepStrictEqual(sliceOf(cornerLine), [POINTS[0], POINTS[1], POINTS[CORNER_INDEX]], "a ride that ends at a corner stops at it")

const oneHop = legOf({boardIndex: 0, alightIndex: 1})
const oneHopLine = lineOf({leg: oneHop})
deepStrictEqual(sliceOf(oneHopLine), [POINTS[0], FIRST_SEGMENT_MIDDLE], "a ride of one hop has its two cut points")

const mismatched = {...wholeLeg, stopIds: ["first", "last"]}
const mismatchedLine = lineOf({leg: mismatched})
deepStrictEqual(reasonOf(mismatchedLine), FallbackReason.stopCountMismatch, "a stop count that is not the leg's hops")

const shortPath = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(0), stopAt(MIDDLE_METERS)])})
const shortLine = lineOf({path: shortPath, leg: wholeLeg})
deepStrictEqual(reasonOf(shortLine), FallbackReason.indexOutOfRange, "a pattern shorter than the leg")

const sameDistance = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(MIDDLE_METERS), stopAt(MIDDLE_METERS)])})
const sameDistanceLine = lineOf({path: sameDistance, leg: oneHop})
deepStrictEqual(reasonOf(sameDistanceLine), FallbackReason.noDistance, "two stops at one distance")

const lastHop = {...oneHop, toStopId: "last"}
const pastEnd = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(0), stopAt(PATH_LENGTH_METERS + DISTANCE_SLACK_METERS * HALF)])})
const pastEndLine = lineOf({path: pastEnd, leg: lastHop})
deepStrictEqual(reasonOf(pastEndLine), FallbackReason.distanceOutOfRange, "a distance past the path's end")

const withinSlack = Object.freeze({points: POINTS, stops: Object.freeze([stopAt(0), stopAt(PATH_LENGTH_METERS + DISTANCE_SLACK_METERS / HALF)])})
const clampedLine = lineOf({path: withinSlack, leg: lastHop})
const clamped = sliceOf(clampedLine)
deepStrictEqual(clamped[clamped.length - 1], POINTS[LAST_INDEX], "a distance within the slack ends at the path's end")

const onePoint = Object.freeze({points: Object.freeze([POINTS[0]]), stops: PATH.stops})
const onePointLine = lineOf({path: onePoint, leg: wholeLeg})
deepStrictEqual(reasonOf(onePointLine), FallbackReason.pathTooShort, "a path of one point")

// A stop far from where its distance cuts the path means the pattern is not
// the trip's: the ride keeps its stops.
const farAlighting = {...STOP_POSITIONS, last: position([FAR_LON, FAR_LAT])}
const farAlightingLine = lineOf({leg: wholeLeg, stopPositions: farAlighting})
deepStrictEqual(reasonOf(farAlightingLine), FallbackReason.detached, "an alighting stop far from the cut")

const farBoarding = {...STOP_POSITIONS, first: position([FAR_LON, FAR_LAT])}
const farBoardingLine = lineOf({leg: wholeLeg, stopPositions: farBoarding})
deepStrictEqual(reasonOf(farBoardingLine), FallbackReason.detached, "a boarding stop far from the cut")

const {last: omitted, ...withoutLast} = STOP_POSITIONS
deepStrictEqual(omitted, STOP_POSITIONS.last, "the position left out is the last stop's")
const unplacedLine = lineOf({leg: wholeLeg, stopPositions: withoutLast})
deepStrictEqual(reasonOf(unplacedLine), FallbackReason.unplaced, "an alighting stop with no position")
deepStrictEqual(STOP_COUNT_TWO, oneHop.stopIds.length, "a one-hop leg names two stops")

function unsequenced() {
  const {alightSequence, ...rest} = wholeLeg
  deepStrictEqual(alightSequence, CORNER_INDEX, "the sequence left out is the last hop's")
  return lineOf({leg: rest})
}

throws(unsequenced, AssertionError, "a leg with no alighting sequence")

function fractionalSequence() {
  return lineOf({leg: {...wholeLeg, boardSequence: BAD_SEQUENCE}})
}

throws(fractionalSequence, AssertionError, "a fractional sequence")

console.log("ride path: every case holds")
