// The stop view of the panel sheet's details view, in the glanceable style:
// pills of the stop's code and direction beside the favorite button, its
// routes' chips over a muted caption of their agencies, its trip buttons,
// the lines of its alerts, and its arrivals as rows. Its content is built
// as text nodes: a stop's texts come from outside the application and are
// never parsed as HTML.

import {alertLines} from "./service_alerts"
import {chipElements} from "./route_chips"
import {writeArrivals} from "./stop_arrivals"
import {PillKind, codePill, directionPill} from "./stop_text"
import {
  addFavorite,
  favoriteCountMax,
  favoritesFullText,
  removeFavorite,
  storedFavorites
} from "./favorite_stop"
import {tripEndButtons} from "./trip_ends"
import {assertCondition} from "./assert"
import {OPEN_EVENT_NAME} from "./panel_sheet"
import {ChosenKind, chosenJourney} from "./chosen_journey"
import {NO_YOUR_BUS, StopMarkKind, stopMark} from "./journey_stop_marks"

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
const TRIP_LINE_CLASS_NAME = "panel-detail-trip"
const TRIP_PLANNER_ID = "trip-planner"
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

function pillsElement(stop) {
  const pills = document.createElement("div")
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
  const isShown = mark.kind !== StopMarkKind.none
  line.toggleAttribute("hidden", !isShown)

  if (isShown) {
    line.replaceChildren(mark.text)
  } else {
    line.replaceChildren()
  }
}

// Opens the Trip tab by the page's open event, sent from the Trip tab's
// panel as the trip strip sends it; the panel takes the view's place.
function openTripTab() {
  const planner = document.getElementById(TRIP_PLANNER_ID)
  assertCondition(planner !== null, "stop view: the page has no Trip tab's panel")
  planner.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true}))
}

// The line at the top of a stop's view that says what the chosen journey
// does at the stop; pressing it opens the Trip tab.
function tripLineElement() {
  const line = document.createElement("button")
  line.type = "button"
  line.className = TRIP_LINE_CLASS_NAME
  line.hidden = true
  line.addEventListener("click", openTripTab)

  return line
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
  writeArrivals({element: arrivalsElement, shown: {status: "waiting"}, withKey: true, yourBus: NO_YOUR_BUS})

  const tripLine = tripLineElement()
  writeTripLine({line: tripLine, stopId: stop.id})

  content.append(tripLine, header, note, routes, actions, alerts, arrivalsElement)
  return {content, favoriteButton, note, arrivalsElement, tripLine}
}
