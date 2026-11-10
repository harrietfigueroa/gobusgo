// Checks the mark the map draws around the selected item, as pure functions
// of values written out by hand: the halo's and the ring's paint around an
// item of a fixed radius and around one whose radius steps with the zoom,
// and the radii a canvas draws the mark at. Run it with
// `node test/scripts/selection_mark_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {selectionHaloPaint, selectionHaloRadius, selectionRingPaint, selectionRingRadius} from "../../assets/js/selection_mark.js"

const GREEN = "#16a34a"
const DOT_RADIUS_PIXELS = 6
const GLYPH_RADIUS_PIXELS = 11
const GLYPH_ZOOM_MIN = 13
const STEPPED_RADIUS = Object.freeze(["step", ["zoom"], DOT_RADIUS_PIXELS, GLYPH_ZOOM_MIN, GLYPH_RADIUS_PIXELS])
// The mark's radii around a dot and around a glyph: the ring 4 px outside
// the marker, and the halo 4 px outside the ring.
const DOT_RING_RADIUS_PIXELS = 10
const DOT_HALO_RADIUS_PIXELS = 14
const GLYPH_RING_RADIUS_PIXELS = 15
const GLYPH_HALO_RADIUS_PIXELS = 19

const cases = [
  {
    name: "the halo around a stop's sign",
    paint: selectionHaloPaint(GLYPH_RADIUS_PIXELS),
    expected: {"circle-radius": 19, "circle-color": GREEN, "circle-opacity": 0.25}
  },
  {
    name: "the ring around a stop's sign",
    paint: selectionRingPaint(GLYPH_RADIUS_PIXELS),
    expected: {"circle-radius": 15, "circle-opacity": 0, "circle-stroke-color": GREEN, "circle-stroke-width": 3}
  },
  {
    name: "the halo around a vehicle, a dot then a glyph",
    paint: selectionHaloPaint(STEPPED_RADIUS),
    expected: {"circle-radius": ["step", ["zoom"], DOT_HALO_RADIUS_PIXELS, GLYPH_ZOOM_MIN, GLYPH_HALO_RADIUS_PIXELS], "circle-color": GREEN, "circle-opacity": 0.25}
  },
  {
    name: "the ring around a vehicle, a dot then a glyph",
    paint: selectionRingPaint(STEPPED_RADIUS),
    expected: {"circle-radius": ["step", ["zoom"], DOT_RING_RADIUS_PIXELS, GLYPH_ZOOM_MIN, GLYPH_RING_RADIUS_PIXELS], "circle-opacity": 0, "circle-stroke-color": GREEN, "circle-stroke-width": 3}
  },
  {name: "the ring a canvas draws around a glyph", paint: selectionRingRadius(GLYPH_RADIUS_PIXELS), expected: 15},
  {name: "the halo a canvas draws around a dot", paint: selectionHaloRadius(DOT_RADIUS_PIXELS), expected: 14}
]

for (const {name, paint, expected} of cases) {
  deepStrictEqual(paint, expected, name)
}

console.log(`selection mark: ${cases.length} cases hold`)
