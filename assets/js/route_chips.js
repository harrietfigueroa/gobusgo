// A popup is compact, a row of route numbers in their routes' colors and a
// short note, and a click on the row opens the popup's item in the details
// view of the panel sheet. The row is a button, so the details are one key
// away as well.

import {chipTextColor} from "./route_chip_color.js"

const CHIP_ROW_CLASS_NAME = "popup-title route-chip-row"
const CHIP_NOTE_CLASS_NAME = "route-chip-note"
const CHIP_CLASS_NAME = "route-chip"

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

// A popup's content: the row of `chips` and of a note whose text starts as
// `noteText`, which a click hands to `onSelect`. `label` names the row for
// a screen reader. The note is returned to be written again, as a stop's
// next arrival is when its arrivals come.
export function compactPopupContent({chips, countMax, emptyText, noteText, label, onSelect}) {
  const content = document.createElement("div")
  const row = document.createElement("button")
  row.type = "button"
  row.className = CHIP_ROW_CLASS_NAME
  row.setAttribute("aria-label", label)

  for (const element of chipElements({chips, countMax, emptyText})) {
    row.append(element)
  }

  const note = document.createElement("span")
  note.className = CHIP_NOTE_CLASS_NAME
  writeChipNote(note, noteText)
  row.append(note)

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
