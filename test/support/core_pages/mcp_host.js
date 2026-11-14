// Stands a host of MCP Apps in the page: it writes a document with one
// frame, renders the app's resource in it, answers the app's handshake,
// hands it the tool's arguments and result as a host does once the app
// says it is initialized, and keeps every update of the model's context
// the app sends, which the check reads as `window.__corePagesHost.context`.
// It speaks the requests of MCP Apps 2026-01-26 that the apps send.
// https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx — checked 2026-11-14
({resource, toolInput, toolResult, hostCapabilities}) => {
  document.open()
  document.write("<!doctype html><html lang=\"en\"><head><title>MCP host</title></head><body><iframe id=\"mcp-app\" title=\"App\" style=\"width: 420px; height: 900px; border: 0\"></iframe></body></html>")
  document.close()

  const frame = document.getElementById("mcp-app")
  const host = {context: []}
  window.__corePagesHost = host

  function post(message) {
    frame.contentWindow.postMessage({jsonrpc: "2.0", ...message}, "*")
  }

  window.addEventListener("message", (event) => {
    const message = event.data
    const isFromApp = event.source === frame.contentWindow
    const isObject = typeof message === "object" && message !== null
    const isObjectFromApp = isFromApp && isObject
    const isProtocol = isObjectFromApp && message.jsonrpc === "2.0"

    if (!isProtocol) {
      return
    }

    if (message.method === "ui/initialize") {
      post({id: message.id, result: {protocolVersion: "2026-01-26", hostInfo: {name: "core-pages-host", version: "1"}, hostCapabilities, hostContext: {theme: "light"}}})
    } else if (message.method === "ui/notifications/initialized") {
      post({method: "ui/notifications/tool-input", params: {arguments: toolInput}})
      post({method: "ui/notifications/tool-result", params: toolResult})
    } else if (message.method === "ui/update-model-context") {
      host.context.push(message.params)
      post({id: message.id, result: {}})
    } else if (message.id !== undefined) {
      post({id: message.id, result: {}})
    }
  })

  frame.srcdoc = resource
}
