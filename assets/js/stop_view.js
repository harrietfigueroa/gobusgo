// The stop view of the panel sheet's details view, in the glanceable style:
// pills of the stop's code and direction beside the favorite button, its
// routes' chips over a muted caption of their agencies, its trip buttons,
// the lines of its alerts, and its arrivals as rows; and the list of the
// stops under a tap, which opens one of them. Its content is built
// as text nodes: a stop's texts come from outside the application and are
// never parsed as HTML.

import {alertLines} from "./service_alerts"
import {chipElements} from "./route_chips"
import {CHIP_COUNT_MAX} from "./stop_marker_shapes"
import {writeArrivals} from "./stop_arrivals"
import {PillKind, codePill, directionPill, stopListRestText} from "./stop_text"
import {
  addFavorite,
  favoriteCountMax,
  favoritesFullText,
  removeFavorite,
  storedFavorites
} from "./favorite_stop"
import {tripEndButtons} from "./trip_ends"
import {ChosenKind, chosenJourney} from "./chosen_journey"
import {NO_YOUR_BUS, StopMarkKind, stopMark} from "./journey_stop_marks"
import {tripLineElement, writeTripLineText} from "./trip_line"

const HEADER_CLASS_NAME = "panel-detail-header"
const PILLS_CLASS_NAME = "panel-detail-pills"
const PILL_CLASS_NAME = "panel-detail-pill"
const FAVORITE_CLASS_NAME = "panel-detail-favorite"
const FULL_NOTE_CLASS_NAME = "panel-detail-caption"
const CHIP_ROW_CLASS_NAME = "panel-detail-chips"
const CAPTION_CLASS_NAME = "panel-detail-caption"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
const CODE_SPOKEN_PREFIX = "Stop code "
const DIRECTION_SPOKEN_PREFIX = "Direction "
const ACTIONS_CLASS_NAME = "panel-detail-actions"
const ACTION_CLASS_NAME = "panel-detail-action"
const ALERTS_CLASS_NAME = "panel-detail-alerts"
const ARRIVALS_CLASS_NAME = "panel-detail-arrivals"
const STOP_LIST_CLASS_NAME = "panel-detail-stop-list"
const STOP_ROW_CLASS_NAME = "panel-detail-stop-row"
const STOP_ROW_CHIPS_CLASS_NAME = "panel-detail-stop-row-chips"
const STOP_ROW_NAME_CLASS_NAME = "panel-detail-stop-row-name"
const STOP_LIST_REST_CLASS_NAME = "panel-detail-caption"
const FAVORITE_MARK = "★"
const NOT_FAVORITE_MARK = "☆"
const FAVORITE_LABEL = "Your favorite stop"
const NOT_FAVORITE_LABEL = "Make this your favorite stop"

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
// favorites are `favorites`: a star, filled for a favorite, its accessible
// name, and the note that stands under the header while every favorite is
// taken, empty otherwise.
function favoriteButtonState({stopId, favorites}) {
  const isFavorite = favorites.some((favorite) => favorite.stopId === stopId)
  const isFull = isFavorite === false && favorites.length >= favoriteCountMax()
  let mark = NOT_FAVORITE_MARK
  let label = NOT_FAVORITE_LABEL
  let note = ""

  if (isFavorite) {
    mark = FAVORITE_MARK
    label = FAVORITE_LABEL
  } else if (isFull) {
    label = favoritesFullText(favoriteCountMax())
    note = label
  }

  return {mark, label, note, disabled: isFull, pressed: String(isFavorite)}
}

// Writes into `button`, and into `note`, the line under the header, what
// the favorite button of `stopId` shows while the rider's favorites are
// `favorites`.
export function writeFavoriteButton({button, note, stopId, favorites}) {
  const shown = favoriteButtonState({stopId, favorites})
  button.replaceChildren(shown.mark)
  button.setAttribute("aria-label", shown.label)
  button.setAttribute("title", shown.label)
  button.toggleAttribute("disabled", shown.disabled)
  button.setAttribute("aria-pressed", shown.pressed)
  note.replaceChildren(shown.note)
  note.toggleAttribute("hidden", shown.note === "")
}

// The button that makes the stop one of the rider's favorites, or removes
// it when it is one already. A stop the source names no name for is stored
// under its identifier. A rider with every favorite taken removes one
// before adding another.
function favoriteButtonOf({stop, note}) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = FAVORITE_CLASS_NAME
  button.addEventListener("click", () => {
    if (isFavoriteStop(stop.id)) {
      removeFavorite(stop.id)
    } else {
      addFavorite({stopId: stop.id, name: suppliedName(stop)})
    }
  })

  writeFavoriteButton({button, note, stopId: stop.id, favorites: storedFavorites()})
  return button
}

// The element of `pill`, its mark and its text: the mark hidden from
// assistive technology, and a hidden `spokenPrefix` that says what it is.
function pillElement({pill, spokenPrefix}) {
  const element = document.createElement("span")
  element.className = PILL_CLASS_NAME

  const spoken = document.createElement("span")
  spoken.className = HIDDEN_TEXT_CLASS_NAME
  spoken.textContent = spokenPrefix
  element.append(spoken)

  if (pill.mark !== "") {
    const mark = document.createElement("span")
    mark.setAttribute("aria-hidden", "true")
    mark.textContent = pill.mark
    element.append(mark, " ")
  }

  element.append(pill.text)
  return element
}

// The pills of a stop's code and direction, as a `span` so they stand in
// the stop list's buttons, which hold phrasing content alone.
function pillsElement(stop) {
  const pills = document.createElement("span")
  pills.className = PILLS_CLASS_NAME
  const code = codePill(stop.code)
  const direction = directionPill(stop.direction)

  if (code.kind === PillKind.shown) {
    pills.append(pillElement({pill: code, spokenPrefix: CODE_SPOKEN_PREFIX}))
  }

  if (direction.kind === PillKind.shown) {
    pills.append(pillElement({pill: direction, spokenPrefix: DIRECTION_SPOKEN_PREFIX}))
  }

  return pills
}

// What the chosen journey does at the stop `stopId`, as `stopMark` says;
// none while no journey is chosen.
export function chosenStopMark(stopId) {
  const chosen = chosenJourney()

  if (chosen.kind === ChosenKind.none) {
    return {kind: StopMarkKind.none}
  }

  return stopMark({chosen, stopId})
}

// Writes into `line`, the control at the top of a stop's view, what the
// chosen journey does at `stopId`, or hides it where the journey does
// nothing there.
export function writeTripLine({line, stopId}) {
  const mark = chosenStopMark(stopId)
  let text = ""

  if (mark.kind !== StopMarkKind.none) {
    text = mark.text
  }

  writeTripLineText({line, text})
}

// The list of the stops under a tap, `stops`, nearest first: one button a
// finger's height per stop, with the stop's route chips, its name, and the
// pills of its code and direction, which calls `onChoose` with the stop,
// and a line that counts the `restCount` stops the list leaves out.
export function stopListElement({stops, restCount, onChoose}) {
  const list = document.createElement("ul")
  list.className = STOP_LIST_CLASS_NAME

  for (const stop of stops) {
    const chips = document.createElement("span")
    chips.className = STOP_ROW_CHIPS_CLASS_NAME

    for (const element of chipElements({chips: stop.routeChips, countMax: CHIP_COUNT_MAX, emptyText: ""})) {
      chips.append(element)
    }

    const name = document.createElement("span")
    name.className = STOP_ROW_NAME_CLASS_NAME
    name.textContent = suppliedName(stop)

    const button = document.createElement("button")
    button.type = "button"
    button.className = STOP_ROW_CLASS_NAME
    button.append(chips, name, pillsElement(stop))
    button.addEventListener("click", () => { onChoose(stop) })

    const item = document.createElement("li")
    item.append(button)
    list.append(item)
  }

  if (restCount > 0) {
    const rest = document.createElement("li")
    rest.className = STOP_LIST_REST_CLASS_NAME
    rest.textContent = stopListRestText(restCount)
    list.append(rest)
  }

  return list
}

// The view of `stop`, with its favorite button, the note under its header,
// and the element its arrivals are written into, which says that it is
// waiting for them. The
// header holds the pills and the favorite button, and the actions row the
// stop's "From here" and "To here". The current alerts of the stop's
// routes, those of a route as a whole and those that name the stop, stand
// between the actions and the arrivals.
export function stopViewElements(stop) {
  const content = document.createElement("div")

  const chips = document.createElement("div")
  chips.className = CHIP_ROW_CLASS_NAME
  const chipCount = stop.routeChips.length

  for (const element of chipElements({chips: stop.routeChips, countMax: chipCount, emptyText: ""})) {
    chips.append(element)
  }

  const note = document.createElement("p")
  note.className = FULL_NOTE_CLASS_NAME
  const favoriteButton = favoriteButtonOf({stop, note})

  const header = document.createElement("div")
  header.className = HEADER_CLASS_NAME
  header.append(pillsElement(stop), favoriteButton)

  const routes = document.createElement("div")
  routes.append(chips)

  // The agencies stand under the chips where the source names them.
  const hasAgencies = typeof stop.agencies === "string" && stop.agencies !== ""

  if (hasAgencies) {
    const caption = document.createElement("p")
    caption.className = CAPTION_CLASS_NAME
    caption.textContent = stop.agencies
    routes.append(caption)
  }

  const actions = document.createElement("div")
  actions.className = ACTIONS_CLASS_NAME

  for (const tripButton of tripEndButtons({stopId: stop.id, name: suppliedName(stop), className: ACTION_CLASS_NAME})) {
    actions.append(tripButton)
  }

  const alerts = document.createElement("div")
  alerts.className = ALERTS_CLASS_NAME
  for (const alertLine of alertLines({routeIds: stop.routeIds, stopId: stop.id})) {
    alerts.append(alertLine)
  }

  const arrivalsElement = document.createElement("div")
  arrivalsElement.className = ARRIVALS_CLASS_NAME
  writeArrivals({element: arrivalsElement, shown: {status: "waiting"}, withKey: true, yourBus: NO_YOUR_BUS, canFollow: false})

  const tripLine = tripLineElement()
  writeTripLine({line: tripLine, stopId: stop.id})

  content.append(tripLine, header, note, routes, actions, alerts, arrivalsElement)
  return {content, favoriteButton, note, arrivalsElement, tripLine}
}
