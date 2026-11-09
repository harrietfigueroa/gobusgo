// The one way the vehicle page's hooks talk to the server: `pageEvents(hook)`
// stands in for the hook's `pushEvent` and `handleEvent`. While the page's
// connection state is live, every event goes to LiveView as it would from
// the hook itself. Otherwise the page answers for itself from the saved
// offline bundle: a stop's position, the names of a trip, the trip's
// filter, and the stored filter's restore. While the page is offline it
// also sends itself the vehicle markers and the open stops' arrivals the
// saved schedules give, through the hooks' own `handle` callbacks. What the
// page cannot answer gets no reply, and the stylesheet says in place that
// it needs a connection.
//
// A trip's filter shown while offline is held by the page alone: the routes
// the map draws and a summary line of its own, which the stylesheet shows
// in place of the server's while the document's root element carries
// `data-local-trip`. When the page is live again it drops both, sends the
// server the stops closed while offline, and calls each hook's `whenLive`
// callbacks, which send the server what the hook has open.

import {assertCondition, unreachable} from "./assert"
import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state"
import {ConnectionKind} from "./connection_rules"
import {
  FILTER_RESTORE_REPLY,
  LocalAnswerKind,
  PageEventName,
  TripFilterKind,
  localAnswerOf,
  namesReply,
  positionReply,
  tripFilterOf,
  tripSummaryText,
  withClose,
  withoutClose
} from "./offline_answers"
import {KeptKind, elementRouteIds, endLocalRoutes, showLocalEveryRoute, showLocalRoutes} from "./route_stop_tiles"
import {savedSnapshots} from "./saved_snapshots"
import {refreshOfflineService, startOfflineService, stopOfflineService} from "./offline_service"

const SUMMARY_ID = "panel-sheet-summary"
const LOCAL_SUMMARY_CLASS_NAME = "panel-sheet-summary-line local-trip-summary"
const OFFLINE_PREFIX_CLASS_NAME = "offline-prefix"
const OFFLINE_PREFIX_TEXT = "Offline · "
const FILTER_ENDED_EVENT_NAME = "trip:filter-ended"
const LOCAL_TRIP_ATTRIBUTE_NAME = "data-local-trip"
const SERVER_SUMMARY_SELECTOR = `#${SUMMARY_ID} > p:not(.local-trip-summary)`

// Whether a trip's filter is shown, whether the server shows it, and what
// the rider's own filter showed before it.
const TripKind = Object.freeze({none: "none", shown: "shown"})

// What the page answers itself with: a reply, or none.
const ReplyKind = Object.freeze({reply: "reply", none: "none"})
const NO_REPLY = Object.freeze({kind: ReplyKind.none})

// The hooks that hold page events, in the order they took them, each with
// its `whenLive` callbacks and the callbacks it takes each event by.
const holders = new Map()
// The stops the page holds open for their arrivals, live or offline, which
// an offline page writes the scheduled arrivals of.
let openStops = []
let isWatching = false
let trip = {kind: TripKind.none}
// The stops closed while offline, which the server still holds open when
// its socket stayed joined.
let deferredCloses = []
// Each local trip's filter is numbered, so a filter whose names arrive
// after a later one was shown is dropped.
let localTripCount = 0

function isLive() {
  return connectionState().kind === ConnectionKind.live
}

// The text of the rider's own summary line, as the server rendered it.
function summaryText() {
  const line = document.querySelector(SERVER_SUMMARY_SELECTOR)

  if (line === null) {
    return ""
  }

  const copy = line.cloneNode(true)

  for (const prefix of copy.querySelectorAll(`.${OFFLINE_PREFIX_CLASS_NAME}`)) {
    prefix.remove()
  }

  return copy.textContent.split(/\s+/u).join(" ").trim()
}

// What the rider's own filter shows, read before a trip's filter replaces it.
function riderView() {
  return {kept: elementRouteIds(), summary: summaryText()}
}

function writeLocalSummary(text) {
  const summary = document.getElementById(SUMMARY_ID)

  if (summary === null) {
    return
  }

  let line = summary.querySelector(".local-trip-summary")

  if (line === null) {
    line = document.createElement("p")
    line.className = LOCAL_SUMMARY_CLASS_NAME
    summary.append(line)
  }

  const prefix = document.createElement("span")
  prefix.className = OFFLINE_PREFIX_CLASS_NAME
  prefix.textContent = OFFLINE_PREFIX_TEXT
  line.replaceChildren(prefix, document.createTextNode(text))
  document.documentElement.setAttribute(LOCAL_TRIP_ATTRIBUTE_NAME, "")
}

function endLocalSummary() {
  document.documentElement.removeAttribute(LOCAL_TRIP_ATTRIBUTE_NAME)

  for (const line of document.querySelectorAll(".local-trip-summary")) {
    line.remove()
  }
}

function endLocalTrip() {
  localTripCount += 1
  endLocalRoutes()
  endLocalSummary()
}

// Shows a trip's filter of `routeIds` for the page itself: its routes at
// once, and the summary line once the saved names are read.
async function showLocalTrip(routeIds) {
  localTripCount += 1
  const tripNumber = localTripCount
  showLocalRoutes(routeIds)
  const snapshots = await savedSnapshots()
  const isCurrent = tripNumber === localTripCount

  if (isCurrent) {
    writeLocalSummary(tripSummaryText({snapshots, routeIds}))
  }
}

// Ends a trip's filter the server showed, by showing what the rider's own
// filter showed before it.
function showRiderView(rider) {
  localTripCount += 1

  if (rider.kept.kind === KeptKind.every) {
    showLocalEveryRoute()
  } else {
    showLocalRoutes(rider.kept.routeIds)
  }

  writeLocalSummary(rider.summary)
}

function noteTripFilter({isServerShown}) {
  if (trip.kind === TripKind.none) {
    trip = {kind: TripKind.shown, rider: riderView(), isServerShown}
  } else if (isServerShown) {
    trip = {...trip, isServerShown}
  }
}

function countMaxOf({hook, name}) {
  const countMax = Number(hook.el.dataset[name])
  assertCondition(Number.isSafeInteger(countMax), `the hook's element carries ${name}: ${countMax}`)
  return countMax
}

function applyTripFilter({hook, payload}) {
  const countMax = countMaxOf({hook, name: "routeCountMax"})
  const accepted = tripFilterOf({payload, countMax})

  if (accepted.kind === TripFilterKind.refused) {
    return
  }

  noteTripFilter({isServerShown: false})
  return showLocalTrip(accepted.routeIds)
}

function clearTrip() {
  const shown = trip
  trip = {kind: TripKind.none}

  if (shown.kind === TripKind.none) {
    return
  }

  if (shown.isServerShown) {
    showRiderView(shown.rider)
  } else {
    endLocalTrip()
  }
}

function replied(reply) {
  return {kind: ReplyKind.reply, reply}
}

// What the page answers itself for `name`: a reply, or none.
async function answerLocally({hook, name, payload}) {
  const answer = localAnswerOf(name)

  switch (answer) {
    case LocalAnswerKind.position: {
      const snapshots = await savedSnapshots()
      return replied(positionReply({snapshots, payload}))
    }
    case LocalAnswerKind.names: {
      const snapshots = await savedSnapshots()
      const countMax = countMaxOf({hook, name: "nameCountMax"})
      return replied(namesReply({snapshots, payload, countMax}))
    }
    case LocalAnswerKind.tripFilter:
      await applyTripFilter({hook, payload})
      return NO_REPLY
    case LocalAnswerKind.tripClear:
      clearTrip()
      return NO_REPLY
    case LocalAnswerKind.filterRestore:
      return replied(FILTER_RESTORE_REPLY)
    case LocalAnswerKind.deferClose:
      deferredCloses = withClose({closes: deferredCloses, stopId: payload.stop_id})
      return NO_REPLY
    case LocalAnswerKind.cancelClose:
      deferredCloses = withoutClose({closes: deferredCloses, stopId: payload.stop_id})
      refreshOfflineService()
      return NO_REPLY
    case LocalAnswerKind.scheduledMarkers:
      refreshOfflineService()
      return NO_REPLY
    case LocalAnswerKind.unanswered:
      return NO_REPLY
    default:
      return unreachable(answer, "page events: a local answer of unknown kind")
  }
}

// The server's view of a trip's filter follows what reaches it, so the
// rider's own filter is read before the first trip's filter replaces it,
// and a trip's filter the server ends is no longer shown.
function noteLivePush(name) {
  if (name === PageEventName.tripFilter) {
    noteTripFilter({isServerShown: true})
  } else if (name === PageEventName.tripClear) {
    trip = {kind: TripKind.none}
  }
}

async function pushLocally({hook, name, payload, onReply}) {
  try {
    const answer = await answerLocally({hook, name, payload})
    const isReplied = answer.kind === ReplyKind.reply
    const isReplyTaken = isReplied && onReply !== undefined

    if (isReplyTaken) {
      onReply(answer.reply)
    }
  } catch (error) {
    console.warn("Page event not answered offline", {event: name, error})
  }
}

// LiveView rejects a push while its socket is down, which can come before
// the connection state hears of it.
async function pushLive({hook, name, payload, onReply}) {
  try {
    const reply = await hook.pushEvent(name, payload)

    if (onReply !== undefined) {
      onReply(reply)
    }
  } catch (error) {
    console.warn("Page event not sent", {event: name, error})
  }
}

// The page is live again: what it showed for itself gives way to the
// server's, the server is told the stops closed meanwhile, and each hook
// sends what it has open.
function wentLive() {
  endLocalTrip()
  trip = {kind: TripKind.none}
  const closes = deferredCloses
  deferredCloses = []
  const [first] = holders.keys()

  if (first !== undefined) {
    for (const stopId of closes) {
      pushLive({hook: first, name: PageEventName.arrivalsClose, payload: {stop_id: stopId}})
    }
  }

  for (const holder of Array.from(holders.values())) {
    for (const callback of holder.whenLive) {
      callback()
    }
  }
}

// Hands `payload` to every callback that takes `name`, as though the server
// had sent it.
function dispatchLocally(name, payload) {
  for (const holder of Array.from(holders.values())) {
    const callbacks = holder.handlers.get(name)

    if (callbacks !== undefined) {
      for (const callback of callbacks) {
        callback(payload)
      }
    }
  }
}

function openStopIds() {
  return Array.from(openStops)
}

function startScheduledService() {
  startOfflineService({dispatch: dispatchLocally, openStopIds})
}

// The stops held open follow every open and close the hooks push, whatever
// the connection.
function noteOpenStops({name, payload}) {
  if (name === PageEventName.arrivalsOpen) {
    openStops = withClose({closes: openStops, stopId: payload.stop_id})
  } else if (name === PageEventName.arrivalsClose) {
    openStops = withoutClose({closes: openStops, stopId: payload.stop_id})
  }
}

function connectionChanged(event) {
  const {previous, connection} = event.detail
  const wasLive = previous.kind === ConnectionKind.live
  const isNowLive = connection.kind === ConnectionKind.live
  const becameLive = !wasLive && isNowLive
  const wasOffline = previous.kind === ConnectionKind.offline
  const isNowOffline = connection.kind === ConnectionKind.offline
  const becameOffline = !wasOffline && isNowOffline

  if (becameLive) {
    stopOfflineService()
    wentLive()
  } else if (becameOffline) {
    startScheduledService()
  }
}

function watch() {
  if (isWatching) {
    return
  }

  window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, connectionChanged)
  isWatching = true

  if (connectionState().kind === ConnectionKind.offline) {
    startScheduledService()
  }
}

/**
 * The page events of `hook`: `push({name, payload, onReply})` sends an
 * event, the optional `onReply` taking the reply where one comes;
 * `handle(name, callback)` takes the events the server sends, and those
 * the page sends itself while offline; `whenLive(callback)` is called each
 * time the page is live again after it was not; and `release()`, from the
 * hook's `destroyed`, lets go of them.
 */
export function pageEvents(hook) {
  assertCondition(!holders.has(hook), "a hook takes its page events once")
  holders.set(hook, {whenLive: [], handlers: new Map()})
  watch()

  function takeLocally({name, callback}) {
    const {handlers} = holders.get(hook)

    if (!handlers.has(name)) {
      handlers.set(name, [])
    }

    handlers.get(name).push(callback)
  }

  function push({name, payload, onReply}) {
    noteOpenStops({name, payload})

    if (isLive()) {
      noteLivePush(name)
      pushLive({hook, name, payload, onReply})
    } else {
      pushLocally({hook, name, payload, onReply})
    }
  }

  function handle(name, callback) {
    if (name === FILTER_ENDED_EVENT_NAME) {
      hook.handleEvent(name, (payload) => {
        trip = {kind: TripKind.none}
        callback(payload)
      })
    } else {
      hook.handleEvent(name, callback)
      takeLocally({name, callback})
    }
  }

  function whenLive(callback) {
    holders.get(hook).whenLive.push(callback)
  }

  function release() {
    holders.delete(hook)
  }

  return {push, handle, whenLive, release}
}
