// Route chips: a route's number in its route's color, with text in the
// color that contrasts with it, and a chip that counts the routes a row
// leaves out.

import {chipTextColor} from "./route_chip_color.js"

const CHIP_CLASS_NAME = "route-chip"

function chipElement({name, color}) {
  const chip = document.createElement("span")
  chip.className = CHIP_CLASS_NAME
  chip.textContent = name

  // A route the source gives no color keeps the counting chip's colors.
  if (typeof color === "string") {
    chip.style.backgroundColor = color
    chip.style.color = chipTextColor(color)
  }

  return chip
}

// The chips of `chips`, the first `countMax` of them and a chip that counts
// the rest, or `emptyText` alone when there is none.
export function chipElements({chips, countMax, emptyText}) {
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
