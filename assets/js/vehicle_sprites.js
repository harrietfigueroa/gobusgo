// The bitmaps the canvas over the map stamps its vehicles with: each dot in
// one color, opacity, and outline, each bus glyph, chevron, and route badge
// in one status, color, and theme, and each status badge in one theme's
// colors, drawn once onto a canvas of its own at the device's pixel ratio
// and sized to what it holds.
// A frame then copies each bitmap with `drawImage` where it stood drawing
// the same paths and text again.
// https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API/Tutorial/Optimizing_canvas — checked 2026-11-09

import {assertCondition} from "./core/assert.js"
import {drawStatusBadge, MARK_SIZE_PIXELS} from "./status_badges"
import {
  BADGE_HEIGHT_PIXELS,
  CHEVRON_SIZE_PIXELS,
  GLYPH_IMAGE_SIZE_PIXELS,
  MARKER_RADIUS_PIXELS,
  MARKER_STROKE_WIDTH_PIXELS,
  badgeWidth,
  drawBusGlyph,
  drawChevron,
  drawRouteBadge,
  drawRoundMarker
} from "./vehicle_marker_shapes"

// The most bitmaps held at once: a page draws one per route color and status
// it shows, and one badge per route name, so a full cache is emptied and
// refilled.
const SPRITE_COUNT_MAX = 512
const HALVING_DIVISOR = 2
const ROUND_SIZE_PIXELS = Math.ceil((MARKER_RADIUS_PIXELS + MARKER_STROKE_WIDTH_PIXELS) * HALVING_DIVISOR)
const KEY_SEPARATOR = "|"

function spriteCanvas({width, height, ratio}) {
  const canvas = document.createElement("canvas")
  canvas.width = Math.ceil(width * ratio)
  canvas.height = Math.ceil(height * ratio)
  const context = canvas.getContext("2d")
  context.scale(ratio, ratio)
  return canvas
}

/**
 * A bounded cache of bitmaps at one pixel ratio. Each bitmap comes back as
 * `{image, width, height}`, its size in CSS pixels, with a dot's, a glyph's,
 * and a chevron's center at the middle of its image, and a badge's corner
 * at its top left.
 */
export class SpriteCache {
  constructor() {
    this.sprites = new Map()
    this.ratio = 0
  }

  // A cache at another pixel ratio, or full, starts again empty.
  prepare(ratio) {
    assertCondition(ratio > 0, `a pixel ratio is above zero, got: ${ratio}`)
    const isFull = this.sprites.size >= SPRITE_COUNT_MAX
    const isOtherRatio = ratio !== this.ratio
    const isStale = isFull || isOtherRatio

    if (isStale) {
      this.sprites = new Map()
      this.ratio = ratio
    }
  }

  clear() {
    this.sprites = new Map()
  }

  cached({key, make}) {
    const sprite = this.sprites.get(key)

    if (sprite !== undefined) {
      return sprite
    }

    const made = make()
    this.sprites.set(key, made)
    return made
  }

  dot({color, opacity, strokeColor, strokeOpacity}) {
    const key = ["dot", color, opacity, strokeColor, strokeOpacity].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const size = ROUND_SIZE_PIXELS
        const image = spriteCanvas({width: size, height: size, ratio: this.ratio})
        const center = size / HALVING_DIVISOR
        drawRoundMarker(image, {x: center, y: center, color, fillOpacity: opacity, strokeColor, strokeOpacity})
        return {image, width: size, height: size}
      }
    })
  }

  // `style` is a `glyphStyle`, which names every color the glyph is drawn in.
  glyph({style}) {
    const key = ["glyph", style.fill, style.outline, style.outlineKind, style.ink].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const size = GLYPH_IMAGE_SIZE_PIXELS
        const image = spriteCanvas({width: size, height: size, ratio: this.ratio})
        const center = size / HALVING_DIVISOR
        drawBusGlyph(image, {x: center, y: center, style})
        return {image, width: size, height: size}
      }
    })
  }

  chevron({color, halo}) {
    const key = ["chevron", color, halo].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const image = spriteCanvas({width: CHEVRON_SIZE_PIXELS, height: CHEVRON_SIZE_PIXELS, ratio: this.ratio})
        drawChevron(image, {color, halo})
        return {image, width: CHEVRON_SIZE_PIXELS, height: CHEVRON_SIZE_PIXELS}
      }
    })
  }

  // `badge` is a `routeBadgeStyle`; `measure` is a context whose font is
  // `BADGE_FONT`, which gives the text's width.
  routeBadge({badge, measure}) {
    const key = ["route-badge", badge.text, badge.mark, badge.fill, badge.ink, badge.border].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const width = badgeWidth({badge, measure: (text) => measure.measureText(text).width})
        const image = spriteCanvas({width, height: BADGE_HEIGHT_PIXELS, ratio: this.ratio})
        drawRouteBadge(image, {badge, width})
        return {image, width, height: BADGE_HEIGHT_PIXELS}
      }
    })
  }

  badge({badge, ink, paper}) {
    const key = ["badge", badge, ink, paper].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const image = spriteCanvas({width: MARK_SIZE_PIXELS, height: MARK_SIZE_PIXELS, ratio: this.ratio})
        drawStatusBadge(image, {badge, ink, paper, x: 0, y: 0})
        return {image, width: MARK_SIZE_PIXELS, height: MARK_SIZE_PIXELS}
      }
    })
  }

}
