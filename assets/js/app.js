import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Basemap} from "./basemap"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {Basemap},
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()

// Exposed for debugging from the browser console, such as liveSocket.enableDebug().
window.liveSocket = liveSocket
