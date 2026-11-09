// The Trip tab: a From field, a To field, and a swap button, and under them
// the journeys between the two, leaving now, routed in the browser from the
// routing snapshots. The rider's position, where the trip starts from it,
// stays in this module: no event to the server carries it, and the router
// fetches only the files the manifest names. After a query the page is
// asked to name the stops and the routes of the journeys shown, and while a
// journey is selected the map's filter is its routes, which the page holds
// for as long as the trip is open and never stores.
//
// Every text here is built as text nodes: names come from outside the
// application and are never parsed as HTML.

import {unreachable} from "./assert"
import {chipElements} from "./route_chips"
import {FetchKind, FailureReason, FromKind, JourneysKind, ServiceDateKind, routeJourneys, serviceDateAt} from "./routing_journeys"
import {END_EVENT_NAME, isPicking, startPicking, stopPicking} from "./trip_ends"
import {createTripMap} from "./trip_map"
import {
  EndKind,
  LOCATION_END,
  NO_END,
  QueryKind,
  StateKind,
  TripEnd,
  failureState,
  isRetryable,
  journeyFeatures,
  journeyRows,
  journeysAnnouncement,
  nameRequest,
  queryOf,
  stateText,
  stopEnd,
  swappedEnds,
  tripRouteIds,
  windowText
} from "./trip_plan"
import {CHANGE_EVENT_NAME as FAVORITE_CHANGE_EVENT_NAME, storedFavorites} from "./favorite_stop"
import {COLLAPSE_EVENT_NAME, OPEN_EVENT_NAME} from "./panel_sheet"
import {LatestKind, OutcomeKind} from "./position_watch"
import {isNotSaved} from "./offline_bundle"
import {pageEvents} from "./page_events"
import {TRIP_HOLDER, holdPosition, latestFix, permissionGranted, releasePosition} from "./rider_position"

const NAMES_EVENT_NAME = "trip:names"
const FILTER_EVENT_NAME = "trip:filter"
const CLEAR_EVENT_NAME = "trip:clear"
const FILTER_ENDED_EVENT_NAME = "trip:filter-ended"
const MANIFEST_TIMEOUT_MS = 20 * 1000
const FIELD_LABELS = Object.freeze({[TripEnd.from]: "From", [TripEnd.to]: "To"})
const EMPTY_FIELD_TEXT = "Choose a stop"
const LOCATION_TEXT = "My location"
const PICK_TEXT = "Pick a stop on the map"
const CHIP_COUNT_MAX = 1
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
const NO_NAMES = Object.freeze({stops: {}, routes: {}})

// The kinds of what the query's start resolves to.
const StartKind = Object.freeze({start: "start", refused: "refused"})

function locatedStart(fix) {
  return {kind: StartKind.start, position: {lat: fix.latitude, lon: fix.longitude}}
}

// The start an outcome of the page's position watch gives.
function startOfOutcome(outcome) {
  switch (outcome.kind) {
    case OutcomeKind.fix:
      return locatedStart(outcome.fix)
    case OutcomeKind.denied:
      return {kind: StartKind.refused, state: StateKind.locationDenied}
    case OutcomeKind.unavailable:
    case OutcomeKind.timedOut:
      return {kind: StartKind.refused, state: StateKind.locationUnavailable}
    default:
      return unreachable(outcome.kind, "trip planner: a position outcome of unknown kind")
  }
}

// Resolves on the rider's position, or on why the browser gives none: the
// latest fix of the page's position watch while it is fresh, or else the
// watch's next outcome, which the trip panel holds the watch for.
function locate(resolve) {
  const latest = latestFix()

  if (latest.kind === LatestKind.fresh) {
    resolve(locatedStart(latest.fix))
    return
  }

  function onOutcome(outcome) {
    releasePosition({holder: TRIP_HOLDER})
    resolve(startOfOutcome(outcome))
  }

  holdPosition({holder: TRIP_HOLDER, onOutcome})
}

// Whether the browser gives the rider's position, and the position.
function currentPosition() {
  return new Promise(locate)
}

function isEarliestRow(row) {
  return row.isEarliest
}

// `elements` as one fragment, to put in place of an element's children.
function fragmentOf(elements) {
  const fragment = document.createDocumentFragment()

  for (const created of elements) {
    fragment.append(created)
  }

  return fragment
}

// One file the manifest names, fetched as the browser caches it: each
// file's address holds one content, so a cached copy is that file.
async function fetchFile({path, signal}) {
  const response = await fetch(path, {signal, cache: "default", credentials: "same-origin"})

  if (isNotSaved(response)) {
    return {kind: FetchKind.failed, reason: FailureReason.notSaved}
  }

  if (!response.ok) {
    return {kind: FetchKind.failed, reason: FailureReason.fetchFailed}
  }

  const buffer = await response.arrayBuffer()
  return {kind: FetchKind.fetched, buffer}
}

// The manifest, revalidated on every query, or why there is none. Its
// shape is the router's to judge; a body with no snapshots is a failure.
async function fetchManifest(url) {
  const signal = AbortSignal.timeout(MANIFEST_TIMEOUT_MS)

  try {
    const response = await fetch(url, {signal, cache: "no-cache", credentials: "same-origin", headers: {accept: "application/json"}})

    if (isNotSaved(response)) {
      return {kind: JourneysKind.failed, reason: FailureReason.notSaved, path: url}
    }

    if (!response.ok) {
      return {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: url}
    }

    const manifest = await response.json()
    const hasSnapshots = typeof manifest === "object" && manifest !== null
    const isManifest = hasSnapshots && Array.isArray(manifest.snapshots)

    if (!isManifest) {
      return {kind: JourneysKind.failed, reason: FailureReason.refused, path: url}
    }

    return {kind: FetchKind.fetched, manifest}
  } catch (error) {
    console.warn("Routing manifest not fetched", error)
    return {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: url}
  }
}

function serviceDayStartsOf(manifest) {
  const starts = {}

  for (const entry of manifest.snapshots) {
    starts[entry.serviceDate] = entry.serviceDayStartMs
  }

  return starts
}

function element({tag, className, text}) {
  const created = document.createElement(tag)
  created.className = className

  if (text !== undefined) {
    created.textContent = text
  }

  return created
}

function button({className, text}) {
  const created = element({tag: "button", className, text})
  created.type = "button"
  return created
}

// The text an end shows in its field.
function endText(end) {
  switch (end.kind) {
    case EndKind.none:
      return EMPTY_FIELD_TEXT
    case EndKind.location:
      return LOCATION_TEXT
    case EndKind.stop:
      return end.name
    default:
      return unreachable(end.kind, "trip planner: an end of unknown kind")
  }
}

// The line that sums up a row: a chip per ride and a text per walk, with
// the changes after them.
function summaryElement(row) {
  const summary = element({tag: "span", className: "trip-journey-summary"})

  for (const [index, part] of row.summary.entries()) {
    if (index > 0) {
      summary.append(element({tag: "span", className: "trip-journey-separator", text: "›"}))
    }

    if (part.kind === "ride") {
      for (const chip of chipElements({chips: [part.chip], countMax: CHIP_COUNT_MAX, emptyText: ""})) {
        summary.append(chip)
      }
    } else {
      summary.append(element({tag: "span", className: "trip-journey-walk", text: part.text}))
    }
  }

  summary.append(element({tag: "span", className: "trip-journey-changes", text: row.changesText}))
  return summary
}

export const TripPlanner = {
  mounted() {
    this.ends = {[TripEnd.from]: NO_END, [TripEnd.to]: NO_END}
    // The query whose answer the tab shows; an answer to an earlier one is
    // dropped.
    this.queryCount = 0
    this.shown = null
    this.names = NO_NAMES
    this.selectedIndex = 0
    this.isFilterSent = false
    this.openMenu = null
    this.manifestUrl = this.el.dataset.manifestUrl
    this.nameCountMax = Number(this.el.dataset.nameCountMax)
    this.routeCountMax = Number(this.el.dataset.routeCountMax)
    this.tripMap = createTripMap()
    this.events = pageEvents(this)
    this.build()

    this.onEnd = (event) => {
      const {end, stopId, name} = event.detail
      this.setEnd({end, value: stopEnd({stopId, name})})
      this.el.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true}))
    }

    this.onFavoriteChange = () => { this.writeMenus() }
    window.addEventListener(END_EVENT_NAME, this.onEnd)
    window.addEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    this.events.handle(FILTER_ENDED_EVENT_NAME, () => { this.isFilterSent = false })
    // A page that is live again holds no trip's filter, and is sent it again.
    this.events.whenLive(() => { this.resendFilter() })
    this.startFromLocation()
  },

  resendFilter() {
    if (this.isFilterSent) {
      this.sendFilter()
    }
  },

  // From starts as the rider's location where the browser gives it with no
  // prompt, so opening the page never raises one.
  async startFromLocation() {
    const granted = await permissionGranted()
    const isUnchosen = this.ends[TripEnd.from].kind === EndKind.none
    const isLocationStart = granted && isUnchosen

    if (isLocationStart) {
      this.ends[TripEnd.from] = LOCATION_END
      this.writeFields()
    }
  },

  build() {
    const ends = element({tag: "div", className: "trip-ends"})
    const fields = element({tag: "div", className: "trip-fields"})
    this.fields = {}
    this.menus = {}

    for (const end of [TripEnd.from, TripEnd.to]) {
      const field = button({className: "trip-field"})
      field.id = `trip-${end}`
      field.setAttribute("aria-haspopup", "true")
      field.setAttribute("aria-expanded", "false")
      field.setAttribute("aria-controls", `trip-${end}-menu`)
      field.append(element({tag: "span", className: `trip-dot trip-dot-${end}`}))
      field.append(element({tag: "span", className: "trip-field-label", text: FIELD_LABELS[end]}))
      const value = element({tag: "span", className: "trip-field-value"})
      field.append(value)
      field.addEventListener("click", () => { this.toggleMenu(end) })

      const menu = element({tag: "div", className: "trip-menu"})
      menu.id = `trip-${end}-menu`
      menu.hidden = true

      this.fields[end] = {field, value}
      this.menus[end] = menu
      fields.append(field, menu)
    }

    const swap = button({className: "trip-swap", text: "⇅"})
    swap.setAttribute("aria-label", "Swap From and To")
    swap.addEventListener("click", () => { this.swap() })
    ends.append(fields, swap)

    this.status = element({tag: "div", className: "trip-status"})
    this.status.setAttribute("role", "status")
    this.windowLine = element({tag: "p", className: "trip-window"})
    this.journeysElement = element({tag: "div", className: "trip-journeys"})

    this.clearButton = button({className: "panel-detail-action trip-clear", text: "Clear trip"})
    this.clearButton.addEventListener("click", () => { this.clear() })

    this.el.addEventListener("keydown", (event) => {
      const isMenuEscape = event.key === "Escape" && this.openMenu !== null

      if (isMenuEscape) {
        event.stopPropagation()
        this.closeMenus()
      }
    })

    this.el.replaceChildren(ends, this.status, this.windowLine, this.journeysElement, this.clearButton)
    this.writeFields()
    this.writeMenus()
  },

  writeFields() {
    for (const end of [TripEnd.from, TripEnd.to]) {
      const shown = this.ends[end]
      const {value} = this.fields[end]
      value.textContent = endText(shown)
      value.classList.toggle("trip-field-empty", shown.kind === EndKind.none)
    }

    const isOpen = this.ends[TripEnd.from].kind !== EndKind.none || this.ends[TripEnd.to].kind !== EndKind.none
    this.clearButton.hidden = isOpen === false
  },

  // The choices of each field: the rider's location for From, each
  // favorite, and a stop picked on the map.
  writeMenus() {
    for (const end of [TripEnd.from, TripEnd.to]) {
      const menu = this.menus[end]
      const items = []

      if (end === TripEnd.from) {
        const location = button({className: "trip-menu-item", text: LOCATION_TEXT})
        location.addEventListener("click", () => { this.setEnd({end, value: LOCATION_END}) })
        items.push(location)
      }

      for (const favorite of storedFavorites()) {
        const item = button({className: "trip-menu-item", text: `★ ${favorite.name}`})
        item.addEventListener("click", () => { this.setEnd({end, value: stopEnd(favorite)}) })
        items.push(item)
      }

      const pick = button({className: "trip-menu-item", text: PICK_TEXT})
      pick.addEventListener("click", () => { this.pick(end) })
      items.push(pick)
      menu.replaceChildren(fragmentOf(items))
    }
  },

  toggleMenu(end) {
    const isOpen = this.openMenu === end
    this.closeMenus()

    if (!isOpen) {
      this.openMenu = end
      this.menus[end].hidden = false
      this.fields[end].field.setAttribute("aria-expanded", "true")
      this.menus[end].querySelector("button").focus()
    }
  },

  closeMenus() {
    for (const end of [TripEnd.from, TripEnd.to]) {
      this.menus[end].hidden = true
      this.fields[end].field.setAttribute("aria-expanded", "false")
    }

    this.openMenu = null
  },

  // Waits for the next stop the rider taps on the map, with the sheet out
  // of the way on a phone.
  pick(end) {
    this.closeMenus()
    startPicking(end)

    const note = element({tag: "p", className: "trip-note", text: `Tap a stop on the map for ${FIELD_LABELS[end]}. Stops show once the map is zoomed in.`})
    const cancel = button({className: "panel-detail-action", text: "Cancel"})
    cancel.addEventListener("click", () => {
      stopPicking()
      this.plan()
    })

    this.status.replaceChildren(note, cancel)
    this.el.dispatchEvent(new CustomEvent(COLLAPSE_EVENT_NAME, {bubbles: true}))
  },

  setEnd({end, value}) {
    if (isPicking()) {
      stopPicking()
    }

    this.closeMenus()
    this.ends[end] = value
    this.writeFields()
    this.plan()
  },

  swap() {
    const swapped = swappedEnds({from: this.ends[TripEnd.from], to: this.ends[TripEnd.to]})
    this.ends = {[TripEnd.from]: swapped.from, [TripEnd.to]: swapped.to}
    this.writeFields()
    this.plan()
  },

  // Ends the trip: no end, no journey, nothing drawn, and the rider's own
  // filter on the map. From starts again as the rider's location where the
  // browser gives it with no prompt.
  clear() {
    stopPicking()
    this.ends = {[TripEnd.from]: NO_END, [TripEnd.to]: NO_END}
    this.writeFields()
    this.closeResult()
    this.status.replaceChildren()
    this.startFromLocation()
  },

  // Drops the journeys shown, the drawing, and the trip's filter.
  closeResult() {
    this.queryCount += 1
    this.shown = null
    this.windowLine.replaceChildren()
    this.journeysElement.replaceChildren()
    this.tripMap.clear()

    if (this.isFilterSent) {
      this.events.push({name: CLEAR_EVENT_NAME, payload: {}})
      this.isFilterSent = false
    }
  },

  showState({kind, retry}) {
    const note = element({tag: "p", className: "trip-note", text: stateText(kind)})
    this.status.replaceChildren(note)

    if (retry) {
      const again = button({className: "panel-detail-action", text: "Try again"})
      again.addEventListener("click", () => { this.plan() })
      this.status.append(again)
    }
  },

  // Plans the trip the two ends make, leaving now, in place of the one
  // shown. Each wait checks that no later query has started since.
  async plan() {
    this.closeResult()
    this.status.replaceChildren()
    const query = queryOf({from: this.ends[TripEnd.from], to: this.ends[TripEnd.to]})

    if (query.kind === QueryKind.incomplete) {
      return
    } else if (query.kind === QueryKind.sameStop) {
      this.showState({kind: StateKind.sameStop, retry: false})
      return
    }

    const queryNumber = this.queryCount
    this.showState({kind: StateKind.loading, retry: false})
    const start = await this.startOf(query.from)

    if (queryNumber !== this.queryCount) {
      return
    } else if (start.kind === StartKind.refused) {
      this.showState({kind: start.state, retry: true})
      return
    }

    const manifestOutcome = await fetchManifest(this.manifestUrl)

    if (queryNumber !== this.queryCount) {
      return
    } else if (manifestOutcome.kind === JourneysKind.failed) {
      this.showState({kind: failureState(manifestOutcome), retry: true})
      return
    }

    const {manifest} = manifestOutcome
    const dated = serviceDateAt({manifest, departureMs: Date.now()})

    if (dated.kind === ServiceDateKind.none) {
      this.showState({kind: StateKind.noServiceDate, retry: true})
      return
    }

    const answer = await routeJourneys({manifest, serviceDate: dated.serviceDate, departureS: dated.departureS, from: start.from, toStopId: query.toStopId, fetchFile})

    if (queryNumber !== this.queryCount) {
      return
    }

    this.answer({answer, dated, manifest, origin: start.origin})
  },

  // The router's start for `from`: a stop, or the rider's position, which
  // stays in this module.
  async startOf(from) {
    if (from.kind === EndKind.stop) {
      return {kind: StartKind.start, from: {kind: FromKind.stop, stopId: from.stopId}, origin: null}
    }

    const located = await currentPosition()

    if (located.kind === StartKind.refused) {
      return located
    }

    const {lat, lon} = located.position
    return {kind: StartKind.start, from: {kind: FromKind.position, lat, lon}, origin: located.position}
  },

  answer({answer, dated, manifest, origin}) {
    switch (answer.kind) {
      case JourneysKind.found:
        break
      case JourneysKind.failed:
        console.warn("Journeys not routed", answer.reason, answer.path)
        this.showState({kind: failureState(answer), retry: isRetryable(answer)})
        return
      case JourneysKind.none:
      case JourneysKind.unknownStop:
      case JourneysKind.noStartStop:
        this.showState({kind: answer.kind, retry: false})
        return
      default:
        unreachable(answer.kind, "trip planner: an answer of unknown kind")
    }

    this.status.replaceChildren()

    this.shown = {
      journeys: answer.journeys,
      departure: {serviceDate: dated.serviceDate, departureS: dated.departureS},
      serviceDayStartsMs: serviceDayStartsOf(manifest),
      origin,
      queryNumber: this.queryCount
    }

    this.names = NO_NAMES
    const rows = this.rows()
    this.selectedIndex = rows.findIndex(isEarliestRow)
    this.writeJourneys(rows)
    this.selectJourney({index: this.selectedIndex, rows})
    this.announceJourneys(rows)
    this.requestNames()
  },

  // The status line says, out of sight, what the list that appeared holds,
  // so a screen reader announces it.
  announceJourneys(rows) {
    const line = element({tag: "p", className: HIDDEN_TEXT_CLASS_NAME, text: journeysAnnouncement(rows)})
    this.status.replaceChildren(line)
  },

  rows() {
    const {journeys, departure, serviceDayStartsMs} = this.shown
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    return journeyRows({journeys, departure, serviceDayStartsMs, names: this.names, timeZone})
  },

  // Asks the page to name the stops and routes of the journeys shown; the
  // answer names them in the list and colors the drawn rides.
  requestNames() {
    const {queryNumber} = this.shown
    const request = nameRequest({journeys: this.shown.journeys, countMax: this.nameCountMax})

    const payload = {stop_ids: request.stopIds, route_ids: request.routeIds}

    const onReply = (reply) => {
      const isCurrent = this.shown !== null && this.shown.queryNumber === queryNumber

      if (!isCurrent) {
        return
      } else if (reply.refused === true) {
        console.warn("Trip names refused")
        return
      }

      this.names = {stops: reply.stops, routes: reply.routes}
      const rows = this.rows()
      this.writeJourneys(rows)
      this.draw(rows[this.selectedIndex])
    }

    this.events.push({name: NAMES_EVENT_NAME, payload, onReply})
  },

  writeJourneys(rows) {
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    this.windowLine.textContent = windowText({journeys: this.shown.journeys, serviceDayStartsMs: this.shown.serviceDayStartsMs, timeZone})
    const items = []

    for (const [index, row] of rows.entries()) {
      const item = button({className: "trip-journey"})
      const isSelected = index === this.selectedIndex
      item.setAttribute("aria-pressed", String(isSelected))

      const heading = element({tag: "span", className: "trip-journey-heading"})
      heading.append(element({tag: "strong", className: "trip-journey-times", text: row.timesText}))
      const badge = element({tag: "span", className: "trip-journey-badge", text: row.badgeText})
      badge.classList.toggle("trip-journey-earliest", row.isEarliest)
      heading.append(badge)
      item.append(heading, summaryElement(row))
      item.addEventListener("click", () => { this.selectJourney({index, rows: this.rows()}) })
      items.push(item)

      if (isSelected) {
        const stepsElement = element({tag: "ol", className: "trip-journey-steps"})

        for (const step of row.steps) {
          stepsElement.append(element({tag: "li", className: "", text: step}))
        }

        items.push(stepsElement)
      }
    }

    this.journeysElement.replaceChildren(fragmentOf(items))
  },

  // Selects the journey at `index`: its steps in the list, its drawing on
  // the map, and its routes as the map's filter.
  selectJourney({index, rows}) {
    const isChanged = index !== this.selectedIndex
    this.selectedIndex = index

    if (isChanged) {
      this.writeJourneys(rows)
    }

    const drawn = this.draw(rows[index])
    this.tripMap.fit(drawn.bounds)
    this.sendFilter()
  },

  draw(row) {
    const drawn = journeyFeatures({journey: row.journey, names: this.names, origin: this.shown.origin})
    this.tripMap.show(drawn.collection)
    return drawn
  },

  // The selected journey's routes as the map's filter, sent again on every
  // selection, which brings it back after an edit of the filter ended it.
  // A journey with no ride leaves the rider's own filter.
  sendFilter() {
    const {journey} = this.rows()[this.selectedIndex]
    const routeIds = tripRouteIds({journey, countMax: this.routeCountMax})

    if (routeIds.length === 0) {
      if (this.isFilterSent) {
        this.events.push({name: CLEAR_EVENT_NAME, payload: {}})
      }

      this.isFilterSent = false
      return
    }

    this.events.push({name: FILTER_EVENT_NAME, payload: {route_ids: routeIds}})
    this.isFilterSent = true
  },

  destroyed() {
    window.removeEventListener(END_EVENT_NAME, this.onEnd)
    window.removeEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    this.tripMap.destroy()
    stopPicking()
    releasePosition({holder: TRIP_HOLDER})
    this.events.release()
  }
}
