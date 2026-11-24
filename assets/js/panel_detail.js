// The details view of the panel sheet, which shows one stop, vehicle, or
// shared vehicle, or a list of the stops under a tap, in place of the
// sheet's tabs. This module is the one owner of what the view shows: a hook
// writes its item into the view with `showDetail`, and every listener of
// the change event learns when the view moves to another item or closes, so
// the hook whose item it was lets go of it. Each item is shown with a
// parent or none, which `showParentDetail` shows again in its place.

import {assertCondition, unreachable} from "#core/assert.js"

const CONTENT_ID = "panel-detail-content"
const TITLE_ID = "panel-detail-title"
const TITLE_CLASS_NAME = "panel-sheet-detail-title"

// The DOM event the window gets when the view shows another item or none,
// with the item shown before and the item shown now in its detail.
export const CHANGE_EVENT_NAME = "gobusgo:panel-detail-change"

// The DOM event the window gets when `clearParentDetail` drops the parent
// of the item the view shows.
export const PARENT_CLEAR_EVENT_NAME = "gobusgo:panel-detail-parent-clear"

export const DetailKind = Object.freeze({none: "none", stop: "stop", stopList: "stopList", vehicle: "vehicle", sharedVehicle: "sharedVehicle"})

/** Whether the item the view shows was opened from another, which its back button returns to. */
export const ParentKind = Object.freeze({none: "none", detail: "detail"})

/** The parent of an item opened from no other. */
export const NO_PARENT = Object.freeze({kind: ParentKind.none})

/** The parent that shows the item of `kind` and `id` again, under `title`, with `content` below it. */
export function detailParent({kind, id, title, content}) {
  return Object.freeze({kind: ParentKind.detail, detail: {kind, id, title, content}})
}

let shownParent = NO_PARENT

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
// `content` below it, in place of what it showed, and keeps `parent`, the
// item it was opened from, for the back button. `title` is text and is
// never parsed as HTML.
export function showDetail({kind, id, title, content, parent = NO_PARENT}) {
  writeContent({title, content})
  shownParent = parent

  const previous = shown
  shown = Object.freeze({kind, id})
  announce(previous)
}

// Whether the item the view shows was opened from another.
export function hasParentDetail() {
  return shownParent.kind === ParentKind.detail
}

/** The title the view's back button returns to: the parent's, or `tabTitle` for an item opened from none. */
export function backTitle(tabTitle) {
  switch (shownParent.kind) {
    case ParentKind.detail:
      return shownParent.detail.title
    case ParentKind.none:
      return tabTitle
    default:
      return unreachable(shownParent.kind, "panel detail: a parent of unknown kind")
  }
}

// Drops the parent of the item the view shows, and announces it where it
// had one.
export function clearParentDetail() {
  if (hasParentDetail()) {
    shownParent = NO_PARENT
    window.dispatchEvent(new CustomEvent(PARENT_CLEAR_EVENT_NAME))
  }
}

// Moves focus to the title of the item the view shows, which a screen
// reader then reads; a page with no map has no title to focus.
export function focusDetailTitle() {
  const heading = document.getElementById(TITLE_ID)

  if (heading !== null) {
    heading.tabIndex = -1
    heading.focus({preventScroll: true})
  }
}

// Shows again the item the view's item was opened from, in place of it.
export function showParentDetail() {
  assertCondition(hasParentDetail(), `the view's item has a parent, shown: ${shown.kind}`)
  const {kind, id, title, content} = shownParent.detail
  showDetail({kind, id, title, content, parent: NO_PARENT})
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
  shownParent = NO_PARENT

  const element = document.getElementById(CONTENT_ID)

  if (element !== null) {
    element.replaceChildren()
  }

  announce(previous)
}
