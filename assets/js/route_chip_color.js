// The text color of a route chip, whose fill is the route's color as the
// agency supplies it. Pure: nothing here reads the document.

import {contrastRatio} from "./contrast.js"

const DARK_TEXT_COLOR = "#0f172a"
const LIGHT_TEXT_COLOR = "#ffffff"
const BLACK_TEXT_COLOR = "#000000"
// The text contrast of WCAG 2.2 1.4.3. With black and white text the worst
// fill still reaches 4.58:1, so the fallback serves every color.
const TEXT_CONTRAST_MIN = 4.5

// The text color of `first` and `second` that contrasts more with `color`.
function higherContrast({color, first, second}) {
  const firstContrast = contrastRatio({foreground: first, background: color})
  const secondContrast = contrastRatio({foreground: second, background: color})

  if (firstContrast >= secondContrast) {
    return first
  } else {
    return second
  }
}

/**
 * The text color of a chip filled with `color`, written `#rrggbb`: slate or
 * white, whichever contrasts more, and black or white where neither reaches
 * 4.5:1.
 */
export function chipTextColor(color) {
  const chosen = higherContrast({color, first: DARK_TEXT_COLOR, second: LIGHT_TEXT_COLOR})
  const chosenContrast = contrastRatio({foreground: chosen, background: color})

  if (chosenContrast >= TEXT_CONTRAST_MIN) {
    return chosen
  } else {
    return higherContrast({color, first: BLACK_TEXT_COLOR, second: LIGHT_TEXT_COLOR})
  }
}
