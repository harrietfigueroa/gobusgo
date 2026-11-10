// The details view of the panel sheet, which shows one stop, vehicle, or
// shared vehicle in place of the sheet's tabs. This module is the one owner of what the
// view shows: a hook writes its item into the view with `showDetail`, and
// every listener of the change event learns when the view moves to another
// item or closes, so the hook whose item it was lets go of it.

const CONTENT_ID = "panel-detail-content"
const TITLE_ID = "panel-detail-title"
const TITLE_CLASS_NAME = "panel-sheet-detail-title"

// The DOM event the window gets when the view shows another item or none,
// with the item shown before and the item shown now in its detail.
export const CHANGE_EVENT_NAME = "gobusgo:panel-detail-change"

export const DetailKind = Object.freeze({none: "none", stop: "stop", vehicle: "vehicle", sharedVehicle: "sharedVehicle"})

// The DOM event the window gets when a tap on the map has deselected the
// item the view showed, so the sheet gives focus back where it was before
// the item was opened.
export const DESELECT_EVENT_NAME = "gobusgo:map-deselect"

const noDetail = Object.freeze({kind: DetailKind.none, id: null})

let shown = noDetail

// The item the view shows, as its kind and identifier.
export function shownDetail() {
  return shown
}

// Whether the view shows the item of `kind` and `id`.
export function showsDetail({kind, id}) {
  const isKind = shown.kind === kind
  return isKind && shown.id === id
}

function announce(previous) {
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {previous, shown}}))
}

// Shows the item of `kind` and `id` in the view, under `title`, with
// `content` below it, in place of what it showed. `title` is text and is
// never parsed as HTML.
export function showDetail({kind, id, title, content}) {
  writeContent({title, content})

  const previous = shown
  shown = Object.freeze({kind, id})
  announce(previous)
}

// Writes `title` and `content` in place of what the view shows while it
// shows the item of `kind` and `id`, and leaves the sheet as it is; the
// view of any other item, or of none, is left as it is.
export function updateDetail({kind, id, title, content}) {
  if (showsDetail({kind, id})) {
    writeContent({title, content})
  }
}

// A page with no map has no details view, and nothing to write into it.
function writeContent({title, content}) {
  const element = document.getElementById(CONTENT_ID)

  if (element === null) {
    return
  }

  const heading = document.createElement("h2")
  heading.id = TITLE_ID
  heading.className = TITLE_CLASS_NAME
  heading.textContent = title
  element.replaceChildren(heading, content)
}

// Closes the view, which then shows nothing.
export function closeDetail() {
  if (shown.kind === DetailKind.none) {
    return
  }

  const previous = shown
  shown = noDetail

  const element = document.getElementById(CONTENT_ID)

  if (element !== null) {
    element.replaceChildren()
  }

  announce(previous)
}
