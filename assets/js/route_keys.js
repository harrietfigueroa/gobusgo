// What a key does to the list of the routes at the middle of the vehicle
// map, as pure functions of the key and of the list's state, and the texts
// the list has read. Nothing here reads the map or the document.
//
// The key that opens the list is a letter: MapLibre's keyboard handler takes
// the arrows, plus, minus, and equals on the focused map, and the list of
// what is in view takes its arrows, Home, End, and Enter inside itself.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/KeyboardHandler/ — checked 2026-11-11

import {assertCondition} from "./assert.js"
import {ListKey, nextActiveIndex} from "./map_items.js"

const OPEN_KEY = "r"

export const CanvasKeyAction = Object.freeze({announceNone: "announceNone", open: "open", pass: "pass"})
export const ListKeyAction = Object.freeze({close: "close", focus: "focus", pass: "pass"})
export const FocusLeaveAction = Object.freeze({close: "close", keep: "keep"})

const listKeysByKey = Object.freeze({
  ArrowDown: ListKey.down,
  ArrowUp: ListKey.up,
  Home: ListKey.home,
  End: ListKey.end
})

/**
 * Whether a key press is the letter alone: a key with a modifier is a
 * browser's or a screen reader's, and every other key is the map's own
 * handler's.
 */
export function isOpenKeyPress({key, altKey, ctrlKey, metaKey, shiftKey}) {
  const hasModifier = altKey || ctrlKey || metaKey || shiftKey
  const isLetter = key.toLowerCase() === OPEN_KEY
  return isLetter && !hasModifier
}

/**
 * What a key pressed on the focused map does: the letter alone opens the
 * list of the routes at the middle, or says there are none, and every
 * other key passes.
 */
export function canvasKeyAction({key, altKey, ctrlKey, metaKey, shiftKey, hasLines}) {
  const isOpen = isOpenKeyPress({key, altKey, ctrlKey, metaKey, shiftKey})

  if (!isOpen) {
    return CanvasKeyAction.pass
  } else if (hasLines) {
    return CanvasKeyAction.open
  } else {
    return CanvasKeyAction.announceNone
  }
}

/**
 * What a key pressed on the entry at `index` of `count` entries does:
 * Escape closes the list, the arrows, Home, and End move to another entry
 * and stop at the ends, and every other key, Tab and Enter among them, is
 * the browser's.
 */
export function listKeyAction({key, index, count}) {
  if (key === "Escape") {
    return {kind: ListKeyAction.close}
  }

  const listKey = listKeysByKey[key]

  if (listKey === undefined) {
    return {kind: ListKeyAction.pass}
  }

  const target = nextActiveIndex({key: listKey, activeIndex: index, count})
  return {kind: ListKeyAction.focus, index: target}
}

/** A list that focus has left closes, and stays while focus is on another of its entries. */
export function focusLeaveAction({isStillInList}) {
  if (isStillInList) {
    return FocusLeaveAction.keep
  } else {
    return FocusLeaveAction.close
  }
}

/** The text read as the list opens: how many routes it names, what leaves it, and its keys. */
export function openedText({count, hiddenCount}) {
  assertCondition(count > 0, `an opened list names a route, got count: ${count}`)
  assertCondition(hiddenCount >= 0, `hiddenCount must not be negative, got: ${hiddenCount}`)

  const isSingle = count === 1
  let routes = `${count} routes`
  let them = "them"

  if (isSingle) {
    routes = `${count} route`
    them = "it"
  }

  let leftOut = ""

  if (hiddenCount > 0) {
    leftOut = `, and ${hiddenCount} more left out`
  }

  return `${routes} at the middle of the map${leftOut}. Up and down move through ${them}, Escape closes the list.`
}

/** The text read where the middle of the map has no line. */
export function noRoutesText() {
  return "No routes at the middle of the map."
}
