// Checks what a key does to the list of the routes at the middle of the
// vehicle map, as pure functions of values written out by hand: the key on
// the map that opens the list or reports that no line is there, the keys
// inside the list, what leaving the list does to it, and the texts it has
// read. Run it with `node test/scripts/route_keys_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {
  CanvasKeyAction,
  FocusLeaveAction,
  ListKeyAction,
  canvasKeyAction,
  focusLeaveAction,
  listKeyAction,
  noRoutesText,
  openedText
} from "../../assets/js/route_keys.js"

const noModifiers = {altKey: false, ctrlKey: false, metaKey: false, shiftKey: false}

const canvasCases = [
  {name: "r with lines at the middle", given: {...noModifiers, key: "r", hasLines: true}, action: CanvasKeyAction.open},
  {name: "r with no line at the middle", given: {...noModifiers, key: "r", hasLines: false}, action: CanvasKeyAction.announceNone},
  {name: "R with caps lock on", given: {...noModifiers, key: "R", hasLines: true}, action: CanvasKeyAction.open},
  {name: "a key of the map's keyboard handler", given: {...noModifiers, key: "ArrowUp", hasLines: true}, action: CanvasKeyAction.pass},
  {name: "plus, which zooms", given: {...noModifiers, key: "+", hasLines: true}, action: CanvasKeyAction.pass},
  {name: "Enter", given: {...noModifiers, key: "Enter", hasLines: true}, action: CanvasKeyAction.pass},
  {name: "r with Control, a browser's shortcut", given: {...noModifiers, ctrlKey: true, key: "r", hasLines: true}, action: CanvasKeyAction.pass},
  {name: "r with Meta, a browser's shortcut", given: {...noModifiers, metaKey: true, key: "r", hasLines: true}, action: CanvasKeyAction.pass},
  {name: "r with Alt", given: {...noModifiers, altKey: true, key: "r", hasLines: true}, action: CanvasKeyAction.pass},
  {name: "r with Shift", given: {...noModifiers, shiftKey: true, key: "r", hasLines: true}, action: CanvasKeyAction.pass}
]

for (const {name, given, action} of canvasCases) {
  deepStrictEqual(canvasKeyAction(given), action, name)
}

const listCases = [
  {name: "Escape closes", given: {key: "Escape", index: 1, count: 3}, action: {kind: ListKeyAction.close}},
  {name: "Down moves to the next entry", given: {key: "ArrowDown", index: 0, count: 3}, action: {kind: ListKeyAction.focus, index: 1}},
  {name: "Down stops at the last entry", given: {key: "ArrowDown", index: 2, count: 3}, action: {kind: ListKeyAction.focus, index: 2}},
  {name: "Up moves to the previous entry", given: {key: "ArrowUp", index: 2, count: 3}, action: {kind: ListKeyAction.focus, index: 1}},
  {name: "Up stops at the first entry", given: {key: "ArrowUp", index: 0, count: 3}, action: {kind: ListKeyAction.focus, index: 0}},
  {name: "Home moves to the first entry", given: {key: "Home", index: 2, count: 3}, action: {kind: ListKeyAction.focus, index: 0}},
  {name: "End moves to the last entry", given: {key: "End", index: 0, count: 3}, action: {kind: ListKeyAction.focus, index: 2}},
  {name: "a lone entry stays", given: {key: "ArrowDown", index: 0, count: 1}, action: {kind: ListKeyAction.focus, index: 0}},
  {name: "Tab leaves the list to the browser", given: {key: "Tab", index: 0, count: 3}, action: {kind: ListKeyAction.pass}},
  {name: "Enter is the button's own", given: {key: "Enter", index: 0, count: 3}, action: {kind: ListKeyAction.pass}},
  {name: "r is no key of the list", given: {key: "r", index: 0, count: 3}, action: {kind: ListKeyAction.pass}}
]

for (const {name, given, action} of listCases) {
  deepStrictEqual(listKeyAction(given), action, name)
}

throws(() => listKeyAction({key: "ArrowDown", index: 3, count: 3}), "an index past the entries")
throws(() => listKeyAction({key: "ArrowDown", index: 0, count: 0}), "a list with no entry")

const leaveCases = [
  {name: "focus moves to another entry", given: {isStillInList: true}, action: FocusLeaveAction.keep},
  {name: "focus leaves the list", given: {isStillInList: false}, action: FocusLeaveAction.close}
]

for (const {name, given, action} of leaveCases) {
  deepStrictEqual(focusLeaveAction(given), action, name)
}

const textCases = [
  {name: "one route", text: openedText({count: 1, hiddenCount: 0}), expected: "1 route at the middle of the map. Up and down move through it, Escape closes the list."},
  {name: "several routes", text: openedText({count: 3, hiddenCount: 0}), expected: "3 routes at the middle of the map. Up and down move through them, Escape closes the list."},
  {name: "routes left out", text: openedText({count: 12, hiddenCount: 4}), expected: "12 routes at the middle of the map, and 4 more left out. Up and down move through them, Escape closes the list."},
  {name: "no route", text: noRoutesText(), expected: "No routes at the middle of the map."}
]

for (const {name, text, expected} of textCases) {
  deepStrictEqual(text, expected, name)
}

throws(() => openedText({count: 0, hiddenCount: 0}), "an opened list names a route")

const caseCount = canvasCases.length + listCases.length + leaveCases.length + textCases.length + 3
console.log(`route keys: ${caseCount} cases hold`)
