import {favoriteHolder, holdStop, releaseStop} from "./stop_holds"
import {appendParagraph, writeArrivals} from "./stop_arrivals"

// The rider's favorite stop, which this browser keeps in its local storage
// as the stop's identifier and name, and the panel that shows the stop's
// next arrivals whatever the page's filter keeps and wherever its map is.
// The stop is open for the server while the panel shows it, as an open
// popup's stop is, so its arrivals come with the "stop-arrivals:arrivals"
// event.

const storageKey = "gobusgo:favorite-stop"
export const changeEventName = "gobusgo:favorite-stop-change"
// The next bus, and enough after it to choose between two routes.
const arrivalCountMax = 3
const removeLabel = "Remove favorite stop"

// The favorite this browser stored, or null when it stored none. Reading
// throws where storage is blocked, such as a private window, and parsing
// throws for text that is not JSON; both read as no favorite, as does a
// stored value of another shape.
export function storedFavorite() {
  try {
    const text = window.localStorage.getItem(storageKey)
    return text === null ? null : favoriteOf(JSON.parse(text))
  } catch (error) {
    console.warn("Stored favorite stop not readable", error)
    return null
  }
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

function writeStored(favorite) {
  try {
    if (favorite === null) {
      window.localStorage.removeItem(storageKey)
    } else {
      window.localStorage.setItem(storageKey, JSON.stringify(favorite))
    }
  } catch (error) {
    console.warn("Favorite stop not stored", error)
  }
}

// Makes `favorite`, a stop's identifier and name, the rider's favorite, or
// removes the favorite for null, and announces it on the window with the
// "gobusgo:favorite-stop-change" event.
export function setFavorite(favorite) {
  writeStored(favorite)
  window.dispatchEvent(new CustomEvent(changeEventName, {detail: {favorite}}))
}

// What the panel shows of the server's answer for the favorite: its first
// arrivals.
function shownInPanel(shown) {
  if (shown.status === "arrivals") {
    return {...shown, arrivals: shown.arrivals.slice(0, arrivalCountMax)}
  } else {
    return shown
  }
}

// The hook of the panel. The server renders the panel hidden and leaves its
// content to the hook, which shows it while there is a favorite.
export const FavoriteStop = {
  mounted() {
    this.favorite = null
    this.arrivalsElement = null
    this.push = (event, payload) => { this.pushEvent(event, payload) }

    this.onChange = (event) => { this.show(event.detail.favorite) }
    window.addEventListener(changeEventName, this.onChange)

    this.handleEvent("stop-arrivals:arrivals", (shown) => {
      const isFavorite = this.favorite !== null && shown.stop_id === this.favorite.stopId

      if (isFavorite) {
        writeArrivals(this.arrivalsElement, shownInPanel(shown))
      }
    })

    this.show(storedFavorite())
  },

  // The page that connects again knows nothing of the stop this hook has
  // open, and is told it again.
  reconnected() {
    if (this.favorite !== null) {
      holdStop({pushEvent: this.push, stopId: this.favorite.stopId, holder: favoriteHolder})
    }
  },

  // Shows `favorite` in the panel, or hides the panel for null, and opens
  // its stop for the server in place of the stop shown before.
  show(favorite) {
    const earlier = this.favorite

    if (earlier !== null) {
      releaseStop({pushEvent: this.push, stopId: earlier.stopId, holder: favoriteHolder})
    }

    this.favorite = favorite

    if (favorite === null) {
      this.arrivalsElement = null
      this.el.replaceChildren()
      this.el.hidden = true
    } else {
      this.writePanel(favorite)
      this.el.hidden = false
      holdStop({pushEvent: this.push, stopId: favorite.stopId, holder: favoriteHolder})
    }
  },

  // The panel's content is built as text nodes: a stop's name comes from
  // outside the application and is never parsed as HTML.
  writePanel(favorite) {
    const header = document.createElement("div")
    header.className = "flex items-start justify-between gap-2"

    const title = document.createElement("div")
    title.className = "font-semibold"
    appendParagraph(title, favorite.name)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "close-button shrink-0"
    remove.setAttribute("aria-label", removeLabel)
    remove.textContent = "×"
    remove.addEventListener("click", () => { setFavorite(null) })

    header.append(title, remove)

    this.arrivalsElement = document.createElement("div")
    writeArrivals(this.arrivalsElement, {status: "waiting"})
    this.el.replaceChildren(header, this.arrivalsElement)
  },

  destroyed() {
    window.removeEventListener(changeEventName, this.onChange)
  }
}
