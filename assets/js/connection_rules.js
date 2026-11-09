// The rules of the page's connection state. Everything here is pure: the
// state, the event, the time, and when the page was rendered are given as
// values, so the next state is a function of them alone.
//
// A page is connecting until its LiveView joins, live while it is joined,
// and offline with a reason: the browser says it has no network, or the
// server has not answered. It is offline at once in an offline browser and
// for a copy from a cache, and otherwise once it has waited JOIN_WAIT_MS
// with no join; a join makes it live from any state, and so does the
// browser's network coming back to a socket that stayed joined.

import {assertCondition, unreachable} from "./assert.js"

/** A page that waits this long with no join is offline. */
export const JOIN_WAIT_MS = 10 * 1000

/** A page rendered longer ago than this when its script starts is a copy from a cache. */
export const CACHED_COPY_AGE_MS_MAX = 2 * 60 * 1000

/** The states of the page's connection. */
export const ConnectionKind = Object.freeze({connecting: "connecting", live: "live", offline: "offline"})

/** Why an offline page is offline. */
export const OfflineReason = Object.freeze({browserOffline: "browserOffline", serverUnreachable: "serverUnreachable"})

/** What reaches the state: a join, a lost socket, the browser's network events, and the end of the join wait. */
export const ConnectionEventKind = Object.freeze({
  joined: "joined",
  disconnected: "disconnected",
  browserOnline: "browserOnline",
  browserOffline: "browserOffline",
  joinWaitEnded: "joinWaitEnded"
})

/** Whether the page carries the time it was rendered. */
export const RenderStampKind = Object.freeze({stamped: "stamped", unstamped: "unstamped"})

const connectionKinds = Object.values(ConnectionKind)
const CONNECTING = Object.freeze({kind: ConnectionKind.connecting})
const LIVE = Object.freeze({kind: ConnectionKind.live})

function offlineFor(reason) {
  return Object.freeze({kind: ConnectionKind.offline, reason})
}

/** The render stamp of the rendered-at meta element's `content`, an ISO 8601 time. */
export function renderStampOf(content) {
  assertCondition(typeof content === "string", `a render stamp's content is a text: ${content}`)
  const renderedAtMs = Date.parse(content)

  if (Number.isFinite(renderedAtMs)) {
    return {kind: RenderStampKind.stamped, renderedAtMs}
  }

  return {kind: RenderStampKind.unstamped}
}

/** Whether a page of `renderStamp` is, at `nowMs`, a copy from a cache. A page with no stamp never is. */
export function isCachedCopy({renderStamp, nowMs}) {
  assertCondition(Number.isFinite(nowMs), `the time is a number: ${nowMs}`)

  switch (renderStamp.kind) {
    case RenderStampKind.stamped:
      return nowMs - renderStamp.renderedAtMs > CACHED_COPY_AGE_MS_MAX
    case RenderStampKind.unstamped:
      return false
    default:
      return unreachable(renderStamp.kind, "render stamp kind")
  }
}

/** The state a page starts in, before any event. */
export function initialConnection({isBrowserOnline, renderStamp, nowMs}) {
  assertCondition(typeof isBrowserOnline === "boolean", `the browser's network is a boolean: ${isBrowserOnline}`)

  if (!isBrowserOnline) {
    return offlineFor(OfflineReason.browserOffline)
  }

  const isCached = isCachedCopy({renderStamp, nowMs})

  if (isCached) {
    return offlineFor(OfflineReason.serverUnreachable)
  }

  return CONNECTING
}

// The browser has a network again. A socket that stayed joined through the
// outage makes the page live at once, since no join is coming; otherwise
// the page stays offline until the server answers.
function browserOnlineConnection({connection, isOffline, isJoined}) {
  assertCondition(typeof isJoined === "boolean", `whether the socket is joined is a boolean: ${isJoined}`)

  if (!isOffline) {
    return connection
  }

  if (isJoined) {
    return LIVE
  }

  return offlineFor(OfflineReason.serverUnreachable)
}

/**
 * The state after `event` reaches a page in `connection`. A `browserOnline`
 * event carries `isJoined`, whether the LiveView socket is joined.
 */
export function nextConnection({connection, event}) {
  assertCondition(connectionKinds.includes(connection.kind), `a connection state: ${connection.kind}`)
  const isOffline = connection.kind === ConnectionKind.offline

  switch (event.kind) {
    case ConnectionEventKind.joined:
      return LIVE
    case ConnectionEventKind.disconnected:
      if (connection.kind === ConnectionKind.live) {
        return CONNECTING
      }

      return connection
    case ConnectionEventKind.browserOffline:
      return offlineFor(OfflineReason.browserOffline)
    case ConnectionEventKind.browserOnline:
      return browserOnlineConnection({connection, isOffline, isJoined: event.isJoined})
    case ConnectionEventKind.joinWaitEnded:
      if (connection.kind === ConnectionKind.connecting) {
        return offlineFor(OfflineReason.serverUnreachable)
      }

      return connection
    default:
      return unreachable(event.kind, "connection event kind")
  }
}

/** Whether a page in `connection` waits for its join, with the join wait running. */
export function waitsForJoin(connection) {
  assertCondition(connectionKinds.includes(connection.kind), `a connection state: ${connection.kind}`)
  return connection.kind === ConnectionKind.connecting
}

/** Whether two states are one: the same kind, and for offline the same reason. */
export function isSameConnection(left, right) {
  const isSameKind = left.kind === right.kind
  const isSameReason = left.reason === right.reason
  return isSameKind && isSameReason
}
