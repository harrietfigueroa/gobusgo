// The texts of a stop's arrivals, as the server sends them with the
// "stop-arrivals:arrivals" event.

import {unreachable} from "./assert.js"

const ARRIVALS_HEADING = "Arrivals"
const SCHEDULED_ARRIVALS_HEADING = "Scheduled arrivals"
const ARRIVALS_WAITING = "Waiting for this stop's arrivals"
const ARRIVALS_NONE = "No arrivals soon"
const ARRIVALS_REFUSED = "No arrivals for this stop"
const ARRIVALS_BUSY = "Too many stops open; close one to see this stop's arrivals"
const ARRIVAL_NOW = "now"
const ARRIVAL_SCHEDULED_NOTE = " (scheduled)"
const ARRIVAL_UNNAMED = "Arrival"
const ARRIVALS_NEED_CONNECTION = "Live arrivals need a connection"
const LIVE_LABEL = "live time"

/** The class of the dot beside a time that is a live prediction. */
export const LIVE_DOT_CLASS_NAME = "live-dot"

/** The class of an element the stylesheet hides while the page is offline. */
export const NEEDS_CONNECTION_CLASS_NAME = "needs-connection"

/** The class of an element the stylesheet shows only while the page is offline. */
export const OFFLINE_NOTE_CLASS_NAME = "offline-note"

export function appendParagraph(element, text) {
  const paragraph = document.createElement("p")
  paragraph.textContent = text
  element.appendChild(paragraph)
}

// One arrival as a line: where it goes, and how soon. A time that is the
// schedule and no prediction says so, and a prediction is live.
function arrivalLine({route, headsign, minutes, predicted}) {
  const names = []

  if (typeof route === "string") {
    names.push(route)
  }

  if (typeof headsign === "string") {
    names.push(`to ${headsign}`)
  }

  let name = ARRIVAL_UNNAMED
  let time = `${minutes} min`
  let note = ARRIVAL_SCHEDULED_NOTE

  if (names.length > 0) {
    name = names.join(" ")
  }

  if (minutes === 0) {
    time = ARRIVAL_NOW
  }

  if (predicted) {
    note = ""
  }

  return {text: `${name}: ${time}${note}`, isLive: predicted}
}

/**
 * Whether `shown` is a stop's arrivals from the saved schedules, which an
 * offline page writes for itself, and not the server's.
 */
export function isScheduledShown(shown) {
  return shown.scheduled === true
}

// The heading of a stop's arrivals: that they are the schedule's, or the age
// of the fetch they come from once it is a minute old.
function arrivalsHeadingText({ageMinutes, isScheduled}) {
  if (isScheduled) {
    return SCHEDULED_ARRIVALS_HEADING
  } else if (ageMinutes >= 1) {
    return `${ARRIVALS_HEADING} (as of ${ageMinutes} min ago)`
  } else {
    return ARRIVALS_HEADING
  }
}

/**
 * The lines a page shows for what the server says of a stop's arrivals, each
 * its text and whether it is a live prediction.
 */
export function arrivalLines(shown) {
  const {status, age_minutes: ageMinutes, arrivals} = shown
  const heading = arrivalsHeadingText({ageMinutes, isScheduled: isScheduledShown(shown)})

  switch (status) {
    case "waiting":
      return [plainLine(ARRIVALS_WAITING)]
    case "refused":
      return [plainLine(ARRIVALS_REFUSED)]
    case "busy":
      return [plainLine(ARRIVALS_BUSY)]
    case "arrivals":
      if (arrivals.length === 0) {
        return [plainLine(heading), plainLine(ARRIVALS_NONE)]
      } else {
        const lines = Array.from(arrivals, arrivalLine)
        return [plainLine(heading), ...lines]
      }
    default:
      return unreachable(status, "arrivals status")
  }
}

/** The kinds of what a stop's arrivals show as rows: the rows, or one note in their place. */
export const ArrivalRowsKind = Object.freeze({rows: "rows", note: "note"})

const ChipLookupKind = Object.freeze({found: "found", missing: "missing"})

// The chip named `route` among `chips`, a stop's route chips, or missing
// for a route the stop has no chip of.
function chipLookup({route, chips}) {
  const chip = chips.find((candidate) => candidate.name === route)

  if (chip === undefined) {
    return {kind: ChipLookupKind.missing}
  }

  return {kind: ChipLookupKind.found, color: chip.color}
}

function arrivalTimeText(minutes) {
  if (minutes === 0) {
    return ARRIVAL_NOW
  }

  return `${minutes} min`
}

function noteRows(text) {
  return {kind: ArrivalRowsKind.note, text}
}

/**
 * What `shown`, a stop's arrivals as the server sends them, shows as rows:
 * each arrival's route, the color of its chip among `chips`, the stop's
 * route chips, its headsign, how soon it comes, and whether that is a live
 * prediction; or the note that stands in their place.
 */
export function arrivalRows({shown, chips}) {
  const {status, arrivals} = shown

  switch (status) {
    case "waiting":
      return noteRows(ARRIVALS_WAITING)
    case "refused":
      return noteRows(ARRIVALS_REFUSED)
    case "busy":
      return noteRows(ARRIVALS_BUSY)
    case "arrivals":
      if (arrivals.length === 0) {
        return noteRows(ARRIVALS_NONE)
      }

      return {
        kind: ArrivalRowsKind.rows,
        rows: Array.from(arrivals, (arrival) => arrivalRow({arrival, chips}))
      }
    default:
      return unreachable(status, "arrivals status")
  }
}

function arrivalRow({arrival, chips}) {
  const {route, headsign, minutes, predicted} = arrival
  let routeName = null
  let color = null

  if (typeof route === "string") {
    routeName = route
    const lookup = chipLookup({route, chips})

    if (lookup.kind === ChipLookupKind.found) {
      color = lookup.color
    }
  }

  let headsignText = null

  if (typeof headsign === "string") {
    headsignText = headsign
  }

  return {route: routeName, color, headsign: headsignText, time: arrivalTimeText(minutes), isLive: predicted === true}
}

function plainLine(text) {
  return {text, isLive: false}
}

/** Whether the next arrival of what the server says of a stop's arrivals is a live prediction. */
export function isNextArrivalLive({status, arrivals}) {
  const hasArrival = status === "arrivals" && arrivals.length > 0

  if (hasArrival === false) {
    return false
  }

  const [{predicted}] = arrivals
  return predicted === true
}

/**
 * The dot beside a live time: an image whose accessible name says the time
 * is live, so a screen reader reads it after the time.
 */
export function liveDot() {
  const dot = document.createElement("span")
  dot.className = LIVE_DOT_CLASS_NAME
  dot.setAttribute("role", "img")
  dot.setAttribute("aria-label", LIVE_LABEL)
  return dot
}

// The next arrival of what the server says of a stop's arrivals, as its
// route and how soon, such as "E 2 min"; an empty text while it says of
// none.
export function nextArrivalText({status, arrivals}) {
  const time = nextArrivalTimeText({status, arrivals})

  if (time === "") {
    return ""
  }

  const [{route}] = arrivals

  if (typeof route === "string") {
    return `${route} ${time}`
  } else {
    return time
  }
}

// How soon the next arrival of what the server says of a stop's arrivals
// comes, such as "2 min" or "now"; an empty text while it says of none.
export function nextArrivalTimeText({status, arrivals}) {
  const hasArrival = status === "arrivals" && arrivals.length > 0

  if (hasArrival === false) {
    return ""
  }

  const [{minutes}] = arrivals

  if (minutes === 0) {
    return ARRIVAL_NOW
  } else {
    return `${minutes} min`
  }
}

// Writes a stop's arrivals into `element` as text nodes: the names come
// from outside the application and are never parsed as HTML. The
// stylesheet shows the server's arrivals while the page is connected and
// the note that they need a connection while it is offline; the saved
// schedules' arrivals are shown whatever the connection, with no note.
export function writeArrivals(element, shown) {
  element.replaceChildren()
  const isScheduled = isScheduledShown(shown)
  let className = NEEDS_CONNECTION_CLASS_NAME

  if (isScheduled) {
    className = ""
  }

  for (const {text, isLive} of arrivalLines(shown)) {
    const paragraph = classedParagraph({text, className})

    if (isLive) {
      paragraph.append(liveDot())
    }

    element.append(paragraph)
  }

  if (!isScheduled) {
    const note = classedParagraph({text: ARRIVALS_NEED_CONNECTION, className: OFFLINE_NOTE_CLASS_NAME})
    element.append(note)
  }
}

/** Hides `note`, a callout's arrivals, while the page is offline, unless `shown` is the saved schedules'. */
export function markArrivalNote({note, shown}) {
  note.classList.toggle(NEEDS_CONNECTION_CLASS_NAME, !isScheduledShown(shown))
}

function classedParagraph({text, className}) {
  const paragraph = document.createElement("p")
  paragraph.textContent = text
  paragraph.className = className
  return paragraph
}
