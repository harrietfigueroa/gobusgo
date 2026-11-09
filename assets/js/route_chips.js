// A popup is compact, a row of route numbers in their routes' colors and a
// short note, and a click on the row opens the popup's item in the details
// view of the panel sheet. The row is a button, so the details are one key
// away as well.

import {chipTextColor} from "./route_chip_color.js"

const CHIP_ROW_CLASS_NAME = "popup-title route-chip-row"
const CHIP_NOTE_CLASS_NAME = "route-chip-note"
const CHIP_CLASS_NAME = "route-chip"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
const CLOSE_BUTTON_SELECTOR = ".maplibregl-popup-close-button"

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

/**
 * The text a popup's row adds after what it shows, hidden from sight, so
 * its accessible name starts with its visible text, as speech input reads
 * it, and goes on to name `itemName` and the `action` a press takes. A row
 * with no chips shows the item's name already.
 * https://www.w3.org/WAI/WCAG22/Understanding/label-in-name — checked 2026-11-09
 */
export function popupNameSuffix({hasChips, itemName, action}) {
  if (hasChips) {
    return `, ${itemName}: ${action}`
  }

  return `: ${action}`
}

/** The accessible name of the close button of the popup of `itemName`. */
export function closeButtonName(itemName) {
  return `Close ${itemName}`
}

// Names the close button MapLibre puts beside `content` once a popup has
// been given it, after the popup's item; content outside a popup, or in a
// popup with no close button, is left as it is.
export function nameCloseButton({content, itemName}) {
  const popupContent = content.parentElement

  if (popupContent === null) {
    return
  }

  const button = popupContent.querySelector(CLOSE_BUTTON_SELECTOR)

  if (button !== null) {
    button.setAttribute("aria-label", closeButtonName(itemName))
  }
}

// A popup's content: the row of `chips` and of a note whose text starts as
// `noteText`, which a click hands to `onSelect`. Hidden text after them
// names `itemName` and the `action` a press takes. The note is returned to
// be written again, as a stop's next arrival is when its arrivals come.
export function compactPopupContent({chips, countMax, emptyText, noteText, itemName, action, onSelect}) {
  const content = document.createElement("div")
  const row = document.createElement("button")
  row.type = "button"
  row.className = CHIP_ROW_CLASS_NAME

  for (const element of chipElements({chips, countMax, emptyText})) {
    row.append(element)
  }

  const note = document.createElement("span")
  note.className = CHIP_NOTE_CLASS_NAME
  writeChipNote(note, noteText)
  row.append(note)

  const suffix = document.createElement("span")
  suffix.className = HIDDEN_TEXT_CLASS_NAME
  suffix.textContent = popupNameSuffix({hasChips: chips.length > 0, itemName, action})
  row.append(suffix)

  row.addEventListener("click", onSelect)
  content.append(row)
  return {content, row, note}
}

// Writes `text` into the note of a compact popup, which shows only while it
// has text.
export function writeChipNote(note, text) {
  note.replaceChildren(text)
  note.toggleAttribute("hidden", text === "")
}
