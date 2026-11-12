// The Trip tab: a From chip and a swap button over one "Where to?" search,
// a switch of when the trip is for, leaving now, leaving at a time, or
// arriving by one, and under them the journeys between the two ends, routed
// in the browser from the routing snapshots. The search box is a WAI-ARIA
// combobox whose listbox groups the rider's recent trips and the places,
// addresses, intersections, and stops a text names; the From chip opens the
// same search for the start. The rider's position, where the trip starts
// from it, stays in this module, and so does every text typed: no event to
// the server carries either, the search reads files fetched whole or by a
// shard a text names, and the router fetches only the files the manifest
// names. After a query the page is asked to name the stops and the routes
// of the journeys shown, and while a journey is selected the map's filter
// is its routes, which the page holds for as long as the trip is open and
// never stores.
//
// Every text here is built as text nodes: names come from outside the
// application and are never parsed as HTML.

import {assertCondition, unreachable} from "./core/assert"
import {FromKind, JourneysKind} from "./core/routing_journeys"
import {AnswerKind, answerOutcome, fetchManifest, routeTo, serviceDayStartsOf, walkSpeedsOf} from "./trip_route"
import {END_EVENT_NAME, isPicking, startPicking, stopPicking} from "./trip_ends"
import {CenterKind, createTripMap} from "./trip_map"
import {
  DayChoice,
  EndKind,
  LOCATION_END,
  NO_END,
  PlannedKind,
  QueryKind,
  StateKind,
  TimeMode,
  TripEnd,
  defaultClock,
  failureState,
  isMarkedRow,
  journeyFeatures,
  journeyRows,
  journeysAnnouncement,
  nameRequest,
  pickingMessage,
  plannedTime,
  pointEnd,
  queryOf,
  stateMessage,
  stopEnd,
  swappedEnds,
  tripRouteIds,
  windowText
} from "./core/trip_plan"
import {ChoiceKind, OSM_CREDIT, OptionMove, PositionKind, RECENT_TRIP_COUNT_MAX, SEARCH_CENTER_DEFAULT, movedOptionIndex, searchPoints, suggestionList, suggestionsAnnouncement} from "./where_to"
import {SORT_LABELS, SortKind, firstRideLive, journeyCard, liveStopIds, sortedCards} from "./journey_cards"
import {button, element} from "./dom_element"
import {cardElement} from "./journey_card_view"
import {tripStrip} from "./trip_strip"
import {createStripView} from "./trip_strip_view"
import {clearChosenJourney, setChosenJourney} from "./chosen_journey"
import {TimelineRowKind, timelineRows} from "./journey_timeline"
import {TRIP_HOLDER as TRIP_STOP_HOLDER, holdStop, releaseStop} from "./stop_holds"
import {liveDot} from "./stop_arrivals"
import {startArrivalTicker} from "./arrival_ticker"
import {chipTextColor} from "./route_chip_color"
import {createSearchFiles} from "./where_to_files"
import {CHANGE_EVENT_NAME as FAVORITE_CHANGE_EVENT_NAME, storedFavorites} from "./favorite_stop"
import {COLLAPSE_EVENT_NAME, OPEN_EVENT_NAME} from "./panel_sheet"
import {LatestKind, OutcomeKind} from "./position_watch"
import {appendMessage} from "./message"
import {pageEvents} from "./page_events"
import {HandoffKind, NO_HANDOFF, takeHandoffState} from "./hook_handoff"
import {SEARCH_HOLDER, TRIP_HOLDER, holdPosition, latestFix, permissionGranted, releasePosition} from "./rider_position"
import {storedSettings} from "./stored_settings"

const STRIP_ID = "trip-strip"
const TRIP_TAB_ID = "panel-tab-trip"
const NAMES_EVENT_NAME = "trip:names"
const FILTER_EVENT_NAME = "trip:filter"
const CLEAR_EVENT_NAME = "trip:clear"
const FILTER_ENDED_EVENT_NAME = "trip:filter-ended"
const ARRIVALS_EVENT_NAME = "stop-arrivals:arrivals"
// The files are the page's own, so no origin goes in front of a path.
const PAGE_ORIGIN = ""
const FIELD_LABELS = Object.freeze({[TripEnd.from]: "From", [TripEnd.to]: "To"})
const OTHER_END = Object.freeze({[TripEnd.from]: TripEnd.to, [TripEnd.to]: TripEnd.from})
const SEARCH_LABELS = Object.freeze({[TripEnd.from]: "Where from?", [TripEnd.to]: "Where to?"})
const EMPTY_FROM_TEXT = "Choose a start"
const LOCATION_TEXT = "My location"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
const NO_NAMES = Object.freeze({stops: {}, routes: {}})
const LISTBOX_ID = "trip-suggestions"
const INPUT_ID = "trip-search-input"
const OPTION_ID_PREFIX = "trip-suggestion-"
const NONE_INDEX = -1
const KEY_MOVES = Object.freeze({ArrowDown: OptionMove.down, ArrowUp: OptionMove.up, Home: OptionMove.home, End: OptionMove.end})
const MODE_LABELS = Object.freeze({[TimeMode.now]: "Now", [TimeMode.departAt]: "Depart at", [TimeMode.arriveBy]: "Arrive by"})
const DAY_LABELS = Object.freeze({[DayChoice.today]: "Today", [DayChoice.tomorrow]: "Tomorrow"})
const LEAVING_NOW = Object.freeze({mode: TimeMode.now, day: DayChoice.today, clockText: ""})

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

// `elements` as one fragment, to put in place of an element's children.
function fragmentOf(elements) {
  const fragment = document.createDocumentFragment()

  for (const created of elements) {
    fragment.append(created)
  }

  return fragment
}

function serviceDateOfJourney(journey) {
  return journey.serviceDate
}

// The text an end shows in the chip or the search box.
function endText(end) {
  switch (end.kind) {
    case EndKind.none:
      return ""
    case EndKind.location:
      return LOCATION_TEXT
    case EndKind.stop:
    case EndKind.point:
      return end.name
    default:
      return unreachable(end.kind, "trip planner: an end of unknown kind")
  }
}

// A stored end as the tab's own: a stored shape is the tab's, so each is
// built again by its constructor, which asserts it.
function endOfStored(stored) {
  switch (stored.kind) {
    case EndKind.location:
      return LOCATION_END
    case EndKind.stop:
      return stopEnd(stored)
    case EndKind.point:
      return pointEnd(stored)
    default:
      return unreachable(stored.kind, "trip planner: a stored end of unknown kind")
  }
}

// The index of the journey whose card has the focus, or none.
function focusedKey(container) {
  const focused = document.activeElement
  const isInside = focused !== null && container.contains(focused)
  const isKeyed = isInside && focused.dataset.focusKey !== undefined

  if (isKeyed) {
    return focused.dataset.focusKey
  }

  return ""
}

// Gives the focus back to the control of `key`, a card or an expand
// button, written anew.
function refocus({container, key}) {
  if (key === "") {
    return
  }

  const control = container.querySelector(`[data-focus-key="${key}"]`)

  if (control !== null) {
    control.focus()
  }
}

// The rail of a timeline row: its dot, or its ride's colored line or its
// walk's dotted one, drawn for the eye alone.
function railElement(row) {
  const rail = element({tag: "span", className: "trip-timeline-rail"})
  rail.setAttribute("aria-hidden", "true")
  const isStop = row.kind === TimelineRowKind.board || row.kind === TimelineRowKind.alight
  const hasColor = isStop || row.kind === TimelineRowKind.ride

  if (hasColor) {
    rail.style.setProperty("--rail-color", rowColor(row))
  }

  return rail
}

function rowColor(row) {
  if (row.kind === TimelineRowKind.ride) {
    return row.chip.color
  }

  return row.color
}

// What a sighted rider reads of a row beside its rail; the row's sentence
// is what a screen reader reads.
function rowBodyElement(row) {
  const body = element({tag: "span", className: "trip-timeline-body"})
  body.setAttribute("aria-hidden", "true")

  switch (row.kind) {
    case TimelineRowKind.origin:
    case TimelineRowKind.arrive:
      body.append(element({tag: "strong", className: "", text: row.name}))
      break
    case TimelineRowKind.board:
    case TimelineRowKind.alight:
      body.append(element({tag: "strong", className: "", text: row.name}))

      if (row.detail !== "") {
        body.append(element({tag: "span", className: "trip-timeline-detail", text: row.detail}))
      }

      break
    case TimelineRowKind.walk:
      body.append(element({tag: "span", className: "trip-timeline-detail", text: row.text}))
      break
    case TimelineRowKind.ride:
      body.append(rideLineElement(row))
      break
    default:
      unreachable(row.kind, "trip planner: a timeline row of unknown kind")
  }

  return body
}

// A ride's chip, headsign, and live lateness.
function rideLineElement(row) {
  const line = element({tag: "span", className: "trip-timeline-ride-line"})
  const chip = element({tag: "span", className: "trip-timeline-chip", text: row.chip.name})
  chip.style.backgroundColor = row.chip.color
  chip.style.color = chipTextColor(row.chip.color)
  line.append(chip)

  if (row.headsign !== "") {
    line.append(element({tag: "span", className: "", text: `to ${row.headsign}`}))
  }

  if (row.lateText !== "") {
    const late = element({tag: "span", className: "trip-timeline-late"})
    late.append(liveDot(), row.lateText)
    line.append(late)
  }

  return line
}

function keepFocusCallback(event) {
  event.preventDefault()
}

// One option of the list, named by its text and its detail.
function optionElement({option, index}) {
  const optionItem = element({tag: "div", className: `trip-suggestion trip-suggestion-${option.kind}`})
  optionItem.id = OPTION_ID_PREFIX + index
  optionItem.setAttribute("role", "option")
  optionItem.setAttribute("aria-selected", "false")
  optionItem.dataset.optionIndex = String(index)
  optionItem.append(element({tag: "span", className: "trip-suggestion-text", text: option.text}))

  if (option.detail !== "") {
    optionItem.append(element({tag: "span", className: "trip-suggestion-detail", text: option.detail}))
  }

  return optionItem
}

// A group of the list, named by its label, which a screen reader announces
// as the active option enters it. The name is the label's own text in an
// attribute, since Chrome computes a name from an element's rendered text,
// which the stylesheet draws in capitals.
function groupElement({group, firstIndex}) {
  const created = element({tag: "div", className: "trip-suggestion-group"})
  created.setAttribute("role", "group")
  created.setAttribute("aria-label", group.label)
  const label = element({tag: "div", className: "trip-suggestion-group-label", text: group.label})
  label.setAttribute("aria-hidden", "true")
  created.append(label)

  for (const [offset, option] of group.options.entries()) {
    created.append(optionElement({option, index: firstIndex + offset}))
  }

  return created
}

export const TripPlanner = {
  mounted() {
    this.ends = {[TripEnd.from]: NO_END, [TripEnd.to]: NO_END}
    this.when = LEAVING_NOW
    // The query whose answer the tab shows; an answer to an earlier one is
    // dropped.
    this.queryCount = 0
    this.shown = null
    this.names = NO_NAMES
    // The headsigns of the journeys' trips, and the rides whose passed
    // stops the timeline shows, by journey and leg.
    this.headsigns = new Map()
    this.snapshotStopNames = {}
    this.expandedRides = new Set()
    this.selectedIndex = 0
    this.isFilterSent = false
    // Whether an edit of the rider's filter ended the trip's filter, which
    // takes the strip away until a journey is selected again.
    this.isStripEnded = false
    // The strip's view, written into the element the page renders for it.
    this.stripView = this.buildStrip()
    // The end the search box searches for, the text typed since it took
    // focus, the options the list shows, and the search whose results the
    // list shows; a later search's results replace an earlier one's.
    this.searching = TripEnd.to
    this.searchText = ""
    this.options = []
    this.activeIndex = NONE_INDEX
    this.searchCount = 0
    this.searchFix = null
    this.manifestUrl = this.el.dataset.manifestUrl
    this.nameCountMax = Number(this.el.dataset.nameCountMax)
    this.routeCountMax = Number(this.el.dataset.routeCountMax)
    this.openCountMax = Number(this.el.dataset.openCountMax)
    // The sort the cards stand in, the stops held open for the live times
    // of the journeys' first rides, and the latest arrivals of each.
    this.sort = SortKind.soonest
    this.liveStops = new Set()
    this.shownByStop = {}
    this.push = (name, payload) => { this.events.push({name, payload}) }
    this.tripMap = createTripMap()
    this.searchFiles = createSearchFiles({origin: PAGE_ORIGIN})
    this.events = pageEvents(this)
    this.build()

    this.onEnd = (event) => {
      const {end, stopId, name} = event.detail
      this.setEnd({end, value: stopEnd({stopId, name})})
      this.el.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true}))
    }

    this.onFavoriteChange = () => { this.refreshList() }
    window.addEventListener(END_EVENT_NAME, this.onEnd)
    window.addEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    this.events.handle(FILTER_ENDED_EVENT_NAME, () => { this.endFilter() })
    this.events.handle(ARRIVALS_EVENT_NAME, (shown) => { this.liveArrivals(shown) })
    // A page that is live again holds no trip's filter and none of the
    // stops held for the live times, and is sent both again.
    this.events.whenLive(() => {
      this.resendFilter()
      this.resendLiveStops()
    })
    this.stopTicker = startArrivalTicker(() => { this.tickCards() })
    this.takeHandedEnds()
    this.startFromLocation()
  },

  // The ends of a trip the offline host's planner held, planned again so
  // the page joining LiveView keeps the rider's trip.
  takeHandedEnds() {
    const handed = takeHandoffState(this.el.id)

    if (handed.kind === HandoffKind.found) {
      this.ends = handed.state.ends
      this.when = handed.state.when
      this.writeEnds()
      this.writeWhen()
      this.plan()
    }
  },

  // The ends chosen, for the planner LiveView mounts on the same element.
  handoffState() {
    const hasFrom = this.ends[TripEnd.from].kind !== EndKind.none
    const hasEnd = hasFrom || this.ends[TripEnd.to].kind !== EndKind.none

    if (!hasEnd) {
      return NO_HANDOFF
    }

    return {kind: HandoffKind.found, state: {ends: {...this.ends}, when: this.when}}
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
      this.writeEnds()
    }
  },

  build() {
    const fromRow = element({tag: "div", className: "trip-from"})
    fromRow.append(element({tag: "span", className: "trip-field-label", text: FIELD_LABELS[TripEnd.from]}))
    this.fromChip = button({className: "trip-from-chip"})
    this.fromChip.id = "trip-from"
    this.fromChip.append(element({tag: "span", className: "trip-dot trip-dot-from"}))
    this.fromValue = element({tag: "span", className: "trip-field-value"})
    this.fromChip.append(this.fromValue)
    this.fromChip.addEventListener("click", () => { this.searchFor(TripEnd.from) })

    const swap = button({className: "trip-swap", text: "⇅"})
    swap.setAttribute("aria-label", "Swap From and To")
    swap.addEventListener("click", () => { this.swap() })
    fromRow.append(this.fromChip, swap)

    const searchBox = element({tag: "div", className: "trip-search-box"})
    this.searchDot = element({tag: "span", className: "trip-dot trip-dot-to"})
    this.searchLabel = element({tag: "label", className: HIDDEN_TEXT_CLASS_NAME, text: SEARCH_LABELS[TripEnd.to]})
    this.searchLabel.htmlFor = INPUT_ID
    this.input = element({tag: "input", className: "trip-search-input"})
    this.input.id = INPUT_ID
    this.input.type = "text"
    this.input.autocomplete = "off"
    this.input.spellcheck = false
    this.input.placeholder = SEARCH_LABELS[TripEnd.to]
    this.input.setAttribute("role", "combobox")
    this.input.setAttribute("aria-autocomplete", "list")
    this.input.setAttribute("aria-controls", LISTBOX_ID)
    this.input.setAttribute("aria-expanded", "false")
    this.input.addEventListener("focus", () => { this.openSearch() })
    this.input.addEventListener("input", () => { this.typed() })
    this.input.addEventListener("keydown", (event) => { this.keydownCallback(event) })
    searchBox.append(this.searchDot, this.searchLabel, this.input)

    this.listbox = element({tag: "div", className: "trip-suggestions"})
    this.listbox.id = LISTBOX_ID
    this.listbox.setAttribute("role", "listbox")
    this.listbox.setAttribute("aria-label", "Suggestions")
    this.listbox.hidden = true
    // A press on an option keeps the focus in the search box, so the list
    // stays open until the click chooses it.
    this.listbox.addEventListener("mousedown", keepFocusCallback)
    this.listbox.addEventListener("click", (event) => { this.optionClickCallback(event) })

    this.credit = element({tag: "p", className: "trip-credit"})
    const creditLink = element({tag: "a", className: "inline-target", text: OSM_CREDIT.linkText})
    creditLink.href = OSM_CREDIT.href
    creditLink.target = "_blank"
    creditLink.rel = "noopener noreferrer"
    this.credit.append(`${OSM_CREDIT.text} `, creditLink)
    this.credit.hidden = true

    this.searchStatus = element({tag: "div", className: HIDDEN_TEXT_CLASS_NAME})
    this.searchStatus.setAttribute("role", "status")

    const search = element({tag: "div", className: "trip-search"})
    search.append(fromRow, searchBox, this.listbox, this.credit, this.searchStatus)
    search.addEventListener("focusout", (event) => { this.focusOutCallback(event) })
    this.searchElement = search

    this.status = element({tag: "div", className: "trip-status"})
    this.status.setAttribute("role", "status")
    this.windowLine = element({tag: "p", className: "trip-window"})
    this.journeysElement = element({tag: "div", className: "trip-journeys"})

    this.clearButton = button({className: "panel-detail-action trip-clear", text: "Clear trip"})
    this.clearButton.addEventListener("click", () => { this.clear() })

    this.el.replaceChildren(search, this.buildWhen(), this.status, this.windowLine, this.buildSorts(), this.journeysElement, this.clearButton)
    this.writeEnds()
    this.writeWhen()
  },

  // The strip above the sheet's tabs: pressing it opens this tab, and its
  // End trip does what Clear trip does.
  buildStrip() {
    const host = document.getElementById(STRIP_ID)
    assertCondition(host !== null, "trip planner: the page has no element for the trip strip")
    const onOpen = () => { this.el.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true})) }
    return createStripView({host, onOpen, onEnd: () => { this.endTrip() }})
  },

  // Takes the strip away and tells the stop details view that no journey is
  // chosen.
  hideStrip() {
    this.stripView.hide()
    clearChosenJourney()
  },

  // The rider's edit of the filter ended the trip's filter, and the strip
  // with it.
  endFilter() {
    this.isFilterSent = false
    this.isStripEnded = true

    this.hideStrip()
  },

  // End trip leaves the strip that held focus, so focus moves to the Trip
  // tab, which stays on the page.
  endTrip() {
    const wasFocusInStrip = this.stripView.contains(document.activeElement)
    this.clear()

    if (wasFocusInStrip) {
      document.getElementById(TRIP_TAB_ID).focus()
    }
  },

  // Writes the strip of the selected journey, or takes it away where the
  // trip's filter ended or no journey is selected.
  writeStrip({cards, lives}) {
    const card = cards.find((candidate) => candidate.order === this.selectedIndex)
    const isCardMissing = card === undefined
    const isStripOff = this.isStripEnded || isCardMissing

    if (isStripOff) {
      this.hideStrip()
      return
    }

    const {serviceDayStartsMs} = this.shown
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    const live = lives[card.order]
    const strip = tripStrip({card, live, names: this.names, serviceDayStartsMs, timeZone})
    this.stripView.write(strip)
    const {origin} = this.shown
    setChosenJourney({journey: card.row.journey, live, leadText: strip.leadText, arriveText: strip.arriveText, serviceDayStartsMs, timeZone, names: this.names, origin, nowMs: Date.now()})
  },

  // The sorts of the journey list, as a group of toggle buttons shown with
  // the journeys.
  buildSorts() {
    this.sortsElement = element({tag: "div", className: "trip-sorts"})
    this.sortsElement.setAttribute("role", "group")
    this.sortsElement.setAttribute("aria-label", "Sort journeys")
    this.sortsElement.hidden = true
    this.sortButtons = {}

    for (const sort of Object.values(SortKind)) {
      const sortButton = button({className: "trip-sort", text: SORT_LABELS[sort]})
      sortButton.setAttribute("aria-pressed", String(sort === this.sort))
      sortButton.addEventListener("click", () => { this.setSort(sort) })
      this.sortButtons[sort] = sortButton
      this.sortsElement.append(sortButton)
    }

    return this.sortsElement
  },

  setSort(sort) {
    this.sort = sort

    for (const [kind, sortButton] of Object.entries(this.sortButtons)) {
      sortButton.setAttribute("aria-pressed", String(kind === sort))
    }

    if (this.shown !== null) {
      this.writeJourneys(this.rows())
    }
  },

  // Holds the boarding stops of the journeys' first rides open, within the
  // page's budget of open stops, so their live arrivals move the cards.
  holdLiveStops() {
    const stopIds = liveStopIds({journeys: this.shown.journeys, countMax: this.openCountMax})

    for (const stopId of stopIds) {
      this.liveStops.add(stopId)
      holdStop({pushEvent: this.push, stopId, holder: TRIP_STOP_HOLDER})
    }
  },

  releaseLiveStops() {
    for (const stopId of this.liveStops) {
      releaseStop({pushEvent: this.push, stopId, holder: TRIP_STOP_HOLDER})
    }

    this.liveStops = new Set()
    this.shownByStop = {}
  },

  resendLiveStops() {
    for (const stopId of this.liveStops) {
      holdStop({pushEvent: this.push, stopId, holder: TRIP_STOP_HOLDER})
    }
  },

  // An answer for a stop the cards hold moves the cards with it.
  liveArrivals(shown) {
    const isHeld = this.liveStops.has(shown.stop_id)
    const isShowing = isHeld && this.shown !== null

    if (isShowing) {
      this.shownByStop = {...this.shownByStop, [shown.stop_id]: shown}
      this.writeJourneys(this.rows())
    }
  },

  // The cards count down between answers.
  tickCards() {
    if (this.shown !== null) {
      this.writeJourneys(this.rows())
    }
  },

  // The switch of when the trip is for, as a group of toggle buttons, and
  // the day and the browser's own time input a chosen time reads.
  buildWhen() {
    const when = element({tag: "div", className: "trip-when"})
    const modes = element({tag: "div", className: "trip-modes"})
    modes.setAttribute("role", "group")
    modes.setAttribute("aria-label", "When")
    this.modeButtons = {}

    for (const mode of Object.values(TimeMode)) {
      const modeButton = button({className: "trip-mode", text: MODE_LABELS[mode]})
      modeButton.addEventListener("click", () => { this.setMode(mode) })
      this.modeButtons[mode] = modeButton
      modes.append(modeButton)
    }

    this.timeRow = element({tag: "div", className: "trip-time"})
    const dayField = element({tag: "div", className: "trip-time-field"})
    const dayLabel = element({tag: "label", className: "trip-time-label", text: "Day"})
    dayLabel.htmlFor = "trip-day"
    this.daySelect = element({tag: "select", className: "trip-time-input"})
    this.daySelect.id = "trip-day"

    for (const day of Object.values(DayChoice)) {
      const option = element({tag: "option", className: "", text: DAY_LABELS[day]})
      option.value = day
      this.daySelect.append(option)
    }

    this.daySelect.addEventListener("change", () => { this.setClock({day: this.daySelect.value, clockText: this.when.clockText}) })
    dayField.append(dayLabel, this.daySelect)

    const clockField = element({tag: "div", className: "trip-time-field"})
    const clockLabel = element({tag: "label", className: "trip-time-label", text: "Time"})
    clockLabel.htmlFor = "trip-clock"
    this.clockInput = element({tag: "input", className: "trip-time-input"})
    this.clockInput.id = "trip-clock"
    this.clockInput.type = "time"
    this.clockInput.addEventListener("change", () => { this.setClock({day: this.when.day, clockText: this.clockInput.value}) })
    clockField.append(clockLabel, this.clockInput)

    this.timeRow.append(dayField, clockField)
    when.append(modes, this.timeRow)
    return when
  },

  writeWhen() {
    for (const [mode, modeButton] of Object.entries(this.modeButtons)) {
      modeButton.setAttribute("aria-pressed", String(mode === this.when.mode))
    }

    this.timeRow.hidden = this.when.mode === TimeMode.now
    this.daySelect.value = this.when.day
    this.clockInput.value = this.when.clockText
  },

  // Switches when the trip is for; a chosen time starts at the next five
  // minutes the first time one is shown.
  setMode(mode) {
    const isChosenTime = mode !== TimeMode.now
    const isUnset = this.when.clockText === ""
    const isFirstChosen = isChosenTime && isUnset
    let {day, clockText} = this.when

    if (isFirstChosen) {
      const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
      const started = defaultClock({nowMs: Date.now(), timeZone})
      day = started.day
      clockText = started.clockText
    }

    this.when = {mode, day, clockText}
    this.writeWhen()
    this.plan()
  },

  setClock({day, clockText}) {
    this.when = {mode: this.when.mode, day, clockText}
    this.writeWhen()
    this.plan()
  },

  // The From chip, the search box's value and label, and whether a trip
  // can be cleared.
  writeEnds() {
    const from = this.ends[TripEnd.from]
    this.fromValue.textContent = endText(from) || EMPTY_FROM_TEXT
    this.fromValue.classList.toggle("trip-field-empty", from.kind === EndKind.none)
    this.fromChip.setAttribute("aria-label", `From: ${this.fromValue.textContent}. Change the start`)
    this.searchLabel.textContent = SEARCH_LABELS[this.searching]
    this.input.placeholder = SEARCH_LABELS[this.searching]
    this.searchDot.className = `trip-dot trip-dot-${this.searching}`

    if (!this.isListOpen()) {
      this.input.value = endText(this.ends[this.searching])
    }

    const isOpen = from.kind !== EndKind.none || this.ends[TripEnd.to].kind !== EndKind.none
    this.clearButton.hidden = isOpen === false
  },

  // Has the search box search for `end` and takes the focus to it.
  searchFor(end) {
    const isFocused = document.activeElement === this.input
    this.searching = end
    this.closeList()
    this.writeEnds()
    this.input.focus()

    // A box that has the focus already gets no focus event.
    if (isFocused) {
      this.openSearch()
    }
  },

  isListOpen() {
    return this.listbox.hidden === false
  },

  // When the box takes focus the files load, its text is selected so
  // typing replaces it, and the list offers what an empty text does.
  openSearch() {
    this.searchFiles.warm({routingManifestUrl: this.manifestUrl})
    this.input.select()
    this.searchText = ""
    this.listbox.hidden = false
    this.input.setAttribute("aria-expanded", "true")
    this.refreshList()
    this.searchWhenLoaded()
    this.holdSearchPosition()
  },

  // Holds the page's position watch while the list is open, where the
  // browser gives the position with no prompt, so the results rank from
  // where the rider stands; a fix writes the list again.
  async holdSearchPosition() {
    const granted = await permissionGranted()
    const isHeld = granted && this.isListOpen()

    if (!isHeld) {
      return
    }

    const onOutcome = (outcome) => {
      const isFirstFix = outcome.kind === OutcomeKind.fix && this.searchFix === null
      this.searchFix = null

      if (outcome.kind === OutcomeKind.fix) {
        this.searchFix = outcome.fix
      }

      if (isFirstFix) {
        this.refreshList()
      }
    }

    holdPosition({holder: SEARCH_HOLDER, onOutcome})
  },

  // Searches again once the files a search reads have loaded, so a list
  // written before they did gains their results.
  async searchWhenLoaded() {
    const pending = this.searchFiles.pendingLoads()
    await Promise.allSettled(pending)

    if (this.isListOpen()) {
      this.refreshList()
    }
  },

  typed() {
    this.searchText = this.input.value

    if (!this.isListOpen()) {
      this.listbox.hidden = false
      this.input.setAttribute("aria-expanded", "true")
    }

    this.refreshList()
  },

  // Writes the list for the text typed, once each source has answered;
  // the answer to an earlier text is dropped.
  async refreshList() {
    if (!this.isListOpen()) {
      return
    }

    this.searchCount += 1
    const searchNumber = this.searchCount
    const text = this.searchText
    const position = this.riderPosition()
    let rider = null

    if (position.kind === PositionKind.known) {
      rider = {lat: position.lat, lon: position.lon}
    }

    const anchor = this.searchFiles.endPosition({end: this.ends[OTHER_END[this.searching]], rider})
    const {near} = searchPoints({anchor, rider, fallback: this.mapSearchCenter()})
    const found = await this.searchFiles.search({text, near, rider})

    if (searchNumber !== this.searchCount) {
      return
    }

    const recents = storedSettings.listRecentTrips(RECENT_TRIP_COUNT_MAX)
    const list = suggestionList({text, end: this.searching, recents, favorites: storedFavorites(), found})
    this.writeList(list)
  },

  // The rider's position, the one point a distance is measured from: the
  // fix while the list holds the position watch, or the latest while it is
  // fresh, or else unknown.
  riderPosition() {
    if (this.searchFix !== null) {
      return {kind: PositionKind.known, lat: this.searchFix.latitude, lon: this.searchFix.longitude}
    }

    const latest = latestFix()

    if (latest.kind === LatestKind.fresh) {
      return {kind: PositionKind.known, lat: latest.fix.latitude, lon: latest.fix.longitude}
    }

    return {kind: PositionKind.unknown}
  },

  // The point a search ranks its results by when it has neither the other
  // end nor the rider's position: the map's center.
  mapSearchCenter() {
    const center = this.tripMap.center()

    if (center.kind === CenterKind.center) {
      return {lat: center.lat, lon: center.lon}
    }

    return SEARCH_CENTER_DEFAULT
  },

  writeList(list) {
    const items = []
    const options = []

    for (const option of list.leading) {
      items.push(optionElement({option, index: options.length}))
      options.push(option)
    }

    for (const group of list.groups) {
      items.push(groupElement({group, firstIndex: options.length}))

      for (const option of group.options) {
        options.push(option)
      }
    }

    for (const option of list.trailing) {
      items.push(optionElement({option, index: options.length}))
      options.push(option)
    }

    this.options = options
    this.activeIndex = NONE_INDEX
    this.input.removeAttribute("aria-activedescendant")
    this.listbox.replaceChildren(fragmentOf(items))
    this.credit.hidden = !list.isCredited
    this.searchStatus.textContent = suggestionsAnnouncement(list.count)
  },

  closeList() {
    releasePosition({holder: SEARCH_HOLDER})
    this.searchFix = null
    this.searchCount += 1
    this.listbox.hidden = true
    this.listbox.replaceChildren()
    this.credit.hidden = true
    this.options = []
    this.activeIndex = NONE_INDEX
    this.input.setAttribute("aria-expanded", "false")
    this.input.removeAttribute("aria-activedescendant")
    this.searchStatus.textContent = ""
    this.input.value = endText(this.ends[this.searching])
  },

  // Focus leaving the search closes its list.
  focusOutCallback(event) {
    const isInside = this.searchElement.contains(event.relatedTarget)

    if (!isInside) {
      this.closeList()
      this.searching = TripEnd.to
      this.writeEnds()
    }
  },

  keydownCallback(event) {
    const move = KEY_MOVES[event.key]

    if (move !== undefined) {
      this.moveActive({event, move})
    } else if (event.key === "Enter") {
      this.chooseActive(event)
    } else if (event.key === "Escape") {
      this.escape(event)
    }
  },

  moveActive({event, move}) {
    const isHomeOrEnd = move === OptionMove.home || move === OptionMove.end
    const isTextMove = isHomeOrEnd && this.activeIndex === NONE_INDEX
    const isNoMove = isTextMove || this.options.length === 0

    // Home and End move the caret in the text until an option is active.
    if (isNoMove) {
      return
    }

    event.preventDefault()
    this.activeIndex = movedOptionIndex({move, index: this.activeIndex, count: this.options.length})
    this.showActive()
  },

  showActive() {
    for (const item of this.listbox.querySelectorAll("[role=option]")) {
      const isActive = Number(item.dataset.optionIndex) === this.activeIndex
      item.setAttribute("aria-selected", String(isActive))

      if (isActive) {
        this.input.setAttribute("aria-activedescendant", item.id)
        item.scrollIntoView({block: "nearest"})
      }
    }
  },

  chooseActive(event) {
    if (this.activeIndex === NONE_INDEX) {
      return
    }

    event.preventDefault()
    this.choose(this.options[this.activeIndex])
  },

  // Escape with the list open closes it and stays in the box; with it
  // closed it reaches the sheet, which collapses.
  escape(event) {
    if (this.isListOpen()) {
      event.stopPropagation()
      this.closeList()
    }
  },

  optionClickCallback(event) {
    const item = event.target.closest("[role=option]")

    if (item !== null) {
      this.choose(this.options[Number(item.dataset.optionIndex)])
    }
  },

  choose(option) {
    const {choice} = option
    const end = this.searching
    this.closeList()
    this.searching = TripEnd.to

    switch (choice.kind) {
      case ChoiceKind.end:
        this.setEnd({end, value: choice.end})
        break
      case ChoiceKind.trip:
        this.ends = {[TripEnd.from]: endOfStored(choice.trip.from), [TripEnd.to]: endOfStored(choice.trip.to)}
        this.writeEnds()
        this.plan()
        break
      case ChoiceKind.pick:
        this.writeEnds()
        this.pick(end)
        break
      default:
        unreachable(choice.kind, "trip planner: a choice of unknown kind")
    }
  },

  // Waits for the next stop the rider taps on the map, with the sheet out
  // of the way on a phone.
  pick(end) {
    startPicking(end)

    const note = element({tag: "p", className: "trip-note", text: ""})
    const picking = pickingMessage(FIELD_LABELS[end])
    appendMessage({element: note, message: picking})
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

    this.ends[end] = value
    this.writeEnds()
    this.plan()
  },

  swap() {
    const swapped = swappedEnds({from: this.ends[TripEnd.from], to: this.ends[TripEnd.to]})
    this.ends = {[TripEnd.from]: swapped.from, [TripEnd.to]: swapped.to}
    this.writeEnds()
    this.plan()
  },

  // Ends the trip: no end, no journey, nothing drawn, and the rider's own
  // filter on the map. From starts again as the rider's location where the
  // browser gives it with no prompt.
  clear() {
    stopPicking()
    this.ends = {[TripEnd.from]: NO_END, [TripEnd.to]: NO_END}
    this.when = LEAVING_NOW
    this.searching = TripEnd.to
    this.writeEnds()
    this.writeWhen()
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
    this.sortsElement.hidden = true
    this.releaseLiveStops()
    this.tripMap.clear()

    this.hideStrip()

    if (this.isFilterSent) {
      this.events.push({name: CLEAR_EVENT_NAME, payload: {}})
      this.isFilterSent = false
    }
  },

  showState({kind, retry}) {
    const note = element({tag: "p", className: "trip-note", text: ""})
    const message = stateMessage(kind)
    appendMessage({element: note, message})
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
    } else if (query.kind === QueryKind.samePoint) {
      this.showState({kind: StateKind.samePoint, retry: false})
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

    const manifestOutcome = await fetchManifest({origin: PAGE_ORIGIN, path: this.manifestUrl})

    if (queryNumber !== this.queryCount) {
      return
    } else if (manifestOutcome.kind === JourneysKind.failed) {
      this.showState({kind: failureState(manifestOutcome), retry: true})
      return
    }

    const {manifest} = manifestOutcome
    const nowMs = Date.now()
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    const planned = plannedTime({when: this.when, nowMs, timeZone, manifest})

    if (planned.kind === PlannedKind.refused) {
      this.showState({kind: planned.state, retry: planned.state === StateKind.noServiceDate})
      return
    }

    const answer = await routeTo({origin: PAGE_ORIGIN, searchFiles: this.searchFiles, manifest, planned, from: start.from, to: query.to})

    if (queryNumber !== this.queryCount) {
      return
    }

    this.answer({answer, planned, nowMs, manifest, origin: start.origin, trip: query})
  },

  // The router's start for `from`: a stop, a point, or the rider's
  // position, which stays in this module.
  async startOf(from) {
    if (from.kind === EndKind.stop) {
      return {kind: StartKind.start, from: {kind: FromKind.stop, stopId: from.stopId}, origin: null}
    } else if (from.kind === EndKind.point) {
      return {kind: StartKind.start, from: {kind: FromKind.position, lat: from.lat, lon: from.lon}, origin: {lat: from.lat, lon: from.lon}}
    }

    const located = await currentPosition()

    if (located.kind === StartKind.refused) {
      return located
    }

    const {lat, lon} = located.position
    return {kind: StartKind.start, from: {kind: FromKind.position, lat, lon}, origin: located.position}
  },

  answer({answer, planned, nowMs, manifest, origin, trip}) {
    const outcome = answerOutcome({answer, planned})

    if (outcome.kind === AnswerKind.state) {
      if (answer.kind === JourneysKind.failed) {
        console.warn("Journeys not routed", answer.reason, answer.path)
      }

      this.showState({kind: outcome.state, retry: outcome.isRetry})
      return
    }

    this.status.replaceChildren()
    storedSettings.addRecentTrip({trip: {from: trip.from, to: trip.to}, countMax: RECENT_TRIP_COUNT_MAX})

    this.shown = {
      journeys: answer.journeys,
      planned,
      nowMs,
      serviceDayStartsMs: serviceDayStartsOf(manifest),
      walkSpeedsMPerS: walkSpeedsOf(manifest),
      originName: endText(trip.from),
      origin,
      queryNumber: this.queryCount
    }

    this.headsigns = new Map()
    this.snapshotStopNames = {}
    this.expandedRides = new Set()

    this.names = NO_NAMES
    const rows = this.rows()
    this.selectedIndex = rows.findIndex(isMarkedRow)
    this.sortsElement.hidden = false
    this.writeJourneys(rows)
    this.selectJourney({index: this.selectedIndex, rows})
    this.announceJourneys(rows)
    this.requestNames()
    this.holdLiveStops()
    this.loadJourneyNames(manifest)
  },

  // The status line says, out of sight, what the list that appeared holds,
  // so a screen reader announces it.
  announceJourneys(rows) {
    const line = element({tag: "p", className: HIDDEN_TEXT_CLASS_NAME, text: journeysAnnouncement(rows)})
    this.status.replaceChildren(line)
  },

  rows() {
    const {journeys, nowMs, serviceDayStartsMs} = this.shown
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    return journeyRows({journeys, nowMs, serviceDayStartsMs, names: this.names, timeZone})
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
    const {journeys, planned, nowMs, serviceDayStartsMs} = this.shown
    this.windowLine.textContent = windowText({journeys, planned, nowMs, serviceDayStartsMs, timeZone})
    const focused = focusedKey(this.journeysElement)
    const cards = []
    const lives = {}

    for (const [order, row] of rows.entries()) {
      const live = firstRideLive({journey: row.journey, shownByStop: this.shownByStop, serviceDayStartsMs})
      lives[order] = live
      cards.push(journeyCard({row, order, live, nowMs: Date.now(), serviceDayStartsMs, names: this.names, timeZone}))
    }

    this.writeStrip({cards, lives})
    const items = []

    for (const card of sortedCards({cards, sort: this.sort})) {
      const index = card.order
      const item = cardElement(card)
      const isSelected = index === this.selectedIndex
      item.setAttribute("aria-pressed", String(isSelected))
      item.addEventListener("click", () => { this.selectJourney({index, rows: this.rows()}) })
      items.push(item)

      if (isSelected) {
        items.push(this.timelineElement(card))
      }
    }

    this.journeysElement.replaceChildren(fragmentOf(items))
    refocus({container: this.journeysElement, key: focused})
  },

  // The timeline of the selected journey, `card`'s: a list in the order
  // taken, each row's rail and text drawn for the eye and its sentence for
  // a screen reader, a ride's passed stops behind a disclosure.
  timelineElement(card) {
    const {journey} = card.row
    const live = firstRideLive({journey, shownByStop: this.shownByStop, serviceDayStartsMs: this.shown.serviceDayStartsMs})
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    // The page's names come first; the snapshot's name the stops a ride
    // only passes, which the page is not asked for.
    const names = {stops: {...this.snapshotStopNames, ...this.names.stops}, routes: this.names.routes}
    const rows = timelineRows({
      journey,
      names,
      headsigns: this.headsigns,
      live,
      originName: this.shown.originName,
      serviceDayStartsMs: this.shown.serviceDayStartsMs,
      timeZone,
      walkSpeedMPerS: this.shown.walkSpeedsMPerS[journey.serviceDate],
    })
    const timeline = element({tag: "ol", className: "trip-timeline"})
    timeline.setAttribute("aria-label", "Steps")

    for (const row of rows) {
      timeline.append(this.timelineRowElement({row, journeyIndex: card.order}))
    }

    return timeline
  },

  timelineRowElement({row, journeyIndex}) {
    const rowItem = element({tag: "li", className: `trip-timeline-row trip-timeline-${row.kind}`})
    const time = element({tag: "span", className: "trip-timeline-time", text: row.timeText})
    time.setAttribute("aria-hidden", "true")
    rowItem.append(time, railElement(row), rowBodyElement(row))
    const isExpandable = row.kind === TimelineRowKind.ride && row.passedStops.length > 0

    if (isExpandable) {
      for (const part of this.passedStopsElements({row, journeyIndex})) {
        rowItem.append(part)
      }
    } else {
      rowItem.append(element({tag: "span", className: HIDDEN_TEXT_CLASS_NAME, text: row.sentence}))
    }

    return rowItem
  },

  // A ride's "Ride 3 stops" disclosure, named by the ride's sentence, and
  // the stops it passes, shown while it is expanded.
  passedStopsElements({row, journeyIndex}) {
    const key = `ride:${journeyIndex}:${row.legIndex}`
    const isExpanded = this.expandedRides.has(key)
    const listId = `trip-passed-${journeyIndex}-${row.legIndex}`
    const toggle = button({className: "trip-timeline-expand inline-target", text: row.stopCountText})
    toggle.dataset.focusKey = key
    toggle.setAttribute("aria-label", row.sentence)
    toggle.setAttribute("aria-expanded", String(isExpanded))
    toggle.setAttribute("aria-controls", listId)
    toggle.addEventListener("click", () => { this.toggleRide(key) })
    const passed = element({tag: "ol", className: "trip-timeline-passed"})
    passed.id = listId
    passed.hidden = !isExpanded

    for (const name of row.passedStops) {
      passed.append(element({tag: "li", className: "", text: name}))
    }

    return [toggle, passed]
  },

  toggleRide(key) {
    if (this.expandedRides.has(key)) {
      this.expandedRides.delete(key)
    } else {
      this.expandedRides.add(key)
    }

    this.writeJourneys(this.rows())
  },

  // Reads the headsigns and the stop names of the service dates of the
  // journeys shown from their snapshots' names files, then writes the
  // timeline again with them.
  async loadJourneyNames(manifest) {
    const {queryNumber, journeys} = this.shown
    const serviceDates = Array.from(journeys, serviceDateOfJourney)
    const dates = new Set(serviceDates)
    const entries = manifest.snapshots.filter((entry) => dates.has(entry.serviceDate))
    const pending = Array.from(entries, (entry) => this.searchFiles.journeyNames({entry}))
    const settled = await Promise.allSettled(pending)
    const isCurrent = this.shown !== null && this.shown.queryNumber === queryNumber

    if (!isCurrent) {
      return
    }

    const headsigns = new Map()
    let stops = {}

    for (const outcome of settled) {
      if (outcome.status === "fulfilled") {
        for (const [key, headsign] of outcome.value.headsigns) {
          headsigns.set(key, headsign)
        }

        stops = {...stops, ...outcome.value.stops}
      } else {
        console.warn("Journey names not read", outcome.reason)
      }
    }

    this.headsigns = headsigns
    this.snapshotStopNames = stops
    this.writeJourneys(this.rows())
  },

  // Selects the journey at `index`: its steps in the list, its drawing on
  // the map, and its routes as the map's filter.
  selectJourney({index, rows}) {
    this.selectedIndex = index
    this.isStripEnded = false
    this.writeJourneys(rows)

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
    this.stopTicker()
    this.releaseLiveStops()

    this.hideStrip()

    stopPicking()
    releasePosition({holder: TRIP_HOLDER})
    releasePosition({holder: SEARCH_HOLDER})
    this.events.release()
  }
}
