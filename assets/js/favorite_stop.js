import {favoriteHolder, holdStop, releaseStop} from "./stop_holds"
import {appendParagraph, writeArrivals} from "./stop_arrivals"

// The rider's favorite stops, which this browser keeps in its local storage
// as each stop's identifier and name, in the order they were added, and the
// panel that shows each one's next arrivals whatever the page's filter keeps
// and wherever its map is. Each favorite's stop is open for the server while
// the panel shows it, as an open popup's stop is, so its arrivals come with
// the "stop-arrivals:arrivals" event.

const storageKey = "gobusgo:favorite-stops"
const elementId = "favorite-stop"
export const changeEventName = "gobusgo:favorite-stops-change"
// The next bus, and enough after it to choose between two routes.
const arrivalCountMax = 3
const removeLabelPrefix = "Remove favorite stop"
const entryClassName = "flex flex-col gap-1 border-t border-slate-200 pt-2 first:border-t-0 first:pt-0"

// The most favorites a rider keeps, which the panel's element carries, or
// none on a page that has no panel.
export function favoriteCountMax() {
  const element = document.getElementById(elementId)

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
    const text = window.localStorage.getItem(storageKey)
    parsed = text === null ? [] : JSON.parse(text)
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
    const favorite = favoriteOf(entry)
    const isNew = favorite !== null && favorites.every((kept) => kept.stopId !== favorite.stopId)

    if (isNew) {
      favorites.push(favorite)
    }
  }

  return favorites
}

function favoriteOf(value) {
  const isObject = typeof value === "object" && value !== null
  const hasStopId = isObject && typeof value.stopId === "string" && value.stopId !== ""
  const isFavorite = hasStopId && typeof value.name === "string"

  if (isFavorite) {
    return {stopId: value.stopId, name: value.name}
  } else {
    return null
  }
}

// Stores `favorites` and announces them on the window with the
// "gobusgo:favorite-stops-change" event.
function storeFavorites(favorites) {
  try {
    window.localStorage.setItem(storageKey, JSON.stringify(favorites))
  } catch (error) {
    console.warn("Favorite stops not stored", error)
  }

  window.dispatchEvent(new CustomEvent(changeEventName, {detail: {favorites}}))
}

// Adds `favorite`, a stop's identifier and name, after the rider's other
// favorites. A stop that is a favorite already, or a favorite beyond the
// most a rider keeps, changes nothing.
export function addFavorite(favorite) {
  const favorites = storedFavorites()
  const isNew = favorites.every((kept) => kept.stopId !== favorite.stopId)
  const hasRoom = favorites.length < favoriteCountMax()

  if (isNew && hasRoom) {
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
    return {...shown, arrivals: shown.arrivals.slice(0, arrivalCountMax)}
  } else {
    return shown
  }
}

// The entry of `favorite` in the panel, with the element its arrivals are
// written into. Its content is built as text nodes: a stop's name comes from
// outside the application and is never parsed as HTML.
function entryOf(favorite) {
  const element = document.createElement("div")
  element.className = entryClassName

  const header = document.createElement("div")
  header.className = "flex items-start justify-between gap-2"

  const title = document.createElement("div")
  title.className = "font-semibold"
  appendParagraph(title, favorite.name)

  const remove = document.createElement("button")
  remove.type = "button"
  remove.className = "close-button shrink-0"
  remove.setAttribute("aria-label", `${removeLabelPrefix} ${favorite.name}`)
  remove.textContent = "×"
  remove.addEventListener("click", () => { removeFavorite(favorite.stopId) })

  header.append(title, remove)

  const arrivalsElement = document.createElement("div")
  writeArrivals(arrivalsElement, {status: "waiting"})
  element.append(header, arrivalsElement)

  return {element, arrivalsElement}
}

// The hook of the panel. The server renders the panel hidden and leaves its
// content to the hook, which shows it while the rider has a favorite.
export const FavoriteStop = {
  mounted() {
    // The entry of each favorite the panel shows, by stop identifier.
    this.entries = new Map()
    this.push = (event, payload) => { this.pushEvent(event, payload) }

    this.onChange = (event) => { this.show(event.detail.favorites) }
    window.addEventListener(changeEventName, this.onChange)

    this.handleEvent("stop-arrivals:arrivals", (shown) => {
      const entry = this.entries.get(shown.stop_id)

      if (entry !== undefined) {
        writeArrivals(entry.arrivalsElement, shownInPanel(shown))
      }
    })

    this.show(storedFavorites())
  },

  // The page that connects again knows nothing of the stops this hook has
  // open, and is told them again.
  reconnected() {
    for (const stopId of this.entries.keys()) {
      holdStop({pushEvent: this.push, stopId, holder: favoriteHolder})
    }
  },

  // Shows `favorites` in the panel, in their order, and hides it when there
  // is none. A favorite shown before keeps its entry and its arrivals; the
  // stop of a favorite that is gone is let go of, and that of a new one is
  // opened for the server.
  show(favorites) {
    const entries = new Map()

    for (const favorite of favorites) {
      let entry = this.entries.get(favorite.stopId)

      if (entry === undefined) {
        entry = entryOf(favorite)
        holdStop({pushEvent: this.push, stopId: favorite.stopId, holder: favoriteHolder})
      }

      entries.set(favorite.stopId, entry)
    }

    for (const stopId of this.entries.keys()) {
      if (entries.has(stopId) === false) {
        releaseStop({pushEvent: this.push, stopId, holder: favoriteHolder})
      }
    }

    this.entries = entries
    this.el.replaceChildren(...Array.from(entries.values(), (entry) => entry.element))
    this.el.hidden = entries.size === 0
  },

  destroyed() {
    window.removeEventListener(changeEventName, this.onChange)
  }
}
