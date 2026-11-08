import {announceRiderPopupChange} from "./rider_popups"

// A popup opens compact, as a row of route numbers in their routes' colors,
// and a click on the row shows the popup's details under it, or hides them
// again. The row is a button, so the details are one key away as well.

const chipRowClassName = "popup-title route-chip-row"
const chipClassName = "route-chip"
const darkTextColor = "#0f172a"
const lightTextColor = "#ffffff"
const hexDigitCount = 6
const hexRadix = 16
const channelMax = 255
// The relative luminance and contrast ratio of WCAG 2.2, section 1.4.3:
// https://www.w3.org/TR/WCAG22/#dfn-relative-luminance — checked 2026-11-07
const linearThreshold = 0.04045
const linearDivisor = 12.92
const gammaOffset = 0.055
const gammaDivisor = 1.055
const gammaExponent = 2.4
const redWeight = 0.2126
const greenWeight = 0.7152
const blueWeight = 0.0722
const contrastOffset = 0.05

function channelLuminance(channel) {
  const fraction = channel / channelMax

  if (fraction <= linearThreshold) {
    return fraction / linearDivisor
  } else {
    return Math.pow((fraction + gammaOffset) / gammaDivisor, gammaExponent)
  }
}

// The relative luminance of a color written `#rrggbb`.
function luminance(color) {
  const digits = color.slice(1)

  if (digits.length !== hexDigitCount) {
    throw new Error(`a chip color is #rrggbb, got: ${color}`)
  }

  const red = channelLuminance(parseInt(digits.slice(0, 2), hexRadix))
  const green = channelLuminance(parseInt(digits.slice(2, 4), hexRadix))
  const blue = channelLuminance(parseInt(digits.slice(4, 6), hexRadix))
  return redWeight * red + greenWeight * green + blueWeight * blue
}

// The text color of the two that contrasts more with `color`.
export function chipTextColor(color) {
  const darkTextLuminance = luminance(darkTextColor)
  const background = luminance(color) + contrastOffset
  const darkContrast = background / (darkTextLuminance + contrastOffset)
  const lightContrast = (1 + contrastOffset) / background

  if (darkContrast >= lightContrast) {
    return darkTextColor
  } else {
    return lightTextColor
  }
}

function chipElement({name, color}) {
  const chip = document.createElement("span")
  chip.className = chipClassName
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
    rest.className = chipClassName
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
  row.className = chipRowClassName
  row.setAttribute("aria-expanded", "false")
  row.setAttribute("aria-label", label)
  row.append(...chipElements({chips, countMax, emptyText}))

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
