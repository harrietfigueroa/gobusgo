// The bitmaps the canvas over the map stamps its vehicles with: each marker
// shape in one color, opacity, and outline, each status badge in one theme's
// colors, and each route label in one theme's colors, drawn once onto a
// canvas of its own at the device's pixel ratio and sized to what it holds.
// A frame then copies each bitmap with `drawImage` where it stood drawing
// the same paths and text again.
// https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API/Tutorial/Optimizing_canvas — checked 2026-11-09

import {assertCondition} from "./assert.js"
import {drawStatusBadge, MARK_SIZE_PIXELS} from "./status_badges"
import {drawPointedMarker, drawRoundMarker, MARKER_RADIUS_PIXELS, MARKER_STROKE_WIDTH_PIXELS, POINTED_TIP_DISTANCE_PIXELS} from "./vehicle_marker_shapes"

/** The shapes a marker's bitmap is drawn in. */
export const SpriteShape = Object.freeze({round: "round", pointed: "pointed"})

// The most bitmaps held at once: a page draws one per route color and status
// it shows, and one per route name, so a full cache is emptied and refilled.
const SPRITE_COUNT_MAX = 512
const HALVING_DIVISOR = 2
const ROUND_SIZE_PIXELS = Math.ceil((MARKER_RADIUS_PIXELS + MARKER_STROKE_WIDTH_PIXELS) * HALVING_DIVISOR)
const POINTED_SIZE_PIXELS = Math.ceil((POINTED_TIP_DISTANCE_PIXELS + MARKER_STROKE_WIDTH_PIXELS) * HALVING_DIVISOR)
const LABEL_HALO_WIDTH_PIXELS = 3
const LABEL_PADDING_PIXELS = Math.ceil(LABEL_HALO_WIDTH_PIXELS / HALVING_DIVISOR)
const LABEL_LINE_HEIGHT_RATIO = 1.3
const KEY_SEPARATOR = "|"

function spriteCanvas({width, height, ratio}) {
  const canvas = document.createElement("canvas")
  canvas.width = Math.ceil(width * ratio)
  canvas.height = Math.ceil(height * ratio)
  const context = canvas.getContext("2d")
  context.scale(ratio, ratio)
  return canvas
}

function markerSize(shape) {
  if (shape === SpriteShape.pointed) {
    return POINTED_SIZE_PIXELS
  }

  return ROUND_SIZE_PIXELS
}

/**
 * A bounded cache of bitmaps at one pixel ratio. Each bitmap comes back as
 * `{image, width, height}`, its size in CSS pixels, with a marker's center
 * and a badge's corner at the middle and the top left of its image, and a
 * label's text centered across its width with its top `padding` down.
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

  marker({shape, color, opacity, strokeColor}) {
    const key = ["marker", shape, color, opacity, strokeColor].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const size = markerSize(shape)
        const image = spriteCanvas({width: size, height: size, ratio: this.ratio})
        const center = size / HALVING_DIVISOR
        image.getContext("2d").globalAlpha = opacity

        if (shape === SpriteShape.pointed) {
          drawPointedMarker(image, {x: center, y: center, angleRadians: 0, color, strokeColor})
        } else {
          drawRoundMarker(image, {x: center, y: center, color, strokeColor})
        }

        return {image, width: size, height: size}
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

  // `measure` is a context whose font is `font`, which gives the text's width.
  label({text, font, textSizePixels, color, haloColor, measure}) {
    const key = ["label", text, font, color, haloColor].join(KEY_SEPARATOR)

    return this.cached({
      key,
      make: () => {
        const metrics = measure.measureText(text)
        const width = Math.ceil(metrics.width) + LABEL_PADDING_PIXELS * HALVING_DIVISOR
        const height = Math.ceil(textSizePixels * LABEL_LINE_HEIGHT_RATIO) + LABEL_PADDING_PIXELS * HALVING_DIVISOR
        const image = spriteCanvas({width, height, ratio: this.ratio})
        const context = image.getContext("2d")
        context.font = font
        context.textAlign = "center"
        context.textBaseline = "top"
        context.lineJoin = "round"
        context.lineWidth = LABEL_HALO_WIDTH_PIXELS
        context.strokeStyle = haloColor
        context.fillStyle = color
        context.strokeText(text, width / HALVING_DIVISOR, LABEL_PADDING_PIXELS)
        context.fillText(text, width / HALVING_DIVISOR, LABEL_PADDING_PIXELS)
        return {image, width, height, textWidth: metrics.width, padding: LABEL_PADDING_PIXELS}
      }
    })
  }
}
