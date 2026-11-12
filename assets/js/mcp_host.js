// The trip planner app's side of its conversation with the host that renders
// it, MCP Apps' JSON-RPC 2.0 over `postMessage`, written by hand: the
// `ui/initialize` handshake, the host's notifications, and the app's
// requests to update the model's context and to send a message. The
// protocol is small enough that no SDK is needed.
//
// https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx — checked 2026-11-11
//
// The module holds no DOM and no global: the window to post to and the
// source of `message` events are handed in, so a check can stand a fake host
// on the other end. A message counts only when it comes from the window the
// app posts to, and a request waits `HOST_REQUEST_TIMEOUT_MS` for its answer.

import {assertCondition} from "./assert.js"

/** The revision of the MCP Apps specification this module speaks. */
export const MCP_APPS_PROTOCOL_VERSION = "2026-01-26"

/** How long a request waits for the host's answer. */
export const HOST_REQUEST_TIMEOUT_MS = 10 * 1000

/** The requests the app sends, and the notifications and requests it handles. */
export const HostMethod = Object.freeze({
  initialize: "ui/initialize",
  initialized: "ui/notifications/initialized",
  message: "ui/message",
  updateModelContext: "ui/update-model-context",
  sizeChanged: "ui/notifications/size-changed",
  toolInput: "ui/notifications/tool-input",
  toolResult: "ui/notifications/tool-result",
  hostContextChanged: "ui/notifications/host-context-changed",
  resourceTeardown: "ui/resource-teardown",
  toolsCall: "tools/call",
  ping: "ping",
})

/** The kinds of what an incoming message is. */
export const IncomingKind = Object.freeze({request: "request", notification: "notification", response: "response", ignored: "ignored"})

/** The kinds of how a request to the host ended. */
export const OutcomeKind = Object.freeze({answered: "answered", refused: "refused", timedOut: "timedOut"})

/** The kinds of what a host context says of the theme. */
export const ThemeKind = Object.freeze({named: "named", none: "none"})

// The code of a request whose method the app does not handle.
// https://www.jsonrpc.org/specification#error_object — checked 2026-11-11
const METHOD_NOT_FOUND_CODE = -32601

function isRecord(value) {
  const isObject = typeof value === "object" && value !== null
  return isObject && !Array.isArray(value)
}

/** A request message with `id`, `method`, and `params`. */
export function requestMessage({id, method, params}) {
  return {jsonrpc: "2.0", id, method, params}
}

/** A notification message, which carries no id and gets no answer. */
export function notificationMessage({method, params}) {
  return {jsonrpc: "2.0", method, params}
}

/** The result message answering the request `id`. */
export function resultMessage({id, result}) {
  return {jsonrpc: "2.0", id, result}
}

/** The error message answering the request `id`. */
export function errorMessage({id, code, message}) {
  return {jsonrpc: "2.0", id, error: {code, message}}
}

/**
 * What `data`, the data of a `message` event, is: an IncomingKind member with
 * the fields the kind reads. A request has an `id` and a `method`, a
 * notification a `method`, a response an `id` and a `result` or an `error`,
 * and anything else, such as a message of another protocol, is ignored.
 */
export function incomingOf(data) {
  if (!isRecord(data)) {
    return {kind: IncomingKind.ignored}
  }

  if (data.jsonrpc !== "2.0") {
    return {kind: IncomingKind.ignored}
  }

  const hasId = typeof data.id === "number" || typeof data.id === "string"

  if (typeof data.method === "string") {
    if (hasId) {
      return {kind: IncomingKind.request, id: data.id, method: data.method, params: data.params}
    }

    return {kind: IncomingKind.notification, method: data.method, params: data.params}
  }

  if (!hasId) {
    return {kind: IncomingKind.ignored}
  }

  if (isRecord(data.error)) {
    return {kind: IncomingKind.response, id: data.id, error: data.error}
  }

  if (isRecord(data.result)) {
    return {kind: IncomingKind.response, id: data.id, result: data.result}
  }

  return {kind: IncomingKind.ignored}
}

/**
 * The channel to the host: `target` is the window to post to, which has
 * `postMessage`, and `events` the object `message` events arrive on, which
 * has `addEventListener`. `appInfo` names the app, `{name, version}`.
 * `timers` has `setTimeout` and `clearTimeout`, handed in so a check
 * controls time.
 *
 * A handler for a notification is registered before the connection is made,
 * since the host sends the first one as soon as the app says it is
 * initialized. The connection resolves on
 * `{kind: OutcomeKind.answered, result}`, the host's initialize result, with
 * its `hostContext` and `hostCapabilities`, or the failure.
 */
export function createHost({target, events, appInfo, timers}) {
  const pending = new Map()
  const handlers = new Map()
  const teardown = {handler: null}
  let nextId = 1

  function post(message) {
    // The sandbox proxy and the host are of other origins, so the target
    // origin is a wildcard; the message holds no credential, and a reply
    // counts only from the window posted to.
    target.postMessage(message, "*")
  }

  function settle({id, outcome}) {
    const waiting = pending.get(id)

    if (waiting === undefined) {
      return
    }

    pending.delete(id)
    timers.clearTimeout(waiting.timer)
    waiting.resolve(outcome)
  }

  function answerRequest({id, method}) {
    const isAnswerable = method === HostMethod.ping || method === HostMethod.resourceTeardown

    if (method === HostMethod.resourceTeardown && teardown.handler !== null) {
      teardown.handler()
    }

    if (isAnswerable) {
      post(resultMessage({id, result: {}}))
      return
    }

    post(errorMessage({id, code: METHOD_NOT_FOUND_CODE, message: "Method not found: " + method}))
  }

  function onMessage(event) {
    if (event.source !== target) {
      return
    }

    const incoming = incomingOf(event.data)

    switch (incoming.kind) {
      case IncomingKind.response:
        settle({id: incoming.id, outcome: responseOutcome(incoming)})
        return
      case IncomingKind.request:
        answerRequest(incoming)
        return
      case IncomingKind.notification: {
        const handler = handlers.get(incoming.method)

        if (handler !== undefined) {
          handler(incoming.params)
        }

        return
      }
      case IncomingKind.ignored:
        return
      default:
        assertCondition(false, "mcp host: an incoming message of unknown kind: " + incoming.kind)
    }
  }

  function request({method, params}) {
    const id = nextId
    nextId += 1

    return new Promise((resolve) => {
      const timer = timers.setTimeout(() => {
        settle({id, outcome: {kind: OutcomeKind.timedOut}})
      }, HOST_REQUEST_TIMEOUT_MS)

      pending.set(id, {resolve, timer})
      post(requestMessage({id, method, params}))
    })
  }

  events.addEventListener("message", onMessage)

  return Object.freeze({
    onNotification(method, handler) {
      handlers.set(method, handler)
    },

    // Runs `handler` when the host asks the app to tear down, before the answer goes out.
    onTeardown(handler) {
      teardown.handler = handler
    },

    async connect() {
      const params = {appInfo, appCapabilities: {availableDisplayModes: ["inline"]}, protocolVersion: MCP_APPS_PROTOCOL_VERSION}
      const outcome = await request({method: HostMethod.initialize, params})

      if (outcome.kind === OutcomeKind.answered) {
        post(notificationMessage({method: HostMethod.initialized, params: {}}))
      }

      return outcome
    },

    request,

    notify({method, params}) {
      post(notificationMessage({method, params}))
    },
  })
}

/**
 * Whether the host grants the app the geolocation permission, from the
 * `hostCapabilities` of its initialize result. A host that omits the field
 * grants none, so the app offers no start from the rider's position.
 */
export function isLocationGranted(hostCapabilities) {
  if (!isRecord(hostCapabilities)) {
    return false
  }

  if (!isRecord(hostCapabilities.sandbox)) {
    return false
  }

  if (!isRecord(hostCapabilities.sandbox.permissions)) {
    return false
  }

  return isRecord(hostCapabilities.sandbox.permissions.geolocation)
}

/**
 * Whether the host takes the model's context, from the `hostCapabilities` of
 * its initialize result: it declares `updateModelContext`. A host that omits
 * the field takes none, so the app offers it no journeys unasked.
 */
export function isContextAccepted(hostCapabilities) {
  if (!isRecord(hostCapabilities)) {
    return false
  }

  return isRecord(hostCapabilities.updateModelContext)
}

/**
 * Whether the host proxies the app's tool calls to the server, from the
 * `hostCapabilities` of its initialize result: it declares `serverTools`. A
 * host that omits the field takes no `tools/call`, so the app sends none.
 */
export function isServerToolsDeclared(hostCapabilities) {
  if (!isRecord(hostCapabilities)) {
    return false
  }

  return isRecord(hostCapabilities.serverTools)
}

/** The theme, `light` or `dark`, of `hostContext`, a context or the part of one the host changed, or none. */
export function themeOf(hostContext) {
  if (!isRecord(hostContext)) {
    return {kind: ThemeKind.none}
  }

  const isNamed = hostContext.theme === "light" || hostContext.theme === "dark"

  if (isNamed) {
    return {kind: ThemeKind.named, theme: hostContext.theme}
  }

  return {kind: ThemeKind.none}
}

function responseOutcome(incoming) {
  if (incoming.error !== undefined) {
    return {kind: OutcomeKind.refused, message: String(incoming.error.message)}
  }

  return {kind: OutcomeKind.answered, result: incoming.result}
}

// A result with `isError` true is the host saying it did not take the
// request: the SDK's types give the field on the message result, and the app
// reads it on both requests.
function takenOutcome(outcome) {
  const isErrorResult = outcome.kind === OutcomeKind.answered && outcome.result.isError === true

  if (isErrorResult) {
    return {kind: OutcomeKind.refused, message: "The host answered with isError"}
  }

  return outcome
}

/**
 * Sends `structuredContent`, an object, as the model's context, with the
 * same object as the text of a content block for a host that reads only
 * content; the host keeps it in place of the context the app sent before.
 * Resolves on an OutcomeKind member.
 */
export async function updateModelContext({host, structuredContent}) {
  const text = JSON.stringify(structuredContent)
  const outcome = await host.request({method: HostMethod.updateModelContext, params: {content: [{type: "text", text}], structuredContent}})
  return takenOutcome(outcome)
}

/**
 * Calls the tool `name` of the server through the host, with `toolArguments`
 * as the tool's arguments, as the standard MCP `tools/call` request the
 * specification lets an app send. Resolves on an OutcomeKind member; an
 * answered outcome's result is the tool's result as the server sent it, a
 * tool's own error with `isError` true included, since that is the tool's
 * answer and not the host's refusal.
 */
export function callTool({host, name, toolArguments}) {
  return host.request({method: HostMethod.toolsCall, params: {name, arguments: toolArguments}})
}

/** Sends `text` to the conversation as the rider's message, in the list of content blocks the SDK types give, and resolves on an OutcomeKind member. */
export async function sendMessage({host, text}) {
  const outcome = await host.request({method: HostMethod.message, params: {role: "user", content: [{type: "text", text}]}})
  return takenOutcome(outcome)
}
