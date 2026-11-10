// The callout a tap on a marker opens on the map: one at a time, for the
// stop, the vehicle, or the shared vehicle the rider chose last. Opening a
// callout closes the one before it, and a tap on the map closes it. A stop's
// or a vehicle's callout is a button that shows its item in the details
// view again, and has no close button, since the view's back button closes
// it. Its content is built as text nodes: the names come from outside the
// application and are never parsed as HTML.

import {calloutNameSuffix} from "./callout_text"
import {chipElements} from "./route_chips"
import {ArrivalRowsKind, NEEDS_CONNECTION_CLASS_NAME, liveDot} from "./stop_arrivals"

/** The class of every callout's popup. */
export const CALLOUT_CLASS_NAME = "map-callout"
const BUTTON_CLASS_NAME = "map-callout-button"
const TITLE_CLASS_NAME = "map-callout-title"
const DETAIL_CLASS_NAME = "map-callout-detail"
const ROWS_CLASS_NAME = "map-callout-rows"
const ROW_CLASS_NAME = "map-callout-row"
const HEADSIGN_CLASS_NAME = "map-callout-headsign"
const TIME_CLASS_NAME = "map-callout-time"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
// The widest a callout stands on the map, so a long headsign wraps.
const CALLOUT_WIDTH_MAX = "240px"

// The callout that is open, with the item it is of, or null while none is.
let open = null

/**
 * Opens a callout over `map`, at `lngLat`, holding `content`, for `item`,
 * a kind and an identifier, in place of the callout that was open. A callout
 * with `closeButton` has one; any other closes with a tap on the map or
 * with `closeCalloutOf`.
 */
export function openCallout({map, maplibre, lngLat, content, item, closeButton}) {
  closeCallout()

  const popup = new maplibre.Popup({
    className: CALLOUT_CLASS_NAME,
    closeButton,
    closeOnClick: true,
    focusAfterOpen: true,
    maxWidth: CALLOUT_WIDTH_MAX
  })
    .setLngLat(lngLat)
    .setDOMContent(content)

  const opened = {popup, item}

  popup.on("close", () => {
    if (open === opened) {
      open = null
    }
  })

  open = opened
  popup.addTo(map)
}

/** Closes the callout that is open, if any. */
export function closeCallout() {
  if (open !== null) {
    open.popup.remove()
  }
}

function isCalloutOf({kind, id}) {
  const isKind = open !== null && open.item.kind === kind
  return isKind && open.item.id === id
}

/** Closes the callout of the item of `kind` and `id`, and leaves any other open. */
export function closeCalloutOf({kind, id}) {
  if (isCalloutOf({kind, id})) {
    closeCallout()
  }
}

/** Writes `content` into the callout of the item of `kind` and `id`; any other is left as it is. */
export function updateCalloutOf({kind, id, content}) {
  if (isCalloutOf({kind, id})) {
    open.popup.setDOMContent(content)
  }
}

// Appends `children` to `element` with a space between each two. A flex
// container lays out no text of white space alone, and the accessible name
// reads the space, so its words stay apart.
function appendSpaced({element, children}) {
  for (const [index, child] of children.entries()) {
    if (index > 0) {
      element.append(" ")
    }

    element.append(child)
  }
}

// A callout's button: its visible children, then hidden text that names
// `detailName` and the `action` a press takes, which hands the item to
// `onSelect`.
function calloutButton({children, detailName, action, onSelect}) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = BUTTON_CLASS_NAME
  appendSpaced({element: button, children})

  const suffix = document.createElement("span")
  suffix.className = HIDDEN_TEXT_CLASS_NAME
  suffix.textContent = calloutNameSuffix({detailName, action})
  button.append(suffix)
  button.addEventListener("click", onSelect)
  return button
}

function textElement({tagName, className, text}) {
  const element = document.createElement(tagName)
  element.className = className
  element.textContent = text
  return element
}

/**
 * A vehicle's callout: `title` and, under it, `detail` where it has text.
 * Its accessible name also names `detailName`, the status a badge shows.
 */
export function vehicleCalloutContent({title, detail, detailName, onSelect}) {
  const children = [textElement({tagName: "span", className: TITLE_CLASS_NAME, text: title})]

  if (detail !== "") {
    children.push(textElement({tagName: "span", className: DETAIL_CLASS_NAME, text: detail}))
  }

  const content = document.createElement("div")
  content.append(calloutButton({children, detailName, action: "show the vehicle", onSelect}))
  return content
}

/**
 * A stop's callout: its `name` and, under it, the element its next arrivals
 * are written into with `writeCalloutArrivals`, which starts empty. The
 * arrivals are live, so the stylesheet hides them while the page is offline.
 */
export function stopCalloutContent({name, onSelect}) {
  const title = textElement({tagName: "span", className: TITLE_CLASS_NAME, text: name})
  const arrivalsElement = document.createElement("span")
  arrivalsElement.className = `${ROWS_CLASS_NAME} ${NEEDS_CONNECTION_CLASS_NAME}`

  const content = document.createElement("div")
  content.append(calloutButton({children: [title, arrivalsElement], detailName: "", action: "show the stop", onSelect}))
  return {content, arrivalsElement}
}

function chipOf({route, color}) {
  const chips = []

  if (route !== null) {
    chips.push({name: route, color})
  }

  return chips
}

// One arrival's row: its route's chip, its headsign, and how soon, with the
// live dot beside a live time.
function rowElement({route, color, headsign, time, isLive}) {
  const row = document.createElement("span")
  row.className = ROW_CLASS_NAME
  const children = chipElements({chips: chipOf({route, color}), countMax: 1, emptyText: ""})

  let headsignText = ""

  if (headsign !== null) {
    headsignText = headsign
  }

  children.push(textElement({tagName: "span", className: HEADSIGN_CLASS_NAME, text: headsignText}))

  const timeElement = textElement({tagName: "span", className: TIME_CLASS_NAME, text: time})

  if (isLive) {
    timeElement.append(liveDot())
  }

  children.push(timeElement)
  appendSpaced({element: row, children})
  return row
}

/**
 * Writes `rows`, what `arrivalRows` gives for a stop's arrivals, into the
 * arrivals element of a stop's callout: a row per arrival, or the note in
 * their place.
 */
export function writeCalloutArrivals({element, rows}) {
  element.replaceChildren()

  if (rows.kind === ArrivalRowsKind.note) {
    element.append(textElement({tagName: "span", className: DETAIL_CLASS_NAME, text: rows.text}))
    return
  }

  const rowElements = Array.from(rows.rows, rowElement)
  appendSpaced({element, children: rowElements})
}
