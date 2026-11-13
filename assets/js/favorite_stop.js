import {FAVORITE_HOLDER, holdStop, releaseStop} from "./stop_holds"
import {isNextArrivalLive, liveDot, nextArrivalText, writeArrivals} from "./stop_arrivals"
import {shownAt} from "./arrival_countdown"
import {NO_YOUR_BUS} from "./journey_stop_marks"
import {startArrivalTicker} from "./arrival_ticker"
import {tripEndButtons} from "./trip_ends"
import {FavoriteChangeKind, storedSettings} from "./stored_settings"
import {FIT_EVENT_DATA, READY_EVENT_NAME} from "./basemap"
import {COLLAPSE_EVENT_NAME, sheetInsets} from "./panel_sheet"
import {EMPTY_MESSAGE, dropIndex, FAVORITE_ZOOM_MIN, favoriteCamera, moveButtonsOf, moveText} from "./favorite_list"
import {appendMessage} from "./message"
import {pageEvents} from "./page_events"

// The rider's favorite stops, which the stored settings module keeps as
// each stop's identifier and name, in the rider's order, and the panel that
// shows each one's next arrivals whatever the page's filter keeps and
// wherever its map is, with the next arrival at the first favorite in the
// badge of the Favorites tab. Each favorite's stop is open for the server
// while the panel shows it, as the selected stop is, so its arrivals
// come with the "stop-arrivals:arrivals" event, and count down between
// events from each arrival's time.

const ELEMENT_ID = "favorite-stop"
const BADGE_ID = "favorite-stop-badge"
export const CHANGE_EVENT_NAME = "gobusgo:favorite-stops-change"
const POSITION_EVENT_NAME = "stop:position"
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"
// The next bus, and enough after it to choose between two routes.
const ARRIVAL_COUNT_MAX = 3
const REMOVE_LABEL_PREFIX = "Remove favorite stop"
const ACTIONS_CLASS_NAME = "panel-detail-actions"
const ACTION_CLASS_NAME = "panel-detail-action"
const ENTRY_CLASS_NAME = "flex flex-col gap-1 border-t border-slate-200 pt-2 first:border-t-0 first:pt-0"
const DRAGGING_CLASS_NAME = "favorite-stop-dragging"
const MOVE_UP_STEP = -1
const MOVE_DOWN_STEP = 1
const HALVING_DIVISOR = 2

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

// The text of the stop view's favorite button while every favorite is taken.
export function favoritesFullText(countMax) {
  return `${countMax} favorite stops already; remove one to add this stop`
}

// The favorites this browser stored, at most the most a rider keeps, each
// once.
export function storedFavorites() {
  return storedSettings.listFavorites(favoriteCountMax())
}

// Announces a change of the favorites on the window with the
// "gobusgo:favorite-stops-change" event.
function announceChange(change) {
  if (change.kind === FavoriteChangeKind.changed) {
    window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {favorites: change.favorites}}))
  }
}

// Adds `favorite`, a stop's identifier and name, after the rider's other
// favorites. A stop that is a favorite already, or a favorite beyond the
// most a rider keeps, changes nothing.
export function addFavorite(favorite) {
  const change = storedSettings.addFavorite({favorite, countMax: favoriteCountMax()})
  announceChange(change)
}

// Removes the favorite of the stop `stopId`.
export function removeFavorite(stopId) {
  const change = storedSettings.removeFavorite({stopId, countMax: favoriteCountMax()})
  announceChange(change)
}

// Moves the favorite of the stop `stopId` to `index` among the favorites.
function moveFavorite({stopId, index}) {
  const change = storedSettings.moveFavorite({stopId, index, countMax: favoriteCountMax()})
  announceChange(change)
}

// Writes what the panel shows of the server's answer for a favorite at
// `nowMs`: its first arrivals still to come.
function writeEntryArrivals({entry, nowMs}) {
  const shown = shownAt({shown: entry.shown, nowMs, countMax: ARRIVAL_COUNT_MAX})
  writeArrivals({element: entry.arrivalsElement, shown, withKey: false, yourBus: NO_YOUR_BUS, canFollow: false})
}

function iconButton({text, label, className}) {
  const element = document.createElement("button")
  element.type = "button"
  element.className = className
  element.setAttribute("aria-label", label)
  element.textContent = text
  return element
}

// The entry of `favorite` in the panel: a drag handle, the stop's name,
// which centers the map on it, its move and remove buttons, the element
// its arrivals are written into, and the stop's "From here" and "To here".
// Its content is built as text nodes: a stop's name comes from outside the
// application and is never parsed as HTML.
function entryOf({favorite, callbacks}) {
  const element = document.createElement("div")
  element.className = ENTRY_CLASS_NAME

  const header = document.createElement("div")
  header.className = "flex items-center gap-1"

  // The handle is for a pointer alone; the move buttons do the same from
  // the keyboard and for assistive technology.
  const handle = document.createElement("span")
  handle.className = "favorite-stop-handle"
  handle.setAttribute("aria-hidden", "true")
  handle.textContent = "⠿"
  handle.addEventListener("pointerdown", (event) => { callbacks.onDragStart({event, element}) })

  const title = document.createElement("button")
  title.type = "button"
  title.className = "favorite-stop-name"
  title.setAttribute("aria-label", `${favorite.name}: show on the map`)
  title.textContent = favorite.name
  title.addEventListener("click", () => { callbacks.onChoose() })

  const up = iconButton({text: "↑", label: `Move ${favorite.name} up`, className: "favorite-stop-move"})
  up.addEventListener("click", () => { callbacks.onMove(MOVE_UP_STEP) })
  const down = iconButton({text: "↓", label: `Move ${favorite.name} down`, className: "favorite-stop-move"})
  down.addEventListener("click", () => { callbacks.onMove(MOVE_DOWN_STEP) })

  const remove = iconButton({text: "×", label: `${REMOVE_LABEL_PREFIX} ${favorite.name}`, className: "close-button shrink-0"})
  remove.addEventListener("click", () => { removeFavorite(favorite.stopId) })

  header.append(handle, title, up, down, remove)

  const actions = document.createElement("div")
  actions.className = ACTIONS_CLASS_NAME

  for (const tripButton of tripEndButtons({stopId: favorite.stopId, name: favorite.name, className: ACTION_CLASS_NAME})) {
    actions.append(tripButton)
  }

  const arrivalsElement = document.createElement("div")
  const shown = {status: "waiting"}
  writeArrivals({element: arrivalsElement, shown, withKey: false, yourBus: NO_YOUR_BUS, canFollow: false})
  element.append(header, arrivalsElement, actions)

  return {element, arrivalsElement, shown, up, down}
}

function isPosition(reply) {
  const isObject = typeof reply === "object" && reply !== null
  const hasLatitude = isObject && Number.isFinite(reply.lat)
  return hasLatitude && Number.isFinite(reply.lon)
}

// The vertical middle of `element` on screen.
function middleOf(element) {
  const rect = element.getBoundingClientRect()
  return rect.top + rect.height / HALVING_DIVISOR
}

// The hook of the panel. The server renders the panel empty and leaves its
// content to the hook, which lists the favorites, or says there is none,
// above a polite live region that announces a move.
export const FavoriteStop = {
  mounted() {
    // The entry of each favorite the panel shows, by stop identifier, in
    // the panel's order.
    this.entries = new Map()
    this.drag = null
    this.map = null
    this.positionRequestCount = 0
    this.events = pageEvents(this)
    this.push = (name, payload) => { this.events.push({name, payload}) }

    this.list = document.createElement("div")
    this.list.className = "flex flex-col gap-2"
    this.list.addEventListener("pointermove", (event) => { this.dragMove(event) })
    this.list.addEventListener("pointerup", (event) => { this.dragEnd(event) })
    this.list.addEventListener("pointercancel", () => { this.dragCancel() })
    this.list.addEventListener("lostpointercapture", () => { this.dragCancel() })
    this.announcement = document.createElement("p")
    this.announcement.className = "sr-only"
    this.announcement.setAttribute("aria-live", "polite")
    this.el.replaceChildren(this.list, this.announcement)

    this.onChange = (event) => { this.show(event.detail.favorites) }
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)
    this.onBasemapReady = (event) => { this.map = event.detail.map }
    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)

    this.events.handle("stop-arrivals:arrivals", (shown) => {
      const entry = this.entries.get(shown.stop_id)

      if (entry !== undefined) {
        // The whole answer is kept, so an arrival that passes before the
        // next event leaves its place to the one after it.
        entry.shown = shown
        const nowMs = Date.now()
        writeEntryArrivals({entry, nowMs})
        this.writeBadge(nowMs)
      }
    })

    this.stopTicker = startArrivalTicker((nowMs) => { this.tick(nowMs) })

    // The page that is live again knows nothing of the stops this hook has
    // open, and is told them again.
    this.events.whenLive(() => { this.sendOpenStops() })
    this.show(storedFavorites())
  },

  sendOpenStops() {
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
        entry = entryOf({favorite, callbacks: this.callbacksOf(favorite.stopId)})
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
    this.drag = null

    const elements = document.createDocumentFragment()

    for (const [index, entry] of Array.from(entries.values()).entries()) {
      const buttons = moveButtonsOf({index, count: entries.size})
      entry.up.disabled = buttons.isUpDisabled
      entry.down.disabled = buttons.isDownDisabled
      entry.element.classList.remove(DRAGGING_CLASS_NAME)
      elements.append(entry.element)
    }

    if (entries.size === 0) {
      const empty = document.createElement("p")
      appendMessage({element: empty, message: EMPTY_MESSAGE})
      elements.append(empty)
    }

    this.list.replaceChildren(elements)
    this.writeBadge(Date.now())
  },

  // Writes every favorite's arrivals and the badge again as of `nowMs`.
  tick(nowMs) {
    for (const entry of this.entries.values()) {
      writeEntryArrivals({entry, nowMs})
    }

    this.writeBadge(nowMs)
  },

  callbacksOf(stopId) {
    return {
      onChoose: () => { this.choose(stopId) },
      onMove: (step) => { this.moveBy({stopId, step}) },
      onDragStart: ({event, element}) => { this.dragStart({event, element, stopId}) }
    }
  },

  indexOf(stopId) {
    const stopIds = Array.from(this.entries.keys())
    return stopIds.indexOf(stopId)
  },

  // Moves the favorite one place up or down from a move button. The panel
  // is written anew, so focus goes back to the moved entry's button, or to
  // its other move button once the entry reaches an end.
  moveBy({stopId, step}) {
    const index = this.indexOf(stopId) + step
    this.moveTo({stopId, index})

    const entry = this.entries.get(stopId)
    let pressed = entry.down
    let other = entry.up

    if (step === MOVE_UP_STEP) {
      pressed = entry.up
      other = entry.down
    }

    if (pressed.disabled) {
      other.focus()
    } else {
      pressed.focus()
    }
  },

  // Stores the favorite at `index` and announces where it now stands.
  moveTo({stopId, index}) {
    moveFavorite({stopId, index})
    const movedIndex = this.indexOf(stopId)
    this.announce(moveText({index: movedIndex, count: this.entries.size}))
  },

  // A live region announces a change of its text, so the text is cleared
  // and written on the next frame, and a second move to the same place is
  // announced as well.
  announce(text) {
    this.announcement.textContent = ""
    window.requestAnimationFrame(() => { this.announcement.textContent = text })
  },

  // A drag starts from a handle with the primary button, a finger, or a
  // pen. The list captures the pointer until the drag ends: the dragged
  // entry moves within the list, and moving an element out of its place
  // releases a capture it holds.
  dragStart({event, element, stopId}) {
    const isPrimary = event.isPrimary && event.button === 0

    if (!isPrimary) {
      return
    }

    event.preventDefault()
    this.list.setPointerCapture(event.pointerId)
    element.classList.add(DRAGGING_CLASS_NAME)
    this.drag = {stopId, element, pointerId: event.pointerId, fromIndex: this.indexOf(stopId)}
  },

  // The dragged entry takes its place among the others as the pointer
  // passes their middles, so the list shows where it drops.
  dragMove(event) {
    const isDragged = this.drag !== null && event.pointerId === this.drag.pointerId

    if (!isDragged) {
      return
    }

    const others = this.otherEntryElements()
    const middles = Array.from(others, middleOf)
    const index = dropIndex({pointerY: event.clientY, middles})

    if (index < others.length) {
      this.list.insertBefore(this.drag.element, others[index])
    } else {
      this.list.append(this.drag.element)
    }
  },

  // The entries other than the dragged one, in the list's order on screen,
  // which the drag changes as it goes.
  otherEntryElements() {
    const elements = []

    for (const element of this.list.children) {
      if (element !== this.drag.element) {
        elements.push(element)
      }
    }

    return elements
  },

  dragEnd(event) {
    const isDragged = this.drag !== null && event.pointerId === this.drag.pointerId

    if (!isDragged) {
      return
    }

    const {stopId, element, fromIndex} = this.drag
    const children = Array.from(this.list.children)
    const index = children.indexOf(element)
    this.drag = null
    element.classList.remove(DRAGGING_CLASS_NAME)

    if (index === fromIndex) {
      return
    }

    this.moveTo({stopId, index})
  },

  // A canceled drag, or one whose capture is lost before the pointer comes
  // up, stores nothing, and the list goes back to the stored order.
  dragCancel() {
    if (this.drag === null) {
      return
    }

    this.show(storedFavorites())
  },

  // Asks the page for the stop's position, and centers the map on it when
  // the answer to the latest request arrives.
  choose(stopId) {
    const requestCount = this.positionRequestCount + 1
    this.positionRequestCount = requestCount

    const onReply = (reply) => {
      const isLatest = requestCount === this.positionRequestCount

      if (isLatest) {
        this.centerOn(reply)
      }
    }

    this.events.push({name: POSITION_EVENT_NAME, payload: {stop_id: stopId}, onReply})
  },

  // On a phone the sheet collapses first, so the stop stands in the part of
  // the map it then leaves.
  centerOn(reply) {
    const isMovable = this.map !== null && isPosition(reply)

    if (!isMovable) {
      return
    }

    const isBottomSheet = sheetInsets().bottom > 0

    if (isBottomSheet) {
      this.el.dispatchEvent(new CustomEvent(COLLAPSE_EVENT_NAME, {bubbles: true}))
    }

    const camera = favoriteCamera({
      lngLat: [reply.lon, reply.lat],
      zoom: this.map.getZoom(),
      zoomMin: FAVORITE_ZOOM_MIN,
      insets: sheetInsets(),
      reducedMotion: window.matchMedia(REDUCED_MOTION_QUERY).matches
    })

    // The fit's event data marks the move as the page's own, so it ends
    // following the rider's location even while it zooms.
    this.map.easeTo(camera, FIT_EVENT_DATA)
  },

  // The badge of the Favorites tab: the next arrival at the first favorite
  // as of `nowMs`, with the live dot for a prediction, hidden while there is
  // none.
  writeBadge(nowMs) {
    const badge = document.getElementById(BADGE_ID)

    if (badge === null) {
      return
    }

    const [first] = this.entries.values()
    let text = ""
    let isLive = false

    if (first !== undefined) {
      const next = shownAt({shown: first.shown, nowMs, countMax: 1})
      text = nextArrivalText(next)
      isLive = isNextArrivalLive(next)
    }

    badge.replaceChildren(text)

    if (isLive) {
      badge.append(liveDot())
    }

    badge.hidden = text === ""
  },

  destroyed() {
    this.stopTicker()
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    this.events.release()
  }
}
