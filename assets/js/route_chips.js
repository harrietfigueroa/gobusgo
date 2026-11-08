import {announceRiderPopupChange} from "./rider_popups"

// A popup opens compact, as a row of route numbers in their routes' colors,
// and a click on the row shows the popup's details under it, or hides them
// again. The row is a button, so the details are one key away as well.

const CHIP_ROW_CLASS_NAME = "popup-title route-chip-row"
const CHIP_CLASS_NAME = "route-chip"
const DARK_TEXT_COLOR = "#0f172a"
const LIGHT_TEXT_COLOR = "#ffffff"
const HEX_DIGIT_COUNT = 6
const HEX_RADIX = 16
const CHANNEL_DIGIT_COUNT = 2
const RED_INDEX = 0
const GREEN_INDEX = 1
const BLUE_INDEX = 2
const CHANNEL_MAX = 255
// The relative luminance and contrast ratio of WCAG 2.2, section 1.4.3:
// https://www.w3.org/TR/WCAG22/#dfn-relative-luminance — checked 2026-11-07
const LINEAR_THRESHOLD = 0.04045
const LINEAR_DIVISOR = 12.92
const GAMMA_OFFSET = 0.055
const GAMMA_DIVISOR = 1.055
const GAMMA_EXPONENT = 2.4
const RED_WEIGHT = 0.2126
const GREEN_WEIGHT = 0.7152
const BLUE_WEIGHT = 0.0722
const CONTRAST_OFFSET = 0.05

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

// The relative luminance of a color written `#rrggbb`.
function luminance(color) {
  const digits = color.slice(1)

  if (digits.length !== HEX_DIGIT_COUNT) {
    throw new Error(`a chip color is #rrggbb, got: ${color}`)
  }

  const red = channelAt(digits, RED_INDEX)
  const green = channelAt(digits, GREEN_INDEX)
  const blue = channelAt(digits, BLUE_INDEX)
  return RED_WEIGHT * red + GREEN_WEIGHT * green + BLUE_WEIGHT * blue
}

// The text color of the two that contrasts more with `color`.
export function chipTextColor(color) {
  const darkTextLuminance = luminance(DARK_TEXT_COLOR)
  const background = luminance(color) + CONTRAST_OFFSET
  const darkContrast = background / (darkTextLuminance + CONTRAST_OFFSET)
  const lightContrast = (1 + CONTRAST_OFFSET) / background

  if (darkContrast >= lightContrast) {
    return DARK_TEXT_COLOR
  } else {
    return LIGHT_TEXT_COLOR
  }
}

function chipElement({name, color}) {
  const chip = document.createElement("span")
  chip.className = CHIP_CLASS_NAME
  chip.textContent = name
  chip.style.backgroundColor = color
  chip.style.color = chipTextColor(color)
  return chip
}

// The chips of `chips`, the first `countMax` of them and a chip that counts
// the rest, or `emptyText` alone when there is none.
function chipElements({chips, countMax, emptyText}) {
  if (chips.length === 0) {
    return [document.createTextNode(emptyText)]
  }

  const shown = chips.slice(0, countMax)
  const elements = []

  for (const chip of shown) {
    elements.push(chipElement(chip))
  }

  if (chips.length > shown.length) {
    const rest = document.createElement("span")
    rest.className = CHIP_CLASS_NAME
    rest.textContent = `+${chips.length - shown.length}`
    elements.push(rest)
  }

  return elements
}

// A popup's content: the row of `chips`, which a click turns into the
// popup's `details` and back. `label` names the row for a screen reader.
export function compactPopupContent({chips, countMax, emptyText, label, details}) {
  const content = document.createElement("div")
  const row = document.createElement("button")
  row.type = "button"
  row.className = CHIP_ROW_CLASS_NAME
  row.setAttribute("aria-expanded", "false")
  row.setAttribute("aria-label", label)

  for (const element of chipElements({chips, countMax, emptyText})) {
    row.append(element)
  }

  details.hidden = true
  row.addEventListener("click", () => {
    details.hidden = !details.hidden
    row.setAttribute("aria-expanded", String(details.hidden === false))
    // The popup's size has changed, so the popups placed around it move.
    announceRiderPopupChange()
  })

  content.append(row, details)
  return content
}
