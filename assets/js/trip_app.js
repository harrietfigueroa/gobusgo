// The trip planner app, which an AI host renders from a `ui://` resource when
// the model calls `plan_trip`. It reads the rider's words for the two ends
// and the time from the host, finds the places with the "Where to?" search
// over the files the application publishes, routes the trip in the browser
// with the Trip tab's router, shows the journeys as the Trip tab's cards, and
// hands the one the rider chooses to the model.
//
// The bundle loads no LiveView and no map. Every file is fetched from the
// origin the document names in `data-file-origin`, since the app runs in a
// sandbox of another origin, and no request names a place, a time, or the
// rider's position. Every text is a text node: names come from outside the
// application and are never parsed as HTML.

import {assertCondition, unreachable} from "./assert"
import {button, element} from "./dom_element"
import {cardElement} from "./journey_card_view"
import {firstRideLive, journeyCard} from "./journey_cards"
import {appendMessage} from "./message"
import {HostMethod, OutcomeKind, ThemeKind, createHost, isLocationGranted, sendMessage, themeOf, updateModelContext} from "./mcp_host"
import {ResolutionKind, resolution} from "./mcp_trip_ends"
import {InputKind, toolInputArguments, toolResultArguments, tripInput} from "./mcp_trip_input"
import {chosenMessage, journeyContext} from "./mcp_trip_journey"
import {PlanKind, planTrip} from "./mcp_trip_plan"
import {SEARCH_CENTER_DEFAULT} from "./where_to"
import {createSearchFiles} from "./where_to_files"
import {EndKind, LOCATION_END, QueryKind, StateKind, TimeMode, TripEnd, journeyRows, journeysAnnouncement, queryOf, stateMessage} from "./trip_plan"

const APP_INFO = Object.freeze({name: "gobusgo-trip-planner", version: "1"})
const ROUTING_MANIFEST_PATH = "/api/routing/manifest"
const LOCATION_TIMEOUT_MS = 10 * 1000
const LOCATION_AGE_MS_MAX = 60 * 1000
const FIELD_LABELS = Object.freeze({[TripEnd.from]: "From", [TripEnd.to]: "To"})
const LOCATION_TEXT = "My location"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
const PROTOCOL_PREFIX = /^https?:\/\//
// The focus key of no element: every element's key is non-empty.
const NO_FOCUS_KEY = ""

// The kinds of what an end of the trip is while the app resolves it.
const EndStateKind = Object.freeze({waiting: "waiting", loading: "loading", resolved: "resolved", choices: "choices", none: "none", locating: "locating"})

const WAITING = Object.freeze({kind: EndStateKind.waiting, isEditing: false, text: ""})

function endTextOf(end) {
  switch (end.kind) {
    case EndKind.location:
      return LOCATION_TEXT
    case EndKind.stop:
    case EndKind.point:
      return end.name
    default:
      return unreachable(end.kind, "trip app: an end of unknown kind")
  }
}

const END_ORDER = Object.freeze([TripEnd.from, TripEnd.to])

function sentText(isSent) {
  if (isSent) {
    return "Sent to your assistant."
  }

  return "Your assistant did not take the journey."
}

function dayText(day) {
  if (day === "tomorrow") {
    return " tomorrow"
  }

  return ""
}

// What the time of the trip reads as: leaving now, leaving at a time, or arriving by one.
function whenText(when) {
  switch (when.mode) {
    case TimeMode.now:
      return "Leaving now"
    case TimeMode.departAt:
      return `Leaving at ${when.clockText}${dayText(when.day)}`
    case TimeMode.arriveBy:
      return `Arriving by ${when.clockText}${dayText(when.day)}`
    default:
      return unreachable(when.mode, "trip app: a time mode of unknown kind")
  }
}

function focusedKey(container) {
  const focused = document.activeElement
  const isInside = focused !== null && container.contains(focused)

  if (isInside) {
    return focused.dataset.focusKey
  }

  return NO_FOCUS_KEY
}

function refocus({container, key}) {
  if (key === NO_FOCUS_KEY) {
    return
  }

  const target = Array.from(container.querySelectorAll("[data-focus-key]")).find((candidate) => candidate.dataset.focusKey === key)

  if (target !== undefined) {
    target.focus()
  }
}

function currentPosition() {
  return new Promise((resolve) => {
    const options = {enableHighAccuracy: false, timeout: LOCATION_TIMEOUT_MS, maximumAge: LOCATION_AGE_MS_MAX}

    navigator.geolocation.getCurrentPosition(
      (fix) => { resolve({isFound: true, position: {lat: fix.coords.latitude, lon: fix.coords.longitude}}) },
      () => { resolve({isFound: false}) },
      options
    )
  })
}

function searchForm({end, text, onSearch}) {
  const form = element({tag: "form", className: "trip-search-box"})
  const label = element({tag: "label", className: HIDDEN_TEXT_CLASS_NAME, text: `Search for ${FIELD_LABELS[end].toLowerCase()}`})
  const input = element({tag: "input", className: "trip-search-input"})
  input.type = "search"
  input.value = text
  input.autocomplete = "off"
  input.spellcheck = false
  input.dataset.focusKey = `search:${end}`
  label.htmlFor = `trip-search-${end}`
  input.id = `trip-search-${end}`
  const submit = button({className: "panel-detail-action", text: "Search"})
  submit.type = "submit"
  form.append(label, input, submit)
  form.addEventListener("submit", (event) => {
    event.preventDefault()
    const typed = input.value.trim()

    if (typed !== "") {
      onSearch({end, text: typed})
    }
  })

  return form
}

function choiceElements({end, state, onChoose}) {
  const items = []

  for (const group of state.groups) {
    items.push(element({tag: "div", className: "trip-suggestion-group-label", text: group.label}))

    for (const option of group.options) {
      const item = button({className: "trip-suggestion"})
      item.dataset.focusKey = `option:${end}:${option.key}`
      item.append(element({tag: "span", className: "trip-field-value", text: option.text}))

      if (option.detail !== "") {
        item.append(element({tag: "span", className: "trip-suggestion-detail", text: option.detail}))
      }

      item.addEventListener("click", () => { onChoose({end, option}) })
      items.push(item)
    }
  }

  return items
}

// One end of the trip: what it resolved to, or the choices and the search that settle it.
function endElement({end, state, isLocationOffered, handlers}) {
  const section = element({tag: "section", className: "trip-search"})
  section.setAttribute("aria-label", FIELD_LABELS[end])
  const row = element({tag: "div", className: "trip-from"})
  row.append(element({tag: "span", className: "trip-field-label", text: FIELD_LABELS[end]}))
  section.append(row)

  switch (state.kind) {
    case EndStateKind.waiting:
      row.append(element({tag: "span", className: "trip-field-empty", text: "Waiting for the trip"}))
      break
    case EndStateKind.loading:
    case EndStateKind.locating:
      row.append(element({tag: "span", className: "trip-field-empty", text: `Looking for ${state.text}`}))
      break
    case EndStateKind.resolved: {
      const chip = button({className: "trip-from-chip"})
      chip.dataset.focusKey = `change:${end}`
      chip.setAttribute("aria-label", `${FIELD_LABELS[end]}: ${endTextOf(state.end)}. Change`)
      chip.append(element({tag: "span", className: `trip-dot trip-dot-${end}`}), element({tag: "span", className: "trip-field-value", text: endTextOf(state.end)}))
      chip.addEventListener("click", () => { handlers.onEdit(end) })
      row.append(chip)
      break
    }
    case EndStateKind.choices:
      section.append(element({tag: "p", className: "trip-note", text: `“${state.text}” matches several places. Choose one.`}))

      for (const choice of choiceElements({end, state, onChoose: handlers.onChoose})) {
        section.append(choice)
      }

      break
    case EndStateKind.none:
      section.append(element({tag: "p", className: "trip-note", text: `Nothing matches “${state.text}”. Try other words.`}))
      break
    default:
      unreachable(state.kind, "trip app: an end state of unknown kind")
  }

  const isUnsettled = state.kind === EndStateKind.choices || state.kind === EndStateKind.none
  const isSearching = state.isEditing || isUnsettled

  if (isSearching) {
    section.append(searchForm({end, text: state.text, onSearch: handlers.onSearch}))
  }

  const isLocationStart = isLocationOffered && end === TripEnd.from

  const isLocationButtonShown = isSearching && isLocationStart

  if (isLocationButtonShown) {
    const locate = button({className: "panel-detail-action", text: "Use my location"})
    locate.dataset.focusKey = "locate"
    locate.addEventListener("click", () => { handlers.onLocate() })
    section.append(locate)
  }

  return section
}

/**
 * Starts the app in `root`, the element of the document's `main`, with its
 * files fetched from `origin` and its conversation with the host over `host`.
 */
export function startTripApp({root, origin, host}) {
  assertCondition(PROTOCOL_PREFIX.test(origin), "trip app: the file origin is not an http address: " + origin)
  const files = createSearchFiles({origin})
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const app = {
    input: null,
    ends: {[TripEnd.from]: WAITING, [TripEnd.to]: WAITING},
    position: null,
    planCount: 0,
    plan: {kind: "idle"},
    chosen: {kind: "none"},
    isLocationOffered: false,
  }

  function searchNear() {
    if (app.position !== null) {
      return app.position
    }

    return SEARCH_CENTER_DEFAULT
  }

  function setEnd({end, state}) {
    app.ends[end] = state
    render()
  }

  async function resolveEnd({end, text}) {
    setEnd({end, state: {kind: EndStateKind.loading, isEditing: false, text}})
    files.warm({routingManifestUrl: ROUTING_MANIFEST_PATH})
    await Promise.allSettled(files.pendingLoads())
    const found = await files.search({text, near: searchNear()})
    const decided = resolution({text, end, found})

    switch (decided.kind) {
      case ResolutionKind.resolved:
        setEnd({end, state: {kind: EndStateKind.resolved, isEditing: false, text, end: decided.end}})
        break
      case ResolutionKind.choices:
        setEnd({end, state: {kind: EndStateKind.choices, isEditing: false, text, groups: decided.groups}})
        break
      case ResolutionKind.none:
        setEnd({end, state: {kind: EndStateKind.none, isEditing: false, text}})
        break
      default:
        unreachable(decided.kind, "trip app: a resolution of unknown kind")
    }

    await planWhenReady()
  }

  function resolvedEnd(end) {
    const state = app.ends[end]

    if (state.kind === EndStateKind.resolved) {
      return {kind: EndStateKind.resolved, end: state.end}
    }

    return {kind: EndStateKind.loading}
  }

  // Plans the trip once both ends are resolved; an answer to an earlier plan is dropped.
  async function planWhenReady() {
    app.planCount += 1
    const planNumber = app.planCount
    app.chosen = {kind: "none"}
    app.plan = {kind: "idle"}
    const fromEnd = resolvedEnd(TripEnd.from)
    const toEnd = resolvedEnd(TripEnd.to)
    const isFromResolved = fromEnd.kind === EndStateKind.resolved
    const isBothResolved = isFromResolved && toEnd.kind === EndStateKind.resolved

    if (!isBothResolved) {
      render()
      return
    }

    const from = fromEnd.end
    const to = toEnd.end
    const query = queryOf({from, to})

    if (query.kind !== QueryKind.ready) {
      app.plan = {kind: "state", state: planStateOf(query.kind), isRetry: false}
      render()
      return
    }

    app.plan = {kind: "planning"}
    render()
    const outcome = await planTrip({origin, files, from, to, when: app.input.when, position: app.position, nowMs: Date.now(), timeZone})

    if (planNumber !== app.planCount) {
      return
    }

    if (outcome.kind === PlanKind.state) {
      app.plan = {kind: "state", state: outcome.state, isRetry: outcome.isRetry}
    } else {
      app.plan = {kind: "journeys", outcome, from, to, nowMs: Date.now()}
    }

    render()
  }

  async function chooseJourney({row, shown}) {
    const fromName = endTextOf(shown.from)
    const toName = endTextOf(shown.to)
    const context = journeyContext({journey: row.journey, names: shown.outcome.names, serviceDayStartsMs: shown.outcome.serviceDayStartsMs, timeZone, from: fromName, to: toName})
    app.chosen = {kind: "sending"}
    render()
    const updated = await updateModelContext({host, structuredContent: context})
    const messaged = await sendMessage({host, text: chosenMessage({row, from: fromName, to: toName})})
    const isSent = updated.kind === OutcomeKind.answered && messaged.kind === OutcomeKind.answered
    app.chosen = {kind: "sent", isSent}
    render()
  }

  const handlers = {
    onSearch: ({end, text}) => { resolveEnd({end, text}) },
    onChoose: ({end, option}) => {
      setEnd({end, state: {kind: EndStateKind.resolved, isEditing: false, text: option.text, end: option.choice.end}})
      planWhenReady()
    },
    onEdit: (end) => { setEnd({end, state: {...app.ends[end], isEditing: true}}) },
    onLocate: async () => {
      setEnd({end: TripEnd.from, state: {kind: EndStateKind.locating, isEditing: false, text: LOCATION_TEXT}})
      const located = await currentPosition()

      if (located.isFound) {
        app.position = located.position
        setEnd({end: TripEnd.from, state: {kind: EndStateKind.resolved, isEditing: false, text: LOCATION_TEXT, end: LOCATION_END}})
      } else {
        setEnd({end: TripEnd.from, state: {kind: EndStateKind.none, isEditing: false, text: LOCATION_TEXT}})
      }

      await planWhenReady()
    },
  }

  // The journeys the plan found, as the Trip tab's rows, or none.
  function rowsShown() {
    if (app.plan.kind !== "journeys") {
      return []
    }

    const {outcome, nowMs} = app.plan
    return journeyRows({journeys: outcome.journeys, nowMs, serviceDayStartsMs: outcome.serviceDayStartsMs, names: outcome.names, timeZone})
  }

  function statusElement(rows) {
    const status = element({tag: "div", className: "trip-status"})
    status.setAttribute("role", "status")

    if (app.plan.kind === "journeys") {
      status.append(element({tag: "p", className: HIDDEN_TEXT_CLASS_NAME, text: journeysAnnouncement(rows)}))
    }

    if (app.plan.kind === "planning") {
      const note = element({tag: "p", className: "trip-note", text: ""})
      appendMessage({element: note, message: stateMessage(StateKind.loading)})
      status.append(note)
    }

    if (app.plan.kind === "state") {
      const note = element({tag: "p", className: "trip-note", text: ""})
      appendMessage({element: note, message: stateMessage(app.plan.state)})
      status.append(note)

      if (app.plan.isRetry) {
        const again = button({className: "panel-detail-action", text: "Try again"})
        again.dataset.focusKey = "retry"
        again.addEventListener("click", () => { planWhenReady() })
        status.append(again)
      }
    }

    return status
  }

  function journeysElement(rows) {
    const list = element({tag: "div", className: "trip-journeys"})
    const shown = app.plan

    for (const [order, row] of rows.entries()) {
      const {serviceDayStartsMs, names} = shown.outcome
      const live = firstRideLive({journey: row.journey, shownByStop: {}, serviceDayStartsMs})
      const card = journeyCard({row, order, live, nowMs: shown.nowMs, serviceDayStartsMs, names, timeZone})
      const item = cardElement(card)
      item.setAttribute("aria-pressed", "false")
      item.addEventListener("click", () => { chooseJourney({row, shown}) })
      list.append(item)
    }

    return list
  }

  function chosenElement() {
    const note = element({tag: "p", className: "trip-note", text: ""})
    note.setAttribute("role", "status")

    if (app.chosen.kind === "sending") {
      note.textContent = "Sending the journey to your assistant."
    } else if (app.chosen.kind === "sent") {
      note.textContent = sentText(app.chosen.isSent)
    }

    return note
  }

  function render() {
    const focused = focusedKey(root)
    const heading = element({tag: "h1", className: "mcp-trip-heading", text: "Trip planner"})
    const when = element({tag: "p", className: "trip-window", text: whenText(app.input.when)})
    const rows = rowsShown()
    root.replaceChildren(heading)

    for (const end of END_ORDER) {
      root.append(endElement({end, state: app.ends[end], isLocationOffered: app.isLocationOffered, handlers}))
    }

    root.append(when, statusElement(rows), journeysElement(rows), chosenElement())
    refocus({container: root, key: focused})
  }

  return Object.freeze({
    // Starts the trip `input` asks for: both ends are searched at once.
    start(input) {
      app.input = input
      app.planCount += 1
      app.ends = {[TripEnd.from]: WAITING, [TripEnd.to]: WAITING}
      render()
      resolveEnd({end: TripEnd.from, text: input.from})
      resolveEnd({end: TripEnd.to, text: input.to})
    },

    // Offers the rider's location as a start, once the host has said it grants it.
    offerLocation() {
      app.isLocationOffered = true
    },

    refuse(field) {
      root.replaceChildren(element({tag: "h1", className: "mcp-trip-heading", text: "Trip planner"}), element({tag: "p", className: "trip-note", text: `The trip's ${field} was not understood. Ask for the trip again.`}))
    },
  })
}

function planStateOf(kind) {
  switch (kind) {
    case QueryKind.sameStop:
      return StateKind.sameStop
    case QueryKind.samePoint:
      return StateKind.samePoint
    default:
      return unreachable(kind, "trip app: a query that is neither ready nor the same place twice")
  }
}

// The theme the host names, as the stylesheet's `data-theme`.
function applyTheme(hostContext) {
  const theme = themeOf(hostContext)

  if (theme.kind === ThemeKind.named) {
    document.documentElement.dataset.theme = theme.theme
  }
}

function showStandalone(root) {
  root.replaceChildren(element({tag: "h1", className: "mcp-trip-heading", text: "Trip planner"}), element({tag: "p", className: "trip-note", text: "This planner opens inside an AI assistant that supports MCP Apps."}))
}

// Tells the host how tall the app is, so it can size the frame.
function reportSize({host, body}) {
  const observer = new ResizeObserver(() => {
    host.notify({method: HostMethod.sizeChanged, params: {width: Math.ceil(body.scrollWidth), height: Math.ceil(body.scrollHeight)}})
  })

  observer.observe(body)
}

async function main() {
  const root = document.getElementById("mcp-trip-app")
  assertCondition(root !== null, "trip app: the document has no element for the app")
  const origin = document.body.dataset.fileOrigin
  const timers = {setTimeout: window.setTimeout.bind(window), clearTimeout: window.clearTimeout.bind(window)}
  const host = createHost({target: window.parent, events: window, appInfo: APP_INFO, timers})
  const planner = startTripApp({root, origin, host})
  let isStarted = false

  function startWith(value) {
    const input = tripInput(value)

    if (input.kind === InputKind.refused) {
      planner.refuse(input.field)
      return
    }

    isStarted = true
    planner.start(input)
  }

  // The host sends the arguments first and the result after; the result's
  // structured content holds the same arguments, which the app reads when
  // the arguments never came.
  host.onNotification(HostMethod.toolInput, (params) => { startWith(toolInputArguments(params)) })
  host.onNotification(HostMethod.toolResult, (params) => {
    if (!isStarted) {
      startWith(toolResultArguments(params))
    }
  })
  host.onNotification(HostMethod.hostContextChanged, applyTheme)

  const connected = await host.connect()

  if (connected.kind !== OutcomeKind.answered) {
    showStandalone(root)
    return
  }

  applyTheme(connected.result.hostContext)

  const isGranted = isLocationGranted(connected.result.hostCapabilities)
  const isLocatable = isGranted && "geolocation" in navigator

  if (isLocatable) {
    planner.offerLocation()
  }

  reportSize({host, body: document.body})
}

main()
