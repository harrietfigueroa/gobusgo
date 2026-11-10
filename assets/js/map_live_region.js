// The map page's one polite live region, which the location button's
// notices and the map's view announcements share, so the two never speak
// over each other from two regions. A notice is shown on the map and read;
// an announcement is read alone, written into a visually hidden span, and
// is dropped while a notice is shown. Each text stays for `TEXT_MS`, then
// the region empties. The region stays in the page, so a screen reader
// hears each text written into it.

import {writeMessage} from "./message"

const ELEMENT_ID = "map-live-region"
const TEXT_MS = 8_000
const ANNOUNCEMENT_CLASS_NAME = "sr-only"
// The region shows a notice while it carries this class. A class, where a
// data attribute would not do: LiveView sets an ignored element's data
// attributes to the server's on each patch, and leaves its classes alone.
const SHOWN_CLASS_NAME = "map-live-region-shown"

let clearTimer = null

function region() {
  return document.getElementById(ELEMENT_ID)
}

function scheduleClear() {
  cancelClear()
  clearTimer = window.setTimeout(clearRegion, TEXT_MS)
}

function cancelClear() {
  if (clearTimer !== null) {
    window.clearTimeout(clearTimer)
    clearTimer = null
  }
}

/** Empties the region and hides its notice, if it shows one. */
export function clearRegion() {
  cancelClear()
  const element = region()

  if (element === null) {
    return
  }

  element.classList.remove(SHOWN_CLASS_NAME)
  element.replaceChildren()
}

/** Shows `message` on the map and has it read, in place of what the region held. */
export function showNotice(message) {
  const element = region()

  if (element === null) {
    return
  }

  writeMessage({element, message})
  element.classList.add(SHOWN_CLASS_NAME)
  scheduleClear()
}

/**
 * Has `text` read without showing it, unless the region shows a notice,
 * which keeps the region.
 */
export function announce(text) {
  const element = region()

  if (element === null) {
    return
  }

  if (element.classList.contains(SHOWN_CLASS_NAME)) {
    return
  }

  const span = document.createElement("span")
  span.className = ANNOUNCEMENT_CLASS_NAME
  span.textContent = text
  element.replaceChildren(span)
  scheduleClear()
}
