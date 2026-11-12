// Checks the trip planner app's conversation with its host, over a fake host
// on the other end of `postMessage`: the `ui/initialize` handshake and the
// `initialized` notification that follows the host's answer, the host's
// notifications reaching their handlers, the requests that update the
// model's context and send a message, each request's answer, refusal, and
// timeout, the requests the host makes of the app, and a message from another
// window or of another protocol left alone. Time is a fake, so no case waits.
// Run it with `node test/scripts/mcp_host_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {
  HOST_REQUEST_TIMEOUT_MS,
  HostMethod,
  IncomingKind,
  MCP_APPS_PROTOCOL_VERSION,
  OutcomeKind,
  ThemeKind,
  createHost,
  incomingOf,
  isContextAccepted,
  isLocationGranted,
  isServerToolsDeclared,
  callTool,
  sendMessage,
  themeOf,
  updateModelContext,
} from "../../assets/js/mcp_host.js"

const MESSAGES_AFTER_ANSWER = 2
const UNKNOWN_ID = 999

function delayOf(entry) {
  return entry.delayMs
}

function messageOf(entry) {
  return entry.message
}

// A window the app posts to, which records what it is sent.
function fakeParent() {
  const posted = []
  return {posted, postMessage(message, targetOrigin) { posted.push({message, targetOrigin}) }}
}

// The events a window receives: a host delivers a message as an event whose
// `source` is the window it came from.
function fakeEvents() {
  const listeners = []
  return {
    addEventListener(name, listener) {
      deepStrictEqual(name, "message", "the app listens for message events only")
      listeners.push(listener)
    },
    deliver({source, data}) {
      for (const listener of listeners) {
        listener({source, data})
      }
    },
  }
}

function fakeTimers() {
  const scheduled = new Map()
  let nextHandle = 1
  return {
    scheduled,
    setTimeout(callback, delayMs) {
      const handle = nextHandle
      nextHandle += 1
      scheduled.set(handle, {callback, delayMs})
      return handle
    },
    clearTimeout(handle) {
      scheduled.delete(handle)
    },
    fireAll() {
      for (const [handle, {callback}] of Array.from(scheduled)) {
        scheduled.delete(handle)
        callback()
      }
    },
  }
}

function setup() {
  const parent = fakeParent()
  const events = fakeEvents()
  const timers = fakeTimers()
  const host = createHost({target: parent, events, appInfo: {name: "check", version: "1"}, timers})
  const answer = (id, result) => events.deliver({source: parent, data: {jsonrpc: "2.0", id, result}})
  const send = (data) => events.deliver({source: parent, data})
  return {parent, events, timers, host, answer, send}
}

// The handshake: the app asks ui/initialize first, and says initialized only
// once the host has answered, since the host sends nothing before that.
{
  const {parent, host, answer} = setup()
  const connecting = host.connect()
  deepStrictEqual(parent.posted.length, 1, "one message before the host answers")
  const [{message: initialize, targetOrigin}] = parent.posted
  deepStrictEqual(targetOrigin, "*", "the target origin")
  deepStrictEqual(initialize.method, HostMethod.initialize, "the first message initializes")
  deepStrictEqual(initialize.params.protocolVersion, MCP_APPS_PROTOCOL_VERSION, "the protocol version")
  deepStrictEqual(initialize.params.appInfo, {name: "check", version: "1"}, "the app's name")
  deepStrictEqual(initialize.params.appCapabilities, {availableDisplayModes: ["inline"]}, "the app's capabilities")

  const result = {protocolVersion: MCP_APPS_PROTOCOL_VERSION, hostInfo: {name: "host", version: "9"}, hostCapabilities: {}, hostContext: {theme: "dark"}}
  answer(initialize.id, result)
  const outcome = await connecting
  deepStrictEqual(outcome, {kind: OutcomeKind.answered, result}, "the host's initialize result")
  deepStrictEqual(parent.posted.length, MESSAGES_AFTER_ANSWER, "initialized follows the answer")
  deepStrictEqual(parent.posted[1].message, {jsonrpc: "2.0", method: HostMethod.initialized, params: {}}, "the initialized notification")
}

// A host that refuses to initialize gets no initialized notification.
{
  const {parent, host, send} = setup()
  const connecting = host.connect()
  send({jsonrpc: "2.0", id: parent.posted[0].message.id, error: {code: -32000, message: "no"}})
  const refusedOutcome = await connecting
  deepStrictEqual(refusedOutcome, {kind: OutcomeKind.refused, message: "no"}, "a refused initialize")
  deepStrictEqual(parent.posted.length, 1, "no initialized after a refusal")
}

// A host that never answers times out, after the bound, with its timer cleared.
{
  const {timers, host} = setup()
  const connecting = host.connect()
  const entries = Array.from(timers.scheduled.values())
  const delays = Array.from(entries, delayOf)
  deepStrictEqual(delays, [HOST_REQUEST_TIMEOUT_MS], "the request's timeout")
  timers.fireAll()
  const timedOut = await connecting
  deepStrictEqual(timedOut, {kind: OutcomeKind.timedOut}, "a timed-out initialize")
}

// The host's notifications reach the handler registered for their method, with their params.
{
  const {host, send} = setup()
  const seen = []
  host.onNotification(HostMethod.toolInput, (params) => seen.push(["input", params]))
  host.onNotification(HostMethod.toolResult, (params) => seen.push(["result", params]))
  send({jsonrpc: "2.0", method: HostMethod.toolInput, params: {arguments: {from: "A", to: "B"}}})
  send({jsonrpc: "2.0", method: HostMethod.toolResult, params: {content: [], structuredContent: {from: "A", to: "B"}}})
  send({jsonrpc: "2.0", method: "ui/notifications/unknown", params: {}})
  deepStrictEqual(seen, [["input", {arguments: {from: "A", to: "B"}}], ["result", {content: [], structuredContent: {from: "A", to: "B"}}]], "the notifications' handlers")
}

// The host's teardown request reaches its handler, and is answered once the handler has run.
{
  const {parent, host, send} = setup()
  const seen = []
  host.onTeardown(() => { seen.push(parent.posted.length) })
  send({jsonrpc: "2.0", id: 8, method: HostMethod.resourceTeardown, params: {reason: "done"}})
  deepStrictEqual(seen, [0], "the handler runs before the answer is posted")
  deepStrictEqual(parent.posted[0].message, {jsonrpc: "2.0", id: 8, result: {}}, "the answer to teardown")
}

// A call of a tool is a tools/call request with the tool's name and arguments, and its result, error flag included, is handed back as the host sent it.
{
  const {parent, host, answer, send} = setup()
  const calling = callTool({host, name: "arrivals", toolArguments: {stopId: "1_1"}})
  const [{message: call}] = parent.posted
  deepStrictEqual(call.method, HostMethod.toolsCall, "the call's method")
  deepStrictEqual(call.method, "tools/call", "the call's method on the wire")
  deepStrictEqual(call.params, {name: "arrivals", arguments: {stopId: "1_1"}}, "the call's params")
  const result = {content: [{type: "text", text: "{}"}], structuredContent: {data: {}}, isError: true}
  answer(call.id, result)
  const answered = await calling
  deepStrictEqual(answered, {kind: OutcomeKind.answered, result}, "a result flagged as an error is still an answer")

  const refusing = callTool({host, name: "arrivals", toolArguments: {stopId: "1_1"}})
  send({jsonrpc: "2.0", id: parent.posted[1].message.id, error: {code: -32602, message: "Tool not callable"}})
  const refused = await refusing
  deepStrictEqual(refused, {kind: OutcomeKind.refused, message: "Tool not callable"}, "a refused call")
}

// A message from another window, or of another protocol, is left alone.
{
  const {events, host} = setup()
  const seen = []
  host.onNotification(HostMethod.toolInput, (params) => seen.push(params))
  events.deliver({source: {}, data: {jsonrpc: "2.0", method: HostMethod.toolInput, params: {arguments: {}}}})
  events.deliver({source: null, data: {jsonrpc: "2.0", method: HostMethod.toolInput, params: {arguments: {}}}})
  deepStrictEqual(seen, [], "a notification from another window")
}

// Update-model-context and message are requests, each answered by its id.
{
  const {parent, host, answer, send} = setup()
  const structuredContent = {schema: "gobusgo.journey", version: 1}
  const updating = updateModelContext({host, structuredContent})
  const [{message: update}] = parent.posted
  deepStrictEqual(update.method, HostMethod.updateModelContext, "the context request's method")
  deepStrictEqual(update.params, {content: [{type: "text", text: JSON.stringify(structuredContent)}], structuredContent}, "the context request's params")

  const messaging = sendMessage({host, text: "I chose it."})
  const message = parent.posted[1].message
  deepStrictEqual(message.method, HostMethod.message, "the message request's method")
  deepStrictEqual(message.params, {role: "user", content: [{type: "text", text: "I chose it."}]}, "the message request's params")
  deepStrictEqual(update.id === message.id, false, "each request has its own id")

  // The answers arrive out of order and each finds its request.
  send({jsonrpc: "2.0", id: message.id, error: {code: -32000, message: "Message sending denied"}})
  answer(update.id, {})
  const messageOutcome = await messaging
  const updateOutcome = await updating
  deepStrictEqual(messageOutcome, {kind: OutcomeKind.refused, message: "Message sending denied"}, "a refused message")
  deepStrictEqual(updateOutcome, {kind: OutcomeKind.answered, result: {}}, "an answered context update")
}

// An answer that carries isError is a refusal, for either request.
{
  const {parent, host, answer} = setup()
  const updating = updateModelContext({host, structuredContent: {version: 1}})
  const messaging = sendMessage({host, text: "I chose it."})
  answer(parent.posted[0].message.id, {isError: true})
  answer(parent.posted[1].message.id, {isError: true})
  const updateOutcome = await updating
  const messageOutcome = await messaging
  deepStrictEqual(updateOutcome.kind, OutcomeKind.refused, "a context update answered with isError")
  deepStrictEqual(messageOutcome.kind, OutcomeKind.refused, "a message answered with isError")
}

// An answer with isError false is an answer.
{
  const {parent, host, answer} = setup()
  const messaging = sendMessage({host, text: "I chose it."})
  answer(parent.posted[0].message.id, {isError: false})
  const messageOutcome = await messaging
  deepStrictEqual(messageOutcome, {kind: OutcomeKind.answered, result: {isError: false}}, "a message answered with isError false")
}

// An answer after the timeout, or to no request, is dropped.
{
  const {parent, host, timers, answer} = setup()
  const updating = updateModelContext({host, structuredContent: {}})
  timers.fireAll()
  const timedOutUpdate = await updating
  deepStrictEqual(timedOutUpdate, {kind: OutcomeKind.timedOut}, "a timed-out context update")
  answer(parent.posted[0].message.id, {})
  answer(UNKNOWN_ID, {})
}

// The requests the host makes of the app: ping and teardown are answered with an empty result, and any other is method not found.
{
  const {parent, send} = setup()
  send({jsonrpc: "2.0", id: 7, method: HostMethod.ping})
  send({jsonrpc: "2.0", id: 8, method: HostMethod.resourceTeardown, params: {reason: "done"}})
  send({jsonrpc: "2.0", id: 9, method: "ui/unknown"})
  const answers = Array.from(parent.posted, messageOf)
  deepStrictEqual(answers, [
    {jsonrpc: "2.0", id: 7, result: {}},
    {jsonrpc: "2.0", id: 8, result: {}},
    {jsonrpc: "2.0", id: 9, error: {code: -32601, message: "Method not found: ui/unknown"}},
  ], "the answers to the host's requests")
}

// Notifications the app sends carry no id.
{
  const {parent, host} = setup()
  host.notify({method: HostMethod.sizeChanged, params: {width: 300, height: 400}})
  deepStrictEqual(parent.posted[0].message, {jsonrpc: "2.0", method: HostMethod.sizeChanged, params: {width: 300, height: 400}}, "a notification")
}

// What a message is.
const incomingCases = [
  {name: "a request", data: {jsonrpc: "2.0", id: 1, method: "ping"}, expected: {kind: IncomingKind.request, id: 1, method: "ping", params: undefined}},
  {name: "a notification", data: {jsonrpc: "2.0", method: "m", params: {a: 1}}, expected: {kind: IncomingKind.notification, method: "m", params: {a: 1}}},
  {name: "a result", data: {jsonrpc: "2.0", id: "x", result: {}}, expected: {kind: IncomingKind.response, id: "x", result: {}}},
  {name: "an error", data: {jsonrpc: "2.0", id: 2, error: {code: 1, message: "m"}}, expected: {kind: IncomingKind.response, id: 2, error: {code: 1, message: "m"}}},
  {name: "text", data: "hello", expected: {kind: IncomingKind.ignored}},
  {name: "null", data: null, expected: {kind: IncomingKind.ignored}},
  {name: "a list", data: [], expected: {kind: IncomingKind.ignored}},
  {name: "another protocol", data: {id: 1, method: "ping"}, expected: {kind: IncomingKind.ignored}},
  {name: "a response with no id", data: {jsonrpc: "2.0", result: {}}, expected: {kind: IncomingKind.ignored}},
  {name: "a response with neither result nor error", data: {jsonrpc: "2.0", id: 1}, expected: {kind: IncomingKind.ignored}},
]

for (const {name, data, expected} of incomingCases) {
  deepStrictEqual(incomingOf(data), expected, name)
}

// The geolocation permission is the host's to grant, and only a host that says so grants it.
deepStrictEqual(isLocationGranted({sandbox: {permissions: {geolocation: {}}}}), true, "a granted permission")
deepStrictEqual(isLocationGranted({sandbox: {permissions: {camera: {}}}}), false, "another permission")
deepStrictEqual(isLocationGranted({sandbox: {}}), false, "no permissions")
deepStrictEqual(isLocationGranted({}), false, "no sandbox")
deepStrictEqual(isLocationGranted(undefined), false, "no capabilities")

// A host takes the model's context only where it declares `updateModelContext`.
deepStrictEqual(isContextAccepted({updateModelContext: {text: {}}}), true, "a declared context update")
deepStrictEqual(isContextAccepted({updateModelContext: {}}), true, "a declared context update with no content types")
deepStrictEqual(isContextAccepted({message: {}}), false, "another capability")
deepStrictEqual(isContextAccepted({updateModelContext: true}), false, "a context update that is no record")
deepStrictEqual(isContextAccepted({}), false, "no capabilities named")
deepStrictEqual(isContextAccepted(undefined), false, "no capabilities")

// A host proxies tool calls to the server only where it declares `serverTools`.
deepStrictEqual(isServerToolsDeclared({serverTools: {}}), true, "a declared proxy")
deepStrictEqual(isServerToolsDeclared({serverTools: {listChanged: true}}), true, "a declared proxy with list changes")
deepStrictEqual(isServerToolsDeclared({serverResources: {}}), false, "another capability")
deepStrictEqual(isServerToolsDeclared({serverTools: true}), false, "a proxy that is no record")
deepStrictEqual(isServerToolsDeclared({}), false, "no capabilities named")
deepStrictEqual(isServerToolsDeclared(undefined), false, "no capabilities")

deepStrictEqual(themeOf({theme: "dark"}), {kind: ThemeKind.named, theme: "dark"}, "a dark theme")
deepStrictEqual(themeOf({theme: "light", displayMode: "inline"}), {kind: ThemeKind.named, theme: "light"}, "a light theme")
deepStrictEqual(themeOf({theme: "sepia"}), {kind: ThemeKind.none}, "an unknown theme")
deepStrictEqual(themeOf({displayMode: "inline"}), {kind: ThemeKind.none}, "a context change with no theme")
deepStrictEqual(themeOf(undefined), {kind: ThemeKind.none}, "no context")

console.log("mcp_host_check: all cases passed")
