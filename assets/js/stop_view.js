// The stop view of the panel sheet's details view: a stop's texts, its
// routes, the favorite button, the lines of its alerts, and its arrivals.
// Its content is built as text nodes: a stop's texts come from outside the
// application and are never parsed as HTML.

import {alertLines} from "./service_alerts"
import {chipElements} from "./route_chips"
import {appendParagraph, writeArrivals} from "./stop_arrivals"
import {
  addFavorite,
  favoriteCountMax,
  favoritesFullText,
  removeFavorite,
  storedFavorites
} from "./favorite_stop"

const NOT_SUPPLIED = "Not supplied"
const CHIP_ROW_CLASS_NAME = "panel-detail-chips"
const FACTS_CLASS_NAME = "panel-detail-facts"
const ACTIONS_CLASS_NAME = "panel-detail-actions"
const ACTION_CLASS_NAME = "panel-detail-action"
const ALERTS_CLASS_NAME = "panel-detail-alerts"
const ARRIVALS_CLASS_NAME = "panel-detail-arrivals"
const FAVORITE_TEXT = "★ Your favorite stop"
const NOT_FAVORITE_TEXT = "☆ Make this your favorite stop"

export function suppliedText(value) {
  const isSupplied = typeof value === "string" && value !== ""

  if (isSupplied) {
    return value
  } else {
    return NOT_SUPPLIED
  }
}

// A stop's name, or its identifier for a stop the source names no name for.
export function suppliedName(stop) {
  const isNamed = typeof stop.name === "string" && stop.name !== ""

  if (isNamed) {
    return stop.name
  } else {
    return stop.id
  }
}

function isFavoriteStop(stopId) {
  return storedFavorites().some((favorite) => favorite.stopId === stopId)
}

// What the favorite button of the stop `stopId` shows while the rider's
// favorites are `favorites`.
function favoriteButtonState({stopId, favorites}) {
  const isFavorite = favorites.some((favorite) => favorite.stopId === stopId)
  const isFull = isFavorite === false && favorites.length >= favoriteCountMax()
  let text = NOT_FAVORITE_TEXT

  if (isFavorite) {
    text = FAVORITE_TEXT
  } else if (isFull) {
    text = favoritesFullText(favoriteCountMax())
  }

  return {text, disabled: isFull, pressed: String(isFavorite)}
}

// Writes into `button` what the favorite button of `stopId` shows while
// the rider's favorites are `favorites`.
export function writeFavoriteButton({button, stopId, favorites}) {
  const shown = favoriteButtonState({stopId, favorites})
  button.replaceChildren(shown.text)
  button.toggleAttribute("disabled", shown.disabled)
  button.setAttribute("aria-pressed", shown.pressed)
}

// The button that makes the stop one of the rider's favorites, or removes
// it when it is one already. A stop the source names no name for is stored
// under its identifier. A rider with every favorite taken removes one
// before adding another.
function favoriteButtonOf(stop) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = ACTION_CLASS_NAME
  button.addEventListener("click", () => {
    if (isFavoriteStop(stop.id)) {
      removeFavorite(stop.id)
    } else {
      addFavorite({stopId: stop.id, name: suppliedName(stop)})
    }
  })

  writeFavoriteButton({button, stopId: stop.id, favorites: storedFavorites()})
  return button
}

// The view of `stop`, with its favorite button and the element its
// arrivals are written into, which says that it is waiting for them. The
// actions row holds the favorite button and room for more actions on the
// stop. The current alerts of the stop's routes, those of a route as a
// whole and those that name the stop, stand between the actions and the
// arrivals.
export function stopViewElements(stop) {
  const content = document.createElement("div")

  const chips = document.createElement("div")
  chips.className = CHIP_ROW_CLASS_NAME
  const chipCount = stop.routeChips.length

  for (const element of chipElements({chips: stop.routeChips, countMax: chipCount, emptyText: ""})) {
    chips.append(element)
  }

  const facts = document.createElement("div")
  facts.className = FACTS_CLASS_NAME
  const lines = [
    `Stop code: ${suppliedText(stop.code)}`,
    `Direction: ${suppliedText(stop.direction)}`,
    `Routes: ${suppliedText(stop.routes)}`,
    `Agencies: ${suppliedText(stop.agencies)}`
  ]

  for (const line of lines) {
    appendParagraph(facts, line)
  }

  const actions = document.createElement("div")
  actions.className = ACTIONS_CLASS_NAME
  const favoriteButton = favoriteButtonOf(stop)
  actions.append(favoriteButton)

  const alerts = document.createElement("div")
  alerts.className = ALERTS_CLASS_NAME
  for (const alertLine of alertLines({routeIds: stop.routeIds, stopId: stop.id})) {
    alerts.append(alertLine)
  }

  const arrivalsElement = document.createElement("div")
  arrivalsElement.className = ARRIVALS_CLASS_NAME
  writeArrivals(arrivalsElement, {status: "waiting"})

  content.append(chips, facts, actions, alerts, arrivalsElement)
  return {content, favoriteButton, arrivalsElement}
}
