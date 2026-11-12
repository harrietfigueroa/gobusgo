// How the canvas over the map draws the ties between vehicles' last
// reports and their markers, as pure functions of points on the screen:
// where a line stops short of its marker, whether its ring shows, which
// strokes draw every tie, and when the ties are drawn again. Every length
// is in CSS pixels, and nothing here reads the document or the map.

import {assertCondition, unreachable} from "./core/assert.js"
import {lerp} from "./core/math/interpolation.js"
import {GLYPH_RADIUS_PIXELS, MARKER_RADIUS_PIXELS, MARKER_STROKE_WIDTH_PIXELS} from "./vehicle_marker_shapes.js"
import {MarkerKind} from "./vehicle_overlay_layout.js"

/** The radius of the ring at a last report, to the middle of its stroke. */
export const RING_RADIUS_PIXELS = 5

/** The width of the ring's stroke in its route's color. */
export const RING_WIDTH_PIXELS = 2

/** The width of the casing under the ring's stroke, which shows on both sides of it. */
export const RING_CASING_WIDTH_PIXELS = 5

/** The width of the dashed line in its route's color. */
export const LINE_WIDTH_PIXELS = 3

/** The width of the casing under the dashed line, which shows in its gaps and on both sides of it. */
export const LINE_CASING_WIDTH_PIXELS = 6

const LINE_DASH_LENGTH_PIXELS = 4
const LINE_GAP_LENGTH_PIXELS = 3

/** The dash and the gap of the line in its route's color. */
export const LINE_DASH_PIXELS = Object.freeze([LINE_DASH_LENGTH_PIXELS, LINE_GAP_LENGTH_PIXELS])

/** How long a moving vehicle's tie is kept between draws while the camera is still. */
export const TIE_REDRAW_INTERVAL_MS = 1000

const HALF = 2
const RING_REACH_PIXELS = RING_RADIUS_PIXELS + RING_CASING_WIDTH_PIXELS / HALF

function isPoint({x, y}) {
  const isFiniteX = Number.isFinite(x)
  return isFiniteX && Number.isFinite(y)
}

/**
 * How far from its center a marker of `kind`, a `MarkerKind`, covers a tie:
 * a dot to the outside of its stroke, and a glyph to its edge.
 */
export function markerCoverPixels(kind) {
  switch (kind) {
    case MarkerKind.round:
      return MARKER_RADIUS_PIXELS + MARKER_STROKE_WIDTH_PIXELS
    case MarkerKind.glyph:
      return GLYPH_RADIUS_PIXELS
    default:
      return unreachable(kind, "a marker is a dot or a glyph")
  }
}

/**
 * `points`, a line on the screen ending at its marker, less the last
 * `trimPixels` of it, the part the marker covers; no points where the line
 * is not longer than that.
 */
export function trimmedLine({points, trimPixels}) {
  assertCondition(trimPixels >= 0, `a cut is not negative, got: ${trimPixels}`)
  let remaining = trimPixels

  for (let index = points.length - 1; index > 0; index--) {
    const target = points[index]
    const source = points[index - 1]
    assertCondition(isPoint(target), `a line's point is finite, got: ${target.x}, ${target.y}`)
    const segmentPixels = Math.hypot(target.x - source.x, target.y - source.y)

    if (segmentPixels > remaining) {
      const fraction = 1 - remaining / segmentPixels
      const end = {x: lerp({from: source.x, to: target.x, fraction}), y: lerp({from: source.y, to: target.y, fraction})}
      const kept = points.slice(0, index)
      kept.push(end)
      return kept
    }

    remaining -= segmentPixels
  }

  return []
}

/**
 * The tie of a vehicle in `color` as the canvas draws it: `line`, from its
 * ring at `ring` to its marker, less the `reachPixels` the marker covers,
 * and its ring where the marker leaves it clear, as a list of one ring or
 * none.
 */
export function screenTie({color, ring, line, reachPixels}) {
  assertCondition(isPoint(ring), `a ring stands at a finite point, got: ${ring.x}, ${ring.y}`)
  assertCondition(line.length > 0, "a tie's line ends at its marker")
  const marker = line[line.length - 1]
  const ringPixels = Math.hypot(marker.x - ring.x, marker.y - ring.y)
  const rings = []

  if (ringPixels > reachPixels + RING_REACH_PIXELS) {
    rings.push(ring)
  }

  return {color, rings, line: trimmedLine({points: line, trimPixels: reachPixels})}
}

/**
 * The strokes that draw `ties`, each from `screenTie`: every line's casing
 * in one stroke and every ring's in one, then per route color, in the order
 * the colors first come, one dashed stroke of its lines and one stroke of
 * its rings. A tie with no line and no ring draws nothing.
 */
export function tieStrokes(ties) {
  const lines = []
  const rings = []
  const byColor = new Map()

  for (const tie of ties) {
    const hasLine = tie.line.length > 1
    const hasRing = tie.rings.length > 0
    const isDrawn = hasLine || hasRing

    if (isDrawn) {
      if (!byColor.has(tie.color)) {
        byColor.set(tie.color, {color: tie.color, lines: [], rings: []})
      }

      const batch = byColor.get(tie.color)

      if (hasLine) {
        lines.push(tie.line)
        batch.lines.push(tie.line)
      }

      for (const ring of tie.rings) {
        rings.push(ring)
        batch.rings.push(ring)
      }
    }
  }

  return {lines, rings, colors: Array.from(byColor.values())}
}

/**
 * Whether the ties are drawn again at `nowMs`: once `intervalMs` has passed
 * since they were last drawn at `drawnAtMs`, null for never, and at every
 * draw for an interval of 0.
 */
export function isTieRedrawDue({drawnAtMs, nowMs, intervalMs}) {
  assertCondition(intervalMs >= 0, `an interval is not negative, got: ${intervalMs}`)

  if (drawnAtMs === null) {
    return true
  }

  return nowMs - drawnAtMs >= intervalMs
}
