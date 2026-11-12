// The arrivals board, which an AI host renders from a `ui://` resource when
// the model calls `arrivals_board`. It shows one stop's name and arrivals
// from the tool's result, and where the host proxies tool calls to the
// server it asks the `arrivals` tool again through the host on its own, with
// no message to the model, until its lifetime passes, the host tears the
// frame down, or the stop is not known. Where the host proxies none, it
// shows the arrivals it was opened with and when they were fetched, and
// sends nothing.
//
// A call with a `when` makes the board a list of scheduled departures from
// that time instead: it asks for no arrivals, lists the departures on the
// device from the routing files, and hands them to the model's context. The
// live board's requests all go through the host; the list's go to the origin
// the document names in `data-file-origin`, and name only a file. Every text
// is a text node: names come from outside the application and are never
// parsed as HTML.

import {startArrivalTicker} from "./arrival_ticker.js"
import {assertCondition, unreachable} from "./core/assert.js"
import {element} from "./dom_element.js"
import {NO_YOUR_BUS} from "./journey_stop_marks.js"
import {showDepartures} from "./board_departures.js"
import {answerOfOutcome, answerOf, boardAfter, fetchedText, shownOf, statusText} from "./mcp_board_answer.js"
import {BoardInputKind, boardInput} from "./mcp_board_input.js"
import {StepKind, expiredText, stepOf} from "./mcp_board_refresh.js"
import {applyTheme, reportSize} from "./mcp_frame.js"
import {HostMethod, OutcomeKind, callTool, createHost, isContextAccepted, isServerToolsDeclared} from "./mcp_host.js"
import {writeArrivals} from "./stop_arrivals.js"

const APP_INFO = Object.freeze({name: "gobusgo-arrivals-board", version: "1"})
const ARRIVALS_TOOL_NAME = "arrivals"
const ARRIVALS_SHOWN_MAX = 100
const HEADING_DEFAULT = "Arrivals board"
const STANDALONE_TEXT = "This board opens inside an AI assistant that supports MCP Apps."
const PROTOCOL_PREFIX = /^https?:\/\//
const EMPTY_BOARD = Object.freeze({stopName: null, arrivals: null, latest: null})

// The skeleton the board fills in place, so its status line is one live region that changes only when its text does.
function boardView(root) {
  const heading = element({tag: "h1", className: "mcp-trip-heading", text: HEADING_DEFAULT})
  const arrivals = element({tag: "div", className: "arrivals-board-rows"})
  const status = element({tag: "p", className: "arrival-note"})
  status.setAttribute("role", "status")
  const fetched = element({tag: "p", className: "trip-window"})
  root.replaceChildren(heading, arrivals, status, fetched)

  function setText(target, text) {
    if (target.textContent !== text) {
      target.replaceChildren(text)
    }
  }

  return Object.freeze({
    write({board, nowMs, isRefreshing, isExpired}) {
      let headingText = HEADING_DEFAULT

      if (board.stopName !== null) {
        headingText = board.stopName
      }

      setText(heading, headingText)

      if (board.arrivals === null) {
        arrivals.replaceChildren()
      } else {
        const shown = shownOf({answer: board.arrivals, nowMs, countMax: ARRIVALS_SHOWN_MAX})
        writeArrivals({element: arrivals, shown, withKey: true, yourBus: NO_YOUR_BUS})
      }

      let statusLine = ""

      if (board.latest !== null) {
        statusLine = statusText({answer: board.latest, isRefreshing})
      }

      if (isExpired) {
        statusLine = expiredText()
      }

      setText(status, statusLine)

      const hasFetchTime = board.arrivals !== null && isRefreshing === false
      let fetchedLine = ""

      if (hasFetchTime) {
        const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
        fetchedLine = fetchedText({fetchedAtMs: board.arrivals.fetchedAtMs, timeZone})
      }

      setText(fetched, fetchedLine)
    }
  })
}

function showStandalone(root) {
  root.replaceChildren(element({tag: "h1", className: "mcp-trip-heading", text: HEADING_DEFAULT}), element({tag: "p", className: "arrival-note", text: STANDALONE_TEXT}))
}

// Holds the board's state and the one loop that refreshes it; the decisions are `stepOf`'s.
function startBoard({root, host, origin}) {
  const view = boardView(root)
  const state = {
    board: EMPTY_BOARD,
    stopId: null,
    answeredAtMs: 0,
    openedAtMs: Date.now(),
    isRefreshing: false,
    isOpen: true,
    isExpired: false,
    isBusy: false,
    scheduled: null,
    connection: null,
    isScheduledStarted: false,
    timer: null,
    stopTicker: null
  }

  function write(nowMs) {
    view.write({board: state.board, nowMs, isRefreshing: state.isRefreshing, isExpired: state.isExpired})
  }

  function stopTimer() {
    window.clearTimeout(state.timer)
    state.timer = null
  }

  function stopBoard() {
    state.isOpen = false
    stopTimer()

    if (state.stopTicker !== null) {
      state.stopTicker()
      state.stopTicker = null
    }
  }

  function accept(answer) {
    const hasStop = typeof answer.stopId === "string"

    if (hasStop) {
      state.stopId = answer.stopId
    }

    state.board = boardAfter({board: state.board, answer})
    state.answeredAtMs = Date.now()
    write(state.answeredAtMs)
  }

  async function refresh() {
    if (state.stopId === null) {
      return
    }

    state.isBusy = true
    const outcome = await callTool({host, name: ARRIVALS_TOOL_NAME, toolArguments: {stopId: state.stopId}})
    state.isBusy = false

    if (state.isOpen === false) {
      return
    }

    accept(answerOfOutcome(outcome))
    next()
  }

  // The one place the loop decides: a timer or a visibility change comes back here.
  function next() {
    stopTimer()
    const isRunning = state.isOpen && state.isRefreshing
    const isIdle = state.isBusy === false && state.board.latest !== null
    const canStep = isRunning && isIdle

    if (canStep === false) {
      return
    }

    const step = stepOf({answer: state.board.latest, answeredAtMs: state.answeredAtMs, openedAtMs: state.openedAtMs, nowMs: Date.now(), isVisible: document.visibilityState !== "hidden"})

    switch (step.kind) {
      case StepKind.expired:
        state.isExpired = true
        write(Date.now())
        stopBoard()
        return
      case StepKind.settled:
      case StepKind.pause:
        return
      case StepKind.wait:
        state.timer = window.setTimeout(next, step.delayMs)
        return
      case StepKind.refresh:
        refresh()
        return
      default:
        unreachable(step.kind, "arrivals board: a step of unknown kind")
    }
  }

  document.addEventListener("visibilitychange", next)
  host.onTeardown(stopBoard)

  async function listDepartures({input, isContextAccepted}) {
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone

    try {
      await showDepartures({root, host, origin, input, isContextAccepted, timeZone})
    } catch (error) {
      console.warn("Departures not shown", error)
    }
  }

  // Turns the board into the list of departures once the call and the host's capabilities are both known, and then only once.
  function startScheduledWhenReady() {
    const isReady = state.scheduled !== null && state.connection !== null
    const isDue = isReady && state.isScheduledStarted === false

    if (isDue === false) {
      return
    }

    state.isScheduledStarted = true
    stopBoard()
    listDepartures({input: state.scheduled, isContextAccepted: state.connection.isContextAccepted})
  }

  return Object.freeze({
    // Takes what the tool was called for: the stop of a live board, or the time and routes of a list of departures.
    takeInput(params) {
      const input = boardInput(params)

      switch (input.kind) {
        case BoardInputKind.live:
          state.stopId = input.stopId
          return
        case BoardInputKind.missing:
          return
        case BoardInputKind.scheduled:
        case BoardInputKind.refused:
          state.scheduled = input
          startScheduledWhenReady()
          return
        default:
          unreachable(input.kind, "arrivals board: an input of unknown kind")
      }
    },

    // Takes the tool's result, the first answer, and starts the loop once the host's capabilities are known.
    takeResult(result) {
      if (state.isOpen === false) {
        return
      }

      accept(answerOf(result))
      next()
    },

    // Says whether the host proxies tool calls and whether it takes the model's context, which ends the wait for the capabilities.
    connect({isRefreshing, isContextAccepted}) {
      state.isRefreshing = isRefreshing
      state.connection = {isContextAccepted}
      state.stopTicker = startArrivalTicker(write)
      next()
      startScheduledWhenReady()
    }
  })
}

async function main() {
  const root = document.getElementById("mcp-arrivals-board")
  assertCondition(root !== null, "arrivals board: the document has no element for the app")
  const origin = document.body.dataset.fileOrigin
  assertCondition(PROTOCOL_PREFIX.test(origin), "arrivals board: the file origin is not an http address: " + origin)
  const timers = {setTimeout: window.setTimeout.bind(window), clearTimeout: window.clearTimeout.bind(window)}
  const host = createHost({target: window.parent, events: window, appInfo: APP_INFO, timers})
  const board = startBoard({root, host, origin})

  host.onNotification(HostMethod.toolInput, (params) => { board.takeInput(params) })
  host.onNotification(HostMethod.toolResult, (params) => { board.takeResult(params) })
  host.onNotification(HostMethod.hostContextChanged, applyTheme)

  const connected = await host.connect()

  if (connected.kind !== OutcomeKind.answered) {
    showStandalone(root)
    return
  }

  applyTheme(connected.result.hostContext)
  console.debug("Host capabilities read", {hostCapabilities: connected.result.hostCapabilities})
  board.connect({isRefreshing: isServerToolsDeclared(connected.result.hostCapabilities), isContextAccepted: isContextAccepted(connected.result.hostCapabilities)})
  reportSize({host, body: document.body})
}

main()
