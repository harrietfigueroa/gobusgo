// Checks what a tap on the vehicle map does to the details view, as a pure
// function of values written out by hand: a tap on no item while the view
// shows one deselects it, and any other tap leaves the view to the item's
// own listener. Run it with `node test/scripts/map_selection_check.mjs`; it
// exits non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {TapOutcome, tapOutcome} from "../../assets/js/map_selection.js"

const cases = [
  {name: "a tap on the empty map while an item is shown", given: {isItemHit: false, isShowing: true}, outcome: TapOutcome.deselect},
  {name: "a tap on the empty map while nothing is shown", given: {isItemHit: false, isShowing: false}, outcome: TapOutcome.none},
  {name: "a tap on an item while another is shown", given: {isItemHit: true, isShowing: true}, outcome: TapOutcome.none},
  {name: "a tap on an item while nothing is shown", given: {isItemHit: true, isShowing: false}, outcome: TapOutcome.none}
]

for (const {name, given, outcome} of cases) {
  deepStrictEqual(tapOutcome(given), outcome, name)
}

console.log(`map selection: ${cases.length} cases hold`)
