// The arrivals board's list of scheduled departures, drawn in a skeleton it
// fills in place: a heading, the line that says what the list is from, the
// rows, and a status line that is one live region changing only when its
// text does. Every text is a text node: names come from outside the
// application and are never parsed as HTML.

import {element} from "./dom_element.js"
import {appendSpaced, chipElements} from "./route_chips.js"

const HEADING_DEFAULT = "Scheduled departures"
const ROW_CLASS_NAME = "arrival-row"
const ROW_WITH_NOTE_CLASS_NAME = "arrival-row arrival-row-with-note"
const NOTE_CLASS_NAME = "arrival-note arrival-row-note"

function rowElement(row) {
  let className = ROW_CLASS_NAME

  if (row.note !== "") {
    className = ROW_WITH_NOTE_CLASS_NAME
  }

  const item = element({tag: "li", className})
  const chips = chipElements({chips: [{name: row.route, color: row.color}], countMax: 1, emptyText: ""})
  let headsign = ""

  if (row.headsign !== null) {
    headsign = row.headsign
  }

  let time = row.time

  if (row.day !== "") {
    time = `${row.day} ${row.time}`
  }

  const children = [...chips, element({tag: "span", className: "arrival-headsign", text: headsign}), element({tag: "span", className: "arrival-time", text: time})]
  appendSpaced({element: item, children})

  if (row.note !== "") {
    item.append(element({tag: "span", className: NOTE_CLASS_NAME, text: row.note}))
  }

  return item
}

/**
 * The skeleton of the departures in `root`, replacing what it holds. Its
 * `write` takes `{heading, fromLine, status, rows}`: the stop's name or null,
 * the text of what the list is from, the status line, and the rows of
 * `departureRows`.
 */
export function departuresView(root) {
  const heading = element({tag: "h1", className: "mcp-trip-heading", text: HEADING_DEFAULT})
  const fromLine = element({tag: "p", className: "trip-window"})
  const list = element({tag: "ul", className: "arrival-rows"})
  const status = element({tag: "p", className: "arrival-note"})
  status.setAttribute("role", "status")
  root.replaceChildren(heading, fromLine, list, status)

  function setText(target, text) {
    if (target.textContent !== text) {
      target.replaceChildren(text)
    }
  }

  return Object.freeze({
    write({heading: stopName, fromLine: fromText, status: statusText, rows}) {
      let headingText = HEADING_DEFAULT

      if (stopName !== null) {
        headingText = stopName
      }

      setText(heading, headingText)
      setText(fromLine, fromText)
      setText(status, statusText)
      const items = []

      for (const row of rows) {
        items.push(rowElement(row))
      }

      list.replaceChildren(...items)
    }
  })
}
