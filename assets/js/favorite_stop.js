import {FAVORITE_HOLDER, holdStop, releaseStop} from "./stop_holds"
import {appendParagraph, nextArrivalText, writeArrivals} from "./stop_arrivals"
import {tripEndButtons} from "./trip_ends"

// The rider's favorite stops, which this browser keeps in its local storage
// as each stop's identifier and name, in the order they were added, and the
// panel that shows each one's next arrivals whatever the page's filter keeps
// and wherever its map is, with the next arrival at the first favorite in
// the badge of the Favorites tab. Each favorite's stop is open for the
// server while the panel shows it, as an open popup's stop is, so its
// arrivals come with the "stop-arrivals:arrivals" event.

const STORAGE_KEY = "gobusgo:favorite-stops"
const ELEMENT_ID = "favorite-stop"
const BADGE_ID = "favorite-stop-badge"
const EMPTY_TEXT = "No favorite stops yet. Open a stop on the map and choose “☆ Make this your favorite stop”."
export const CHANGE_EVENT_NAME = "gobusgo:favorite-stops-change"
// The next bus, and enough after it to choose between two routes.
const ARRIVAL_COUNT_MAX = 3
const REMOVE_LABEL_PREFIX = "Remove favorite stop"
const ACTIONS_CLASS_NAME = "panel-detail-actions"
const ACTION_CLASS_NAME = "panel-detail-action"
const ENTRY_CLASS_NAME ="flex flex-col gap-1 border-t border-slate-200 pt-2 first:border-t-0 first:pt-0"

// The kinds of a stored entry read back as a favorite.
const EntryKind = Object.freeze({favorite: "favorite", malformed: "malformed"})

// The most favorites a rider keeps, which the panel's element carries, or
// none on a page that has no panel.
export function favoriteCountMax() {
  const element = document.getElementById(ELEMENT_ID)

  if (element === null) {
    return 0
  } else {
    return Number(element.dataset.favoriteCountMax)
  }
}

// The text of a popup's button while every favorite is taken.
export function favoritesFullText(countMax) {
  return `${countMax} favorite stops already; remove one to add this stop`
}

// The favorites this browser stored, at most the most a rider keeps, each
// once. Reading throws where storage is blocked, such as a private window,
// and parsing throws for text that is not JSON; both read as no favorite,
// and an entry of another shape is left out.
export function storedFavorites() {
  let parsed

  try {
    const text = window.localStorage.getItem(STORAGE_KEY)

    if (text === null) {
      parsed = []
    } else {
      parsed = JSON.parse(text)
    }
  } catch (error) {
    console.warn("Stored favorite stops not readable", error)
    return []
  }

  return favoritesOf(parsed)
}

function favoritesOf(value) {
  const favorites = []

  if (Array.isArray(value) === false) {
    return favorites
  }

  for (const entry of value.slice(0, favoriteCountMax())) {
    const read = favoriteOf(entry)

    if (read.kind === EntryKind.favorite) {
      const isNew = favorites.every((kept) => kept.stopId !== read.favorite.stopId)

      if (isNew) {
        favorites.push(read.favorite)
      }
    }
  }

  return favorites
}

function favoriteOf(value) {
  const isObject = typeof value === "object" && value !== null
  const hasStopIdText = isObject && typeof value.stopId === "string"
  const hasStopId = hasStopIdText && value.stopId !== ""
  const isFavorite = hasStopId && typeof value.name === "string"

  if (isFavorite) {
    return {kind: EntryKind.favorite, favorite: {stopId: value.stopId, name: value.name}}
  } else {
    return {kind: EntryKind.malformed}
  }
}

// Stores `favorites` and announces them on the window with the
// "gobusgo:favorite-stops-change" event.
function storeFavorites(favorites) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(favorites))
  } catch (error) {
    console.warn("Favorite stops not stored", error)
  }

  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {favorites}}))
}

// Adds `favorite`, a stop's identifier and name, after the rider's other
// favorites. A stop that is a favorite already, or a favorite beyond the
// most a rider keeps, changes nothing.
export function addFavorite(favorite) {
  const favorites = storedFavorites()
  const isNew = favorites.every((kept) => kept.stopId !== favorite.stopId)
  const hasRoom = favorites.length < favoriteCountMax()
  const isAddable = isNew && hasRoom

  if (isAddable) {
    storeFavorites([...favorites, favorite])
  }
}

// Removes the favorite of the stop `stopId`.
export function removeFavorite(stopId) {
  const favorites = storedFavorites()
  const kept = favorites.filter((favorite) => favorite.stopId !== stopId)

  if (kept.length < favorites.length) {
    storeFavorites(kept)
  }
}

// What the panel shows of the server's answer for a favorite: its first
// arrivals.
function shownInPanel(shown) {
  if (shown.status === "arrivals") {
    return {...shown, arrivals: shown.arrivals.slice(0, ARRIVAL_COUNT_MAX)}
  } else {
    return shown
  }
}

// The entry of `favorite` in the panel, with the element its arrivals are
// written into and the stop's "From here" and "To here". Its content is built as text nodes: a stop's name comes from
// outside the application and is never parsed as HTML.
function entryOf(favorite) {
  const element = document.createElement("div")
  element.className = ENTRY_CLASS_NAME

  const header = document.createElement("div")
  header.className = "flex items-start justify-between gap-2"

  const title = document.createElement("div")
  title.className = "font-semibold"
  appendParagraph(title, favorite.name)

  const remove = document.createElement("button")
  remove.type = "button"
  remove.className = "close-button shrink-0"
  remove.setAttribute("aria-label", `${REMOVE_LABEL_PREFIX} ${favorite.name}`)
  remove.textContent = "×"
  remove.addEventListener("click", () => { removeFavorite(favorite.stopId) })

  header.append(title, remove)

  const actions = document.createElement("div")
  actions.className = ACTIONS_CLASS_NAME

  for (const tripButton of tripEndButtons({stopId: favorite.stopId, name: favorite.name, className: ACTION_CLASS_NAME})) {
    actions.append(tripButton)
  }

  const arrivalsElement = document.createElement("div")
  const shown = {status: "waiting"}
  writeArrivals(arrivalsElement, shown)
  element.append(header, arrivalsElement, actions)

  return {element, arrivalsElement, shown}
}

// The hook of the panel. The server renders the panel empty and leaves its
// content to the hook, which lists the favorites, or says there is none.
export const FavoriteStop = {
  mounted() {
    // The entry of each favorite the panel shows, by stop identifier.
    this.entries = new Map()
    this.push = (event, payload) => { this.pushEvent(event, payload) }

    this.onChange = (event) => { this.show(event.detail.favorites) }
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)

    this.handleEvent("stop-arrivals:arrivals", (shown) => {
      const entry = this.entries.get(shown.stop_id)

      if (entry !== undefined) {
        entry.shown = shownInPanel(shown)
        writeArrivals(entry.arrivalsElement, entry.shown)
        this.writeBadge()
      }
    })

    this.show(storedFavorites())
  },

  // The page that connects again knows nothing of the stops this hook has
  // open, and is told them again.
  reconnected() {
    for (const stopId of this.entries.keys()) {
      holdStop({pushEvent: this.push, stopId, holder: FAVORITE_HOLDER})
    }
  },

  // Shows `favorites` in the panel, in their order, or a line that says
  // there is none. A favorite shown before keeps its entry and its
  // arrivals; the stop of a favorite that is gone is let go of, and that of
  // a new one is opened for the server.
  show(favorites) {
    const entries = new Map()

    for (const favorite of favorites) {
      let entry = this.entries.get(favorite.stopId)

      if (entry === undefined) {
        entry = entryOf(favorite)
        holdStop({pushEvent: this.push, stopId: favorite.stopId, holder: FAVORITE_HOLDER})
      }

      entries.set(favorite.stopId, entry)
    }

    for (const stopId of this.entries.keys()) {
      if (entries.has(stopId) === false) {
        releaseStop({pushEvent: this.push, stopId, holder: FAVORITE_HOLDER})
      }
    }

    this.entries = entries

    const elements = document.createDocumentFragment()

    for (const entry of entries.values()) {
      elements.append(entry.element)
    }

    if (entries.size === 0) {
      appendParagraph(elements, EMPTY_TEXT)
    }

    this.el.replaceChildren(elements)
    this.writeBadge()
  },

  // The badge of the Favorites tab: the next arrival at the first favorite,
  // hidden while there is none.
  writeBadge() {
    const badge = document.getElementById(BADGE_ID)

    if (badge === null) {
      return
    }

    const [first] = this.entries.values()
    let text = ""

    if (first !== undefined) {
      text = nextArrivalText(first.shown)
    }

    badge.textContent = text
    badge.hidden = text === ""
  },

  destroyed() {
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
  }
}
