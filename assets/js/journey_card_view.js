// A journey's card as an element, which the Trip tab and the trip planner app
// share: when to leave and when it arrives, the bar, and the first bus's live
// lateness, with the live dot, or that it is scheduled. Every text is a text
// node, never HTML.

import {barElement} from "./journey_bar"
import {button, element} from "./dom_element"
import {liveDot} from "./stop_arrivals"

const HIDDEN_TEXT_CLASS_NAME = "sr-only"

/** What the bar shows of `row`, a row of `journeyRows`, as text: each ride's route and each walk, in order. */
export function summaryText(row) {
  const parts = []

  for (const part of row.summary) {
    if (part.kind === "ride") {
      parts.push(`route ${part.chip.name}`)
    } else {
      parts.push(part.text)
    }
  }

  return parts.join(", ")
}

/** The card of `card`, a card of `journeyCard`, as a button. */
export function cardElement(card) {
  const item = button({className: "trip-journey"})
  item.dataset.focusKey = `journey:${card.order}`
  const heading = element({tag: "span", className: "trip-journey-heading"})
  heading.append(element({tag: "strong", className: "trip-journey-lead", text: card.leadText}))
  heading.append(element({tag: "span", className: "trip-journey-arrive", text: card.arriveText}))
  const summary = element({tag: "span", className: HIDDEN_TEXT_CLASS_NAME, text: summaryText(card.row)})
  const detail = element({tag: "span", className: "trip-journey-detail"})

  if (card.isLive) {
    detail.append(liveDot())
  }

  detail.append(element({tag: "span", className: "trip-journey-status", text: card.detailText}))
  const badge = element({tag: "span", className: "trip-journey-badge", text: card.row.badgeText})
  badge.classList.toggle("trip-journey-marked", card.row.isMarked)
  detail.append(badge)
  item.append(heading, barElement(card.segments), summary, detail)
  return item
}
