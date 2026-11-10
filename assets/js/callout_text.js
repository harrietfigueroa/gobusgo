// The texts of the callout a tap opens on the map, as pure functions of the
// texts a marker carries. Nothing here reads the document.

const TITLE_SEPARATOR = " · "
const DETAIL_SEPARATOR = " · "
const NEXT_STOP_PREFIX = "next "

function isText(value) {
  return typeof value === "string" && value !== ""
}

/**
 * A vehicle's callout: its route and headsign as the title, or
 * `fallbackName` for a vehicle with neither, and a detail line of its
 * lateness and its next stop, each where the marker has it, empty where it
 * has neither.
 */
export function vehicleCalloutText({route, headsign, schedule, nextStop, fallbackName}) {
  const names = []

  if (isText(route)) {
    names.push(route)
  }

  if (isText(headsign)) {
    names.push(headsign)
  }

  let title = fallbackName

  if (names.length > 0) {
    title = names.join(TITLE_SEPARATOR)
  }

  const details = []

  if (isText(schedule)) {
    details.push(schedule)
  }

  if (isText(nextStop)) {
    details.push(NEXT_STOP_PREFIX + nextStop)
  }

  return {title, detail: details.join(DETAIL_SEPARATOR)}
}

/**
 * The text a callout adds, hidden, after what it shows, so its accessible
 * name starts with its visible text, as speech input reads it, and goes on
 * to name `detailName`, what the callout shows only by a mark such as a
 * status badge, or nothing for an empty one, and the `action` a press takes.
 * https://www.w3.org/WAI/WCAG22/Understanding/label-in-name — checked 2026-11-09
 */
export function calloutNameSuffix({detailName, action}) {
  if (isText(detailName)) {
    return `, ${detailName}: ${action}`
  }

  return `: ${action}`
}
