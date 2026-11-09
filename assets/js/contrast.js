// The relative luminance and contrast ratio of WCAG 2.2, as pure functions
// over colors written `#rrggbb`:
// https://www.w3.org/TR/WCAG22/#dfn-relative-luminance — checked 2026-11-09
// https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio — checked 2026-11-09

import {assertCondition} from "./assert.js"

const HEX_DIGIT_COUNT = 6
const HEX_RADIX = 16
const CHANNEL_DIGIT_COUNT = 2
const RED_INDEX = 0
const GREEN_INDEX = 1
const BLUE_INDEX = 2
const CHANNEL_MAX = 255
const LINEAR_THRESHOLD = 0.04045
const LINEAR_DIVISOR = 12.92
const GAMMA_OFFSET = 0.055
const GAMMA_DIVISOR = 1.055
const GAMMA_EXPONENT = 2.4
const RED_WEIGHT = 0.2126
const GREEN_WEIGHT = 0.7152
const BLUE_WEIGHT = 0.0722
const CONTRAST_OFFSET = 0.05
const HEX_COLOR_PATTERN = /^#[0-9a-fA-F]{6}$/

function channelLuminance(channel) {
  const fraction = channel / CHANNEL_MAX

  if (fraction <= LINEAR_THRESHOLD) {
    return fraction / LINEAR_DIVISOR
  } else {
    return Math.pow((fraction + GAMMA_OFFSET) / GAMMA_DIVISOR, GAMMA_EXPONENT)
  }
}

// The luminance of the channel at `channelIndex` of `digits`, a color's
// hexadecimal digits without its `#`.
function channelAt(digits, channelIndex) {
  const start = channelIndex * CHANNEL_DIGIT_COUNT
  const channelDigits = digits.slice(start, start + CHANNEL_DIGIT_COUNT)
  const channel = parseInt(channelDigits, HEX_RADIX)
  return channelLuminance(channel)
}

/** The relative luminance of `color`, written `#rrggbb`: 0 for black, 1 for white. */
export function relativeLuminance(color) {
  assertCondition(HEX_COLOR_PATTERN.test(color), `a color is #rrggbb, got: ${color}`)
  const digits = color.slice(1)
  assertCondition(digits.length === HEX_DIGIT_COUNT, `a color has ${HEX_DIGIT_COUNT} digits, got: ${color}`)
  const red = channelAt(digits, RED_INDEX)
  const green = channelAt(digits, GREEN_INDEX)
  const blue = channelAt(digits, BLUE_INDEX)
  return RED_WEIGHT * red + GREEN_WEIGHT * green + BLUE_WEIGHT * blue
}

/** The contrast ratio of two colors written `#rrggbb`, from 1 to 21; the order of the two does not matter. */
export function contrastRatio({foreground, background}) {
  const foregroundLuminance = relativeLuminance(foreground)
  const backgroundLuminance = relativeLuminance(background)
  const lighter = Math.max(foregroundLuminance, backgroundLuminance)
  const darker = Math.min(foregroundLuminance, backgroundLuminance)
  return (lighter + CONTRAST_OFFSET) / (darker + CONTRAST_OFFSET)
}
