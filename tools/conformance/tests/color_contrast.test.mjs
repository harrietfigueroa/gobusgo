// Checks the color contrast module against WCAG 2.2's definitions: the
// luminance of black and white, the ratio of 21 between them, a ratio of 1
// for one color on itself, a ratio that is the same in either order, and
// the ratio of #767676 on white, the lightest gray that passes 4.5:1.
// https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio — checked 2026-11-09

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const TEXT_CONTRAST_MIN = 4.5
const CONTRAST_MAX = 21

describe.each(IMPLEMENTATIONS)("color contrast ($name)", ({colorContrast}) => {
  test("black", () => {
    expect(colorContrast.relativeLuminance("#000000")).toBe(0)
  })

  test("white", () => {
    expect(colorContrast.relativeLuminance("#ffffff")).toBe(1)
  })

  test("black on white", () => {
    expect(colorContrast.contrastRatio({foreground: "#000000", background: "#ffffff"})).toBe(CONTRAST_MAX)
  })

  test("one color on itself", () => {
    expect(colorContrast.contrastRatio({foreground: "#3a7bd5", background: "#3a7bd5"})).toBe(1)
  })

  test("either order", () => {
    const whiteOnBlue = colorContrast.contrastRatio({foreground: "#ffffff", background: "#3a7bd5"})
    const blueOnWhite = colorContrast.contrastRatio({foreground: "#3a7bd5", background: "#ffffff"})
    expect(whiteOnBlue).toBe(blueOnWhite)
  })

  test("#767676 on white passes", () => {
    const passingGray = colorContrast.contrastRatio({foreground: "#767676", background: "#ffffff"})
    expect(passingGray).toBeGreaterThanOrEqual(TEXT_CONTRAST_MIN)
  })

  test("#777777 on white fails", () => {
    const failingGray = colorContrast.contrastRatio({foreground: "#777777", background: "#ffffff"})
    expect(failingGray).toBeLessThan(TEXT_CONTRAST_MIN)
  })
})
