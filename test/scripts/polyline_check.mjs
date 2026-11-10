// Checks the polyline module against cases written out by hand on a plane
// in meters: the nearest point of a line beside a segment's middle, before
// its start, past its end, at a corner, at or past a minimum distance along
// it, and on a segment of no length, the segment that holds a distance
// along a line, before its start, at a point, inside a segment, and past
// its end, and the points of a line between two distances along it. Run it
// with `node test/scripts/polyline_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, strictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {nearestAlong, pointsBetween, segmentIndexAt} from "../../assets/js/math/polyline.js"

// An L-shaped line: 100 m east, then 100 m north.
const LINE = {
  xs: new Float64Array([0, 100, 100]),
  ys: new Float64Array([0, 0, 100]),
  cumulative: new Float64Array([0, 100, 200])
}

const nearestCases = [
  {name: "beside the first segment's middle", x: 50, y: -30, alongMin: 0, nearest: {offset: 30, along: 50}},
  {name: "before the start", x: -30, y: -40, alongMin: 0, nearest: {offset: 50, along: 0}},
  {name: "past the end", x: 100, y: 130, alongMin: 0, nearest: {offset: 30, along: 200}},
  {name: "outside the corner", x: 130, y: -40, alongMin: 0, nearest: {offset: 50, along: 100}},
  {name: "on the second segment", x: 100, y: 25, alongMin: 0, nearest: {offset: 0, along: 125}},
  {name: "beside the first segment, at or past 150 m", x: 50, y: -30, alongMin: 150, nearest: {offset: Number.POSITIVE_INFINITY, along: 150}},
  {name: "nearer the first segment, from the start", x: 90, y: 5, alongMin: 0, nearest: {offset: 5, along: 90}},
  {name: "nearer the first segment, at or past 95 m", x: 90, y: 5, alongMin: 95, nearest: {offset: 10, along: 105}}
]

for (const {name, x, y, alongMin, nearest} of nearestCases) {
  deepStrictEqual(nearestAlong({...LINE, x, y, alongMin}), nearest, name)
}

deepStrictEqual(
  nearestAlong({xs: new Float64Array([0, 0]), ys: new Float64Array([0, 0]), cumulative: new Float64Array([0, 0]), x: 3, y: 4, alongMin: 0}),
  {offset: 5, along: 0},
  "a segment of no length"
)

deepStrictEqual(
  nearestAlong({...LINE, x: 0, y: 0, alongMin: 500}),
  {offset: Number.POSITIVE_INFINITY, along: 500},
  "no point at or past the minimum"
)

throws(nearestOnShortLine, AssertionError, "a line short of y coordinates")

function nearestOnShortLine() {
  nearestAlong({xs: new Float64Array([0, 1]), ys: new Float64Array([0]), cumulative: new Float64Array([0, 1]), x: 0, y: 0, alongMin: 0})
}

// A line of four points 0, 100, 250, and 400 m along it.
const distancesAlong = {first: 0, second: 100, third: 250, fourth: 400}
const CUMULATIVE = Float64Array.of(distancesAlong.first, distancesAlong.second, distancesAlong.third, distancesAlong.fourth)

const segmentCases = [
  {name: "before the start", along: -5, index: 0},
  {name: "at the start", along: 0, index: 0},
  {name: "inside the first segment", along: 50, index: 0},
  {name: "at the second point", along: 100, index: 1},
  {name: "inside the last segment", along: 300, index: 2},
  {name: "at the end", along: 400, index: 2},
  {name: "past the end", along: 900, index: 2}
]

for (const {name, along, index} of segmentCases) {
  strictEqual(segmentIndexAt({cumulative: CUMULATIVE, along}), index, name)
}

throws(segmentOfOnePoint, AssertionError, "a line of one point")

function segmentOfOnePoint() {
  segmentIndexAt({cumulative: [0], along: 0})
}

function pairOf({x, y}) {
  return [x, y]
}

// The L-shaped line's points, their coordinates interleaved.
const L_COORDINATES = Float64Array.of(0, 0, 100, 0, 100, 100)

const betweenCases = [
  {name: "inside one segment", from: 20, to: 60, points: [{x: 20, y: 0}, {x: 60, y: 0}]},
  {name: "across the corner", from: 50, to: 150, points: [{x: 50, y: 0}, {x: 100, y: 0}, {x: 100, y: 50}]},
  {name: "from a point to the end", from: 100, to: 200, points: [{x: 100, y: 0}, {x: 100, y: 100}]},
  {name: "the whole line", from: 0, to: 200, points: [{x: 0, y: 0}, {x: 100, y: 0}, {x: 100, y: 100}]},
  {name: "one distance", from: 150, to: 150, points: [{x: 100, y: 50}, {x: 100, y: 50}]},
  {name: "outside the line, clamped to its ends", from: -40, to: 260, points: [{x: 0, y: 0}, {x: 100, y: 0}, {x: 100, y: 100}]}
]

for (const {name, from, to, points} of betweenCases) {
  const expected = Array.from(points, pairOf)
  deepStrictEqual(pointsBetween({coordinates: L_COORDINATES, cumulative: LINE.cumulative, from, to}), expected, name)
}

throws(reversedDistances, AssertionError, "a start past the end")
throws(halfPoint, AssertionError, "coordinates that end inside a point")

function reversedDistances() {
  pointsBetween({coordinates: L_COORDINATES, cumulative: LINE.cumulative, from: 150, to: 50})
}

function halfPoint() {
  pointsBetween({coordinates: Float64Array.of(0, 0, 100, 0, 100), cumulative: LINE.cumulative, from: 0, to: 50})
}

console.log("polyline: every case holds")
