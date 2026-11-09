// The text color of a route chip, whose fill is the route's color as the
// agency supplies it. Pure: nothing here reads the document.

import {contrastRatio} from "./contrast.js"

const DARK_TEXT_COLOR = "#0f172a"
const LIGHT_TEXT_COLOR = "#ffffff"

/** The text color of the two that contrasts more with `color`, written `#rrggbb`. */
export function chipTextColor(color) {
  const darkContrast = contrastRatio({foreground: DARK_TEXT_COLOR, background: color})
  const lightContrast = contrastRatio({foreground: LIGHT_TEXT_COLOR, background: color})

  if (darkContrast >= lightContrast) {
    return DARK_TEXT_COLOR
  } else {
    return LIGHT_TEXT_COLOR
  }
}
