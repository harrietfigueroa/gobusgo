import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Basemap} from "./basemap"
import {RouteLines} from "./route_lines"
import {StopMarkers} from "./stop_markers"
import {VehicleFilter} from "./vehicle_filter"
import {VehicleMarkers} from "./vehicle_markers"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {Basemap, RouteLines, StopMarkers, VehicleFilter, VehicleMarkers},
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()

// Exposed for debugging from the browser console, such as liveSocket.enableDebug().
window.liveSocket = liveSocket
