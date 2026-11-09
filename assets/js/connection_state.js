// The one owner of the page's connection state: connecting, live, or
// offline with a reason. It hears the
// ConnectionState hook, the browser's network events, and the time the
// page was rendered, which the root layout writes into the rendered-at
// meta element.
//
// The state is read synchronously with `connectionState()`, and each change
// is announced with the `gobusgo:connection-change` DOM event on the window,
// whose detail holds the state before and after. The document's root
// element carries the state's kind as `data-connection`, which the
// stylesheet reads to hide what needs a connection and to show the offline
// signal.

import {assertCondition} from "./assert.js"
import {
  ConnectionEventKind,
  JOIN_WAIT_MS,
  initialConnection,
  isSameConnection,
  nextConnection,
  renderStampOf,
  waitsForJoin
} from "./connection_rules.js"

/** The DOM event on the window that announces a change of the connection state. */
export const CONNECTION_CHANGE_EVENT_NAME = "gobusgo:connection-change"

const RENDERED_AT_SELECTOR = "meta[name='gobusgo:rendered-at']"

// The state, once `watchConnection` has read it, and the join wait's timer
// while it runs.
let connection = null
let joinWaitTimer = null
// Whether the LiveView socket is joined, by the hook's latest callback. A
// browser that loses its network can leave the socket joined.
let isJoined = false

function renderStamp() {
  const meta = document.querySelector(RENDERED_AT_SELECTOR)

  if (meta === null) {
    return renderStampOf("")
  }

  return renderStampOf(meta.content)
}

function writeRootAttribute() {
  document.documentElement.dataset.connection = connection.kind
}

// Runs the join wait while the state waits for a join, and stops it once
// the state does not. Entering connecting again starts a new wait.
function followJoinWait() {
  const waits = waitsForJoin(connection)
  const isRunning = joinWaitTimer !== null
  const startsWait = waits && !isRunning
  const stopsWait = !waits && isRunning

  if (startsWait) {
    joinWaitTimer = window.setTimeout(joinWaitEndedCallback, JOIN_WAIT_MS)
  } else if (stopsWait) {
    window.clearTimeout(joinWaitTimer)
    joinWaitTimer = null
  }
}

function joinWaitEndedCallback() {
  joinWaitTimer = null
  report({kind: ConnectionEventKind.joinWaitEnded})
}

function report(event) {
  assertCondition(connection !== null, `a connection event before the state is watched: ${event.kind}`)
  const previous = connection
  connection = nextConnection({connection: previous, event})
  followJoinWait()
  writeRootAttribute()

  if (isSameConnection(previous, connection)) {
    return
  }

  const detail = {previous, connection}
  window.dispatchEvent(new CustomEvent(CONNECTION_CHANGE_EVENT_NAME, {detail}))
}

function browserOnlineCallback() {
  report({kind: ConnectionEventKind.browserOnline, isJoined})
}

function browserOfflineCallback() {
  report({kind: ConnectionEventKind.browserOffline})
}

/** Reads the state the page starts in and starts hearing its inputs. Called once, before the LiveView socket connects. */
export function watchConnection() {
  assertCondition(connection === null, "the connection state is watched once")
  connection = initialConnection({isBrowserOnline: navigator.onLine, renderStamp: renderStamp(), nowMs: Date.now()})
  writeRootAttribute()
  followJoinWait()
  window.addEventListener("online", browserOnlineCallback)
  window.addEventListener("offline", browserOfflineCallback)
}

/** The page's connection state now: `{kind}`, with a `reason` while offline. */
export function connectionState() {
  assertCondition(connection !== null, "the connection state is read before it is watched")
  return connection
}

/**
 * The hook whose callbacks are the authority on the LiveView join: its
 * `mounted` and `reconnected` report a join and its `disconnected` a lost
 * socket. Its `mounted` reports a join, so LiveView alone mounts it.
 */
export const ConnectionState = {
  mounted() {
    isJoined = true
    report({kind: ConnectionEventKind.joined})
  },

  reconnected() {
    isJoined = true
    report({kind: ConnectionEventKind.joined})
  },

  disconnected() {
    isJoined = false
    report({kind: ConnectionEventKind.disconnected})
  }
}
