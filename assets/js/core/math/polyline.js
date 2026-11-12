// Points on a polyline, in meters on a plane. Everything here is pure: a
// line is given as the coordinates of its points and the cumulative
// distance at each, in typed arrays, so a caller chooses the plane and how
// distances along it are measured.

import {assertOrdered} from "./checks.js"
import {lerp} from "./interpolation.js"

/** The index of a point's x coordinate in a line's interleaved coordinates. */
export const POINT_X = 0

/** The index of a point's y coordinate in a line's interleaved coordinates. */
export const POINT_Y = 1

/** The numbers a point takes in a line's interleaved coordinates. */
export const COORDINATES_PER_POINT = 2

// Halving a list of 2^53 points, more than any array holds, takes 53 steps.
const HALVING_STEP_COUNT_MAX = 53
const HALF = 2

/**
 * Where (`x`, `y`) projects onto the line `xs`, `ys`, with the cumulative
 * distances `cumulative`: of the points each segment holds nearest to it,
 * the nearest at least `alongMin` along the line, as its distance `along`
 * the line, a share of the segment's cumulative distances, and its distance
 * `offset` from (`x`, `y`). A segment of no length offers its first point.
 * With no such point, `offset` is Infinity and `along` is `alongMin`.
 */
export function nearestAlong({xs, ys, cumulative, x, y, alongMin}) {
  const pointCount = xs.length
  assertOrdered({low: HALF, high: pointCount, label: "polyline: the points of a line"})
  assertOrdered({low: pointCount, high: ys.length, label: "polyline: the y coordinates of a line"})
  assertOrdered({low: pointCount, high: cumulative.length, label: "polyline: the distances of a line"})
  let offsetBest = Infinity
  let alongBest = alongMin

  for (let index = 0; index + 1 < pointCount; index++) {
    const startAlong = cumulative[index]
    const endAlong = cumulative[index + 1]
    if (endAlong < alongMin) {
      continue
    }

    const sourceX = xs[index]
    const sourceY = ys[index]
    const deltaX = xs[index + 1] - sourceX
    const deltaY = ys[index + 1] - sourceY
    const squaredLength = deltaX * deltaX + deltaY * deltaY
    let fraction = 0
    if (squaredLength > 0) {
      const dot = (x - sourceX) * deltaX + (y - sourceY) * deltaY
      fraction = Math.min(1, Math.max(0, dot / squaredLength))
    }

    const along = lerp({from: startAlong, to: endAlong, fraction})
    const offset = Math.hypot(sourceX + fraction * deltaX - x, sourceY + fraction * deltaY - y)
    const isAfterMin = along >= alongMin
    const isNearer = offset < offsetBest
    const isBetter = isAfterMin && isNearer
    if (isBetter) {
      offsetBest = offset
      alongBest = along
    }
  }

  return {offset: offsetBest, along: alongBest}
}

/**
 * The index of the segment of a line whose cumulative distances are
 * `cumulative`, ascending from 0, that holds `along`: the last point at or
 * before it, and the second to last point for `along` at or past the end.
 * It halves the points, so its cost grows with the logarithm of their count.
 */
export function segmentIndexAt({cumulative, along}) {
  assertOrdered({low: HALF, high: cumulative.length, label: "polyline: the points of a line"})
  let low = 0
  let high = cumulative.length - 1

  for (let step = 0; high - low > 1; step++) {
    assertOrdered({low: step, high: HALVING_STEP_COUNT_MAX, label: "polyline: the halvings of a segment search"})
    const middle = Math.floor((low + high) / HALF)
    if (cumulative[middle] <= along) {
      low = middle
    } else {
      high = middle
    }
  }

  assertOrdered({low: high, high: low + 1, label: "polyline: the end of a segment"})
  return low
}

// The [x, y] point `along` the line, inside the segment that starts at
// `index`.
function pointInSegment({coordinates, cumulative, index, along}) {
  const segmentLength = cumulative[index + 1] - cumulative[index]
  let fraction = 0
  if (segmentLength > 0) {
    fraction = (along - cumulative[index]) / segmentLength
  }
  const source = index * COORDINATES_PER_POINT
  const target = source + COORDINATES_PER_POINT
  const x = lerp({from: coordinates[source + POINT_X], to: coordinates[target + POINT_X], fraction})
  const y = lerp({from: coordinates[source + POINT_Y], to: coordinates[target + POINT_Y], fraction})
  return [x, y]
}

/**
 * The points of the line `coordinates`, with the cumulative distances
 * `cumulative`, from `from` to `to` along it, as [x, y] pairs: the point at
 * `from`, every point of the line strictly between the two, and the point
 * at `to`. Each distance is brought inside the line's ends first.
 * `coordinates` interleaves the points' coordinates, `COORDINATES_PER_POINT`
 * per point, x at `POINT_X` and y at `POINT_Y`.
 */
export function pointsBetween({coordinates, cumulative, from, to}) {
  const pointCount = Math.floor(coordinates.length / COORDINATES_PER_POINT)
  assertOrdered({low: coordinates.length, high: pointCount * COORDINATES_PER_POINT, label: "polyline: the coordinates of whole points"})
  assertOrdered({low: HALF, high: pointCount, label: "polyline: the points of a line"})
  assertOrdered({low: pointCount, high: cumulative.length, label: "polyline: the distances of a line"})
  assertOrdered({low: from, high: to, label: "polyline: the distances between which points are taken"})
  const length = cumulative[pointCount - 1]
  const start = Math.min(length, Math.max(0, from))
  const end = Math.min(length, Math.max(0, to))
  const startIndex = segmentIndexAt({cumulative, along: start})
  const endIndex = segmentIndexAt({cumulative, along: end})
  const between = [pointInSegment({coordinates, cumulative, index: startIndex, along: start})]

  for (let index = startIndex + 1; index <= endIndex; index++) {
    const isAfterStart = cumulative[index] > start
    const isInside = isAfterStart && cumulative[index] < end
    if (isInside) {
      const offset = index * COORDINATES_PER_POINT
      between.push([coordinates[offset + POINT_X], coordinates[offset + POINT_Y]])
    }
  }

  between.push(pointInSegment({coordinates, cumulative, index: endIndex, along: end}))
  return between
}
