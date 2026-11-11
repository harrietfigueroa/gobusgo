// How much of the layout viewport the on-screen keyboard covers, as a pure
// function of the viewport's measures. Mobile browsers leave the layout
// viewport at its size while the keyboard is shown and shrink the visual
// viewport, so a fixed element along the bottom stays under the keyboard.

// A smaller shortfall is a browser bar, not a keyboard.
const KEYBOARD_HEIGHT_PIXELS_MIN = 100
const UNZOOMED_SCALE = 1

// The height from the bottom of the visual viewport down to the bottom of
// the layout viewport, of `layoutHeight`, where `visual` carries
// `window.visualViewport`'s `height`, `offsetTop`, and `scale`. It is 0
// while the shortfall is a browser bar and while the page is pinch-zoomed,
// where the visual viewport is smaller for a reason that moves no sheet.
export function keyboardInset({layoutHeight, visual}) {
  if (visual.scale > UNZOOMED_SCALE) {
    return 0
  }

  const covered = layoutHeight - visual.height - visual.offsetTop

  if (covered >= KEYBOARD_HEIGHT_PIXELS_MIN) {
    return Math.round(covered)
  } else {
    return 0
  }
}
