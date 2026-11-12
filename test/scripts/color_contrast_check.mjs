// Checks the color contrast module against WCAG 2.2's definitions: the
// luminance of black and white, the ratio of 21 between them, a ratio of 1
// for one color on itself, a ratio that is the same in either order, and
// the ratio of #767676 on white, the lightest gray that passes 4.5:1. Run
// it with `node test/scripts/color_contrast_check.mjs`; it exits non-zero
// on the first case that differs.
// https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio — checked 2026-11-09

import {ok, strictEqual} from "node:assert/strict"
import {contrastRatio, relativeLuminance} from "../../assets/js/core/math/color_contrast.js"

const TEXT_CONTRAST_MIN = 4.5
const CONTRAST_MAX = 21

strictEqual(relativeLuminance("#000000"), 0, "black")
strictEqual(relativeLuminance("#ffffff"), 1, "white")
strictEqual(contrastRatio({foreground: "#000000", background: "#ffffff"}), CONTRAST_MAX, "black on white")
strictEqual(contrastRatio({foreground: "#3a7bd5", background: "#3a7bd5"}), 1, "one color on itself")
strictEqual(
  contrastRatio({foreground: "#ffffff", background: "#3a7bd5"}),
  contrastRatio({foreground: "#3a7bd5", background: "#ffffff"}),
  "either order"
)

const passingGray = contrastRatio({foreground: "#767676", background: "#ffffff"})
const failingGray = contrastRatio({foreground: "#777777", background: "#ffffff"})
ok(passingGray >= TEXT_CONTRAST_MIN, `#767676 on white is ${passingGray}`)
ok(failingGray < TEXT_CONTRAST_MIN, `#777777 on white is ${failingGray}`)

console.log("color contrast: every case holds")
