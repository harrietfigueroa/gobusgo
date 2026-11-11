// Checks how much of the layout viewport the on-screen keyboard covers, as a
// pure function of the layout viewport's height and of the visual viewport's
// height, offset, and scale, written out by hand. Run it with
// `node test/scripts/keyboard_inset_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {keyboardInset} from "../../assets/js/keyboard_inset.js"

const cases = [
  {name: "no keyboard", layoutHeight: 800, visual: {height: 800, offsetTop: 0, scale: 1}, inset: 0},
  {name: "a keyboard that shrinks the visual viewport", layoutHeight: 800, visual: {height: 500, offsetTop: 0, scale: 1}, inset: 300},
  {name: "a keyboard with the visual viewport scrolled down", layoutHeight: 800, visual: {height: 500, offsetTop: 120, scale: 1}, inset: 180},
  {name: "a browser bar's few pixels", layoutHeight: 800, visual: {height: 770, offsetTop: 0, scale: 1}, inset: 0},
  {name: "just under the smallest keyboard", layoutHeight: 800, visual: {height: 701, offsetTop: 0, scale: 1}, inset: 0},
  {name: "the smallest keyboard", layoutHeight: 800, visual: {height: 700, offsetTop: 0, scale: 1}, inset: 100},
  {name: "a pinch zoom", layoutHeight: 800, visual: {height: 400, offsetTop: 0, scale: 2}, inset: 0},
  {name: "a visual viewport taller than the layout", layoutHeight: 800, visual: {height: 900, offsetTop: 0, scale: 1}, inset: 0},
  {name: "a scroll past the bottom", layoutHeight: 800, visual: {height: 500, offsetTop: 400, scale: 1}, inset: 0}
]

for (const {name, layoutHeight, visual, inset} of cases) {
  deepStrictEqual(keyboardInset({layoutHeight, visual}), inset, name)
}
