// The texts of a stop's arrivals, as the server sends them with the
// "stop-arrivals:arrivals" event, in the glanceable style: a row per
// arrival of its route's chip, its headsign, and its time, with a live dot
// beside a predicted time, and a key under the rows.

import {unreachable} from "./core/assert.js"
import {appendSpaced, chipElements} from "./route_chips.js"
import {arrivalsKey} from "./stop_text.js"
import {appendMessage} from "./message.js"
import {YourBusKind} from "./journey_stop_marks.js"
import {ArrivalFollowKind, FOLLOW_REQUEST_EVENT_NAME, arrivalFollow, arrivalFollowLabel} from "./vehicle_follow.js"

const ARRIVALS_WAITING = "Waiting for this stop's arrivals"
const ARRIVALS_NONE = "No arrivals soon"
const ARRIVALS_REFUSED = "No arrivals for this stop"
const ARRIVALS_BUSY = "Too many stops open; close one to see this stop's arrivals"
const ARRIVAL_NOW = "now"
const ARRIVALS_NEED_CONNECTION = Object.freeze({headline: "Live arrivals need a connection", caption: "They come back when you're online."})
const LIVE_LABEL = "live time"
const ROWS_CLASS_NAME = "arrival-rows"
const ROW_CLASS_NAME = "arrival-row"
const YOURS_ROW_CLASS_NAME = "arrival-row arrival-row-yours"
const YOURS_CLASS_NAME = "arrival-yours"
const YOURS_TEXT = "Your bus"
const NO_ROW_INDEX = -1
const HEADSIGN_CLASS_NAME = "arrival-headsign"
const TIME_CLASS_NAME = "arrival-time"
const LIVE_TIME_CLASS_NAME = "arrival-time arrival-time-live"
const NOTE_CLASS_NAME = "arrival-note"
const KEY_CLASS_NAME = "arrival-key"
const KEY_DOT_CLASS_NAME = "live-dot arrival-key-dot"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
const FOLLOW_BUTTON_MARK_CLASS_NAME = "arrival-follow"
const FOLLOW_BUTTON_CLASS_NAME = `panel-detail-action ${FOLLOW_BUTTON_MARK_CLASS_NAME}`
const FOLLOW_BUTTON_TEXT = "Follow"
const FocusKind = Object.freeze({button: "button", none: "none"})

/** The class of the dot beside a time that is a live prediction. */
export const LIVE_DOT_CLASS_NAME = "live-dot"

/** The class of an element the stylesheet hides while the page is offline. */
const NEEDS_CONNECTION_CLASS_NAME = "needs-connection"

/** The class of an element the stylesheet shows only while the page is offline. */
export const OFFLINE_NOTE_CLASS_NAME = "offline-note"

export function appendParagraph(element, text) {
  const paragraph = document.createElement("p")
  paragraph.textContent = text
  element.appendChild(paragraph)
}

/**
 * Whether `shown` is a stop's arrivals from the saved schedules, which an
 * offline page writes for itself, and not the server's.
 */
export function isScheduledShown(shown) {
  return shown.scheduled === true
}

/** The kinds of what a stop's arrivals show as rows: the rows, or one note in their place. */
export const ArrivalRowsKind = Object.freeze({rows: "rows", note: "note"})

function arrivalTimeText(minutes) {
  if (minutes === 0) {
    return ARRIVAL_NOW
  }

  return `${minutes} min`
}

function noteRows(text) {
  return {kind: ArrivalRowsKind.note, text}
}

// An arrival's row; a text the arrival lacks is null in the row.
function arrivalRow(arrival) {
  const row = {route: null, color: null, headsign: null, time: arrivalTimeText(arrival.minutes), isLive: arrival.predicted === true, vehicleId: null}

  for (const field of ["route", "color", "headsign"]) {
    if (typeof arrival[field] === "string") {
      row[field] = arrival[field]
    }
  }

  const follow = arrivalFollow(arrival)

  if (follow.kind === ArrivalFollowKind.followable) {
    row.vehicleId = follow.vehicleId
  }

  return row
}

/**
 * What `shown`, a stop's arrivals as the server sends them, shows as rows:
 * each arrival's route, its route's color, its headsign, how soon it comes,
 * and whether that is a live prediction; or the note that stands in their
 * place.
 */
export function arrivalRows(shown) {
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

      return {kind: ArrivalRowsKind.rows, rows: Array.from(arrivals, arrivalRow)}
    default:
      return unreachable(status, "arrivals status")
  }
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
  return arrivalTimeText(minutes)
}

function textElement({tagName, className, text}) {
  const element = document.createElement(tagName)
  element.className = className
  element.textContent = text
  return element
}

function chipOf({route, color}) {
  const chips = []

  if (route !== null) {
    chips.push({name: route, color})
  }

  return chips
}

/**
 * One arrival's row, of the shape `arrivalRows` gives, as an element of
 * `tagName`: its route's chip, its headsign, and how soon, a live time in
 * bold with the live dot beside it.
 */
function arrivalRowElement({row, tagName, isYours, canFollow}) {
  const {route, color, headsign, time, isLive, vehicleId} = row
  const element = document.createElement(tagName)
  element.className = ROW_CLASS_NAME

  if (isYours) {
    element.className = YOURS_ROW_CLASS_NAME
  }

  const children = chipElements({chips: chipOf({route, color}), countMax: 1, emptyText: ""})

  let headsignText = ""

  if (headsign !== null) {
    headsignText = headsign
  }

  children.push(textElement({tagName: "span", className: HEADSIGN_CLASS_NAME, text: headsignText}))

  if (isYours) {
    children.push(textElement({tagName: "span", className: YOURS_CLASS_NAME, text: YOURS_TEXT}))
  }

  let timeClassName = TIME_CLASS_NAME

  if (isLive) {
    timeClassName = LIVE_TIME_CLASS_NAME
  }

  const timeElement = textElement({tagName: "span", className: timeClassName, text: time})

  if (isLive) {
    timeElement.append(liveDot())
  }

  children.push(timeElement)

  const isFollowable = canFollow && vehicleId !== null

  if (isFollowable) {
    children.push(followButton({vehicleId, route, headsign}))
  }

  appendSpaced({element, children})
  return element
}

// The button that asks the map to follow the arrival's vehicle. A real
// button, named by its route and where it goes, so a screen reader reads
// which bus each one follows.
function followButton({vehicleId, route, headsign}) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = FOLLOW_BUTTON_CLASS_NAME
  button.textContent = FOLLOW_BUTTON_TEXT
  button.setAttribute("aria-label", arrivalFollowLabel({route, headsign}))
  button.dataset.vehicleId = vehicleId
  button.addEventListener("click", () => {
    window.dispatchEvent(new CustomEvent(FOLLOW_REQUEST_EVENT_NAME, {detail: {vehicleId}}))
  })
  return button
}

// The vehicle of the follow button that has the focus inside `element`, or
// none: the rows are written again between events, and the button the rider
// is on is found again by its vehicle.
function focusedVehicleOf(element) {
  const active = document.activeElement
  const isInside = active !== null && element.contains(active)

  if (isInside && typeof active.dataset.vehicleId === "string") {
    return {kind: FocusKind.button, vehicleId: active.dataset.vehicleId}
  }

  return {kind: FocusKind.none}
}

function restoreFocus({element, focused}) {
  if (focused.kind === FocusKind.none) {
    return
  }

  const buttons = element.querySelectorAll(`button.${FOLLOW_BUTTON_MARK_CLASS_NAME}`)

  for (const button of buttons) {
    if (button.dataset.vehicleId === focused.vehicleId) {
      button.focus()
      return
    }
  }
}

// The key under a stop's arrivals: the line a sighted rider reads, a live
// dot before it for the server's arrivals, and the sentences a screen
// reader reads in its place.
function keyElement(shown) {
  const isScheduled = isScheduledShown(shown)
  const key = arrivalsKey({ageMinutes: shown.age_minutes, isScheduled})
  const element = document.createElement("p")
  element.className = KEY_CLASS_NAME

  const visible = document.createElement("span")
  visible.setAttribute("aria-hidden", "true")

  if (!isScheduled) {
    const dot = document.createElement("span")
    dot.className = KEY_DOT_CLASS_NAME
    visible.append(dot, " ")
  }

  visible.append(key.shown)
  element.append(visible, textElement({tagName: "span", className: HIDDEN_TEXT_CLASS_NAME, text: key.spoken}))
  return element
}

// Writes a stop's arrivals into `element` as text nodes: the names come
// from outside the application and are never parsed as HTML. The rows are
// a list, and the key under them comes `withKey`. The stylesheet shows the
// server's arrivals while the page is connected and the note that they need
// a connection while it is offline; the saved schedules' arrivals are shown
// whatever the connection, with no note. `yourBus`, a `yourBusRow` answer,
// names the row of the chosen journey's first bus, which says "Your bus" in
// text beside its headsign. `canFollow` gives each arrival that names a live
// vehicle a button that asks the map to follow it; focus on one stays on it
// through the rewrite.
export function writeArrivals({element, shown, withKey, yourBus, canFollow}) {
  const focused = focusedVehicleOf(element)
  element.replaceChildren()
  const isScheduled = isScheduledShown(shown)
  let className = NEEDS_CONNECTION_CLASS_NAME

  if (isScheduled) {
    className = ""
  }

  const rows = arrivalRows(shown)

  if (rows.kind === ArrivalRowsKind.note) {
    element.append(textElement({tagName: "p", className: `${NOTE_CLASS_NAME} ${className}`, text: rows.text}))
  } else {
    const list = document.createElement("ul")
    list.className = `${ROWS_CLASS_NAME} ${className}`

    const yourIndex = yourBusIndexOf(yourBus)

    for (const [index, row] of rows.rows.entries()) {
      list.append(arrivalRowElement({row, tagName: "li", isYours: index === yourIndex, canFollow}))
    }

    element.append(list)

    if (withKey) {
      const key = keyElement(shown)
      key.classList.toggle(NEEDS_CONNECTION_CLASS_NAME, !isScheduled)
      element.append(key)
    }
  }

  if (!isScheduled) {
    const note = classedParagraph({text: "", className: OFFLINE_NOTE_CLASS_NAME})
    appendMessage({element: note, message: ARRIVALS_NEED_CONNECTION})
    element.append(note)
  }

  restoreFocus({element, focused})
}

// The index of the row `yourBus` names; no index a row has where it names none.
function yourBusIndexOf(yourBus) {
  if (yourBus.kind === YourBusKind.row) {
    return yourBus.index
  }

  return NO_ROW_INDEX
}

function classedParagraph({text, className}) {
  const paragraph = document.createElement("p")
  paragraph.textContent = text
  paragraph.className = className
  return paragraph
}
