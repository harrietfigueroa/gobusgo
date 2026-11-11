// The arrival label's pill image on the map, as pure functions: its
// geometry and the padding it shows around the text. Nothing here reads
// the document or the map, so the rules replay against values written by
// hand.

/** The side of the pill image's square, in CSS pixels. */
export const PILL_IMAGE_SIZE_PIXELS = 16

const PILL_RADIUS_PIXELS = 7
const PILL_PADDING_VERTICAL_PIXELS = 2
const PILL_PADDING_HORIZONTAL_PIXELS = 6

/**
 * How MapLibre stretches the pill image, drawn at `pixelRatio`, to the text
 * it holds: `stretchX` and `stretchY` leave each corner whole and `content`
 * is the stretched middle the text stands in, each in the image's own
 * pixels, which MapLibre reads without the ratio. `radiusPixels` is the
 * corner's radius and `textFitPaddingPixels` the pill shown around the
 * text, as top, right, bottom, and left, both in CSS pixels.
 * https://maplibre.org/maplibre-style-spec/layers/#icon-text-fit — checked 2026-11-11
 */
export function pillImageSpec({pixelRatio}) {
  const side = PILL_IMAGE_SIZE_PIXELS * pixelRatio
  const near = PILL_RADIUS_PIXELS * pixelRatio
  const far = side - near

  return {
    radiusPixels: PILL_RADIUS_PIXELS,
    stretchX: [[near, far]],
    stretchY: [[near, far]],
    content: [near, near, far, far],
    textFitPaddingPixels: [
      PILL_PADDING_VERTICAL_PIXELS,
      PILL_PADDING_HORIZONTAL_PIXELS,
      PILL_PADDING_VERTICAL_PIXELS,
      PILL_PADDING_HORIZONTAL_PIXELS
    ]
  }
}
