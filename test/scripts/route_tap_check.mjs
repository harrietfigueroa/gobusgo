// Checks what a tap on the vehicle map does to the list of the routes under
// it, as a pure function of values written out by hand: a device that hovers
// leaves the list to hover, a marker under the tap wins over any line, lines
// under the tap open the list, and any other tap closes a list that is
// shown. Run it with `node test/scripts/route_tap_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {DeviceKind, TapAction, deviceKind, tapAction} from "../../assets/js/route_tap.js"

const kindCases = [
  {name: "a primary pointer that cannot hover", given: {isHoverNone: true}, kind: DeviceKind.touch},
  {name: "a primary pointer that can hover", given: {isHoverNone: false}, kind: DeviceKind.hover}
]

for (const {name, given, kind} of kindCases) {
  deepStrictEqual(deviceKind(given), kind, name)
}

const touch = DeviceKind.touch
const hover = DeviceKind.hover

const actionCases = [
  {name: "lines under a tap, nothing shown", given: {kind: touch, isItemHit: false, hasLines: true, isShown: false}, action: TapAction.open},
  {name: "lines under a tap, a list shown", given: {kind: touch, isItemHit: false, hasLines: true, isShown: true}, action: TapAction.open},
  {name: "a tap on empty map, a list shown", given: {kind: touch, isItemHit: false, hasLines: false, isShown: true}, action: TapAction.close},
  {name: "a tap on empty map, nothing shown", given: {kind: touch, isItemHit: false, hasLines: false, isShown: false}, action: TapAction.none},
  {name: "a marker on a line, nothing shown", given: {kind: touch, isItemHit: true, hasLines: true, isShown: false}, action: TapAction.none},
  {name: "a marker on a line, a list shown", given: {kind: touch, isItemHit: true, hasLines: true, isShown: true}, action: TapAction.close},
  {name: "a marker off the lines, a list shown", given: {kind: touch, isItemHit: true, hasLines: false, isShown: true}, action: TapAction.close},
  {name: "a marker off the lines, nothing shown", given: {kind: touch, isItemHit: true, hasLines: false, isShown: false}, action: TapAction.none},
  {name: "a hovering device, lines under a click", given: {kind: hover, isItemHit: false, hasLines: true, isShown: false}, action: TapAction.none},
  {name: "a hovering device, a click on empty map with a list shown", given: {kind: hover, isItemHit: false, hasLines: false, isShown: true}, action: TapAction.none},
  {name: "a hovering device, a click on a marker", given: {kind: hover, isItemHit: true, hasLines: true, isShown: true}, action: TapAction.none}
]

for (const {name, given, action} of actionCases) {
  deepStrictEqual(tapAction(given), action, name)
}

console.log(`route tap: ${kindCases.length + actionCases.length} cases hold`)
