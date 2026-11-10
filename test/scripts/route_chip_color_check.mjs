// Checks the route chip text rule against every route color the agencies
// supply, and against a sweep of the color cube: each color's chip text
// reaches the 4.5:1 of WCAG 2.2 1.4.3, and black text stands only where
// neither slate nor white reaches it, so every other chip keeps its text.
// The route colors are the fixture's, read from the stored routes-for-agency
// responses. A color the rule does not yet serve stands in `knownFailures`
// under the issue that fixes it, and an entry whose color passes fails the
// check, so a fix removes its entry. Run it with
// `node test/scripts/route_chip_color_check.mjs`; it exits non-zero and
// names every color that fails.

import {readFileSync} from "node:fs"
import {contrastRatio} from "../../assets/js/math/color_contrast.js"
import {chipTextColor} from "../../assets/js/route_chip_color.js"

const TEXT_CONTRAST_MIN = 4.5
const RATIO_DIGITS = 2
const SLATE_TEXT_COLOR = "#0f172a"
const WHITE_TEXT_COLOR = "#ffffff"
const BLACK_TEXT_COLOR = "#000000"
const CHANNEL_MAX = 255
const SWEEP_STEP = 17
const HEX_RADIX = 16
const HEX_CHANNEL_DIGIT_COUNT = 2

const knownFailures = new Map()

function channelHex(channel) {
  const digits = channel.toString(HEX_RADIX)
  return digits.padStart(HEX_CHANNEL_DIGIT_COUNT, "0")
}

// Every color whose channels are multiples of `SWEEP_STEP`, the cube's
// corners and every 8-bit gray among them, 4,096 colors in all.
function* sweepColors() {
  for (let red = 0; red <= CHANNEL_MAX; red += SWEEP_STEP) {
    for (let green = 0; green <= CHANNEL_MAX; green += SWEEP_STEP) {
      for (let blue = 0; blue <= CHANNEL_MAX; blue += SWEEP_STEP) {
        yield `#${channelHex(red)}${channelHex(green)}${channelHex(blue)}`
      }
    }
  }
}

function* grayColors() {
  for (let level = 0; level <= CHANNEL_MAX; level++) {
    const channel = channelHex(level)
    yield `#${channel}${channel}${channel}`
  }
}

// What a color's chip fails on, or nothing.
function colorFailure(color) {
  const text = chipTextColor(color)
  const ratio = contrastRatio({foreground: text, background: color})

  if (ratio < TEXT_CONTRAST_MIN) {
    return `${text} text is ${ratio.toFixed(RATIO_DIGITS)}:1, under ${TEXT_CONTRAST_MIN}:1`
  }

  const slateRatio = contrastRatio({foreground: SLATE_TEXT_COLOR, background: color})
  const whiteRatio = contrastRatio({foreground: WHITE_TEXT_COLOR, background: color})
  const twoRatioMax = Math.max(slateRatio, whiteRatio)
  const isBlack = text === BLACK_TEXT_COLOR
  const blackUnneeded = isBlack && twoRatioMax >= TEXT_CONTRAST_MIN

  if (blackUnneeded) {
    return `black text where slate or white reaches ${twoRatioMax.toFixed(RATIO_DIGITS)}:1`
  }

  return ""
}

const fixturePath = new URL("../fixtures/route_colors/route_colors.json", import.meta.url)
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"))
const failures = []

for (const {color, routeCount} of fixture.colors) {
  const failure = colorFailure(color)
  const issue = knownFailures.get(color)
  const isKnown = issue !== undefined
  const passesKnown = failure === "" && isKnown
  const failsUnknown = failure !== "" && !isKnown

  if (passesKnown) {
    failures.push(`${color} passes; remove its known failure, ${issue}`)
  } else if (failsUnknown) {
    failures.push(`${color} (${routeCount} routes): ${failure}`)
  }
}

const sweeps = [sweepColors(), grayColors()]
let sweptCount = 0

for (const sweep of sweeps) {
  for (const color of sweep) {
    sweptCount += 1
    const failure = colorFailure(color)

    if (failure !== "") {
      failures.push(`${color} (sweep): ${failure}`)
    }
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"))
  process.exit(1)
}

console.log(`route chip text: ${fixture.colors.length} route colors and ${sweptCount} swept colors, ${knownFailures.size} known failures`)
