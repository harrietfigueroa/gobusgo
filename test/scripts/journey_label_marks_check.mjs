// Checks the pure rules of the marks behind the chosen journey's map
// labels: the geometry of the arrival label's pill image, whose corners
// stay round as it stretches to the text, and whether the layer that keeps
// the labels clear of the stops' signs is drawn. Run it with
// `node test/scripts/journey_label_marks_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {BlockerVisibility, PILL_IMAGE_SIZE_PIXELS, pillImageSpec, stopBlockerVisibility} from "../../assets/js/journey_label_marks.js"
import {contrastRatio} from "../../assets/js/math/color_contrast.js"
import {Theme, mapColors} from "../../assets/js/theme.js"

const TEXT_CONTRAST_MIN = 4.5
const PIXEL_RATIOS = [1, 2, 3]

// MapLibre reads the stretch and content areas in the image's own pixels,
// so a pill drawn at a pixel ratio of 2 names areas twice as far out.
for (const pixelRatio of PIXEL_RATIOS) {
  const spec = pillImageSpec({pixelRatio})
  const side = PILL_IMAGE_SIZE_PIXELS * pixelRatio
  const corner = spec.radiusPixels * pixelRatio

  // The corners are the part of the image that does not stretch.
  deepStrictEqual(spec.stretchX, [[corner, side - corner]], `the pill stretches between its corners across at ratio ${pixelRatio}`)
  deepStrictEqual(spec.stretchY, [[corner, side - corner]], `the pill stretches between its corners down at ratio ${pixelRatio}`)

  // The text stands in the stretched middle.
  deepStrictEqual(spec.content, [corner, corner, side - corner, side - corner], `the text stands in the stretched middle at ratio ${pixelRatio}`)
  ok(corner * 2 <= side, `the corners fit in the image at ratio ${pixelRatio}`)
}

// The padding is in CSS pixels, whatever the ratio.
const spec = pillImageSpec({pixelRatio: 2})
deepStrictEqual(spec.textFitPaddingPixels.length, 4, "the padding names top, right, bottom, and left")
ok(spec.textFitPaddingPixels.every((padding) => padding > 0), "the pill pads the text on every side")

// The sideways padding is the gap that sets a pill apart from a text
// selection, which hugs its glyphs.
ok(spec.textFitPaddingPixels[1] >= 4, "the pill pads the text sideways by at least 4 pixels")
deepStrictEqual(spec.textFitPaddingPixels, pillImageSpec({pixelRatio: 1}).textFitPaddingPixels, "the padding does not move with the ratio")

deepStrictEqual(stopBlockerVisibility(true), BlockerVisibility.visible, "the stops' signs block a label while a journey is chosen")
deepStrictEqual(stopBlockerVisibility(false), BlockerVisibility.none, "the stops' signs block nothing without a journey")

// The pill is drawn in the label ink with the label paper for its text.
for (const theme of [Theme.light, Theme.dark]) {
  const colors = mapColors(theme)
  const ratio = contrastRatio({foreground: colors.badgePaper, background: colors.badgeInk})
  ok(ratio >= TEXT_CONTRAST_MIN, `the pill's text reaches ${TEXT_CONTRAST_MIN}:1 in the ${theme} theme, got ${ratio}`)
}

console.log("journey label marks check passed")
