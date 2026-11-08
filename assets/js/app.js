import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Basemap} from "./basemap"
import {ColorTheme, followSystemTheme} from "./color_theme"
import {FavoriteStop} from "./favorite_stop"
import {FilterBar} from "./filter_bar"
import {RouteLines} from "./route_lines"
import {RouteStopTiles} from "./route_stop_tiles"
import {OfflineSchedules} from "./offline_schedules"
import {PanelSheet} from "./panel_sheet"
import {LocalTime} from "./service_alerts"
import {SnapToLocation} from "./snap_to_location"
import {StopMarkers} from "./stop_markers"
import {VehicleFilter} from "./vehicle_filter"
import {VehicleMarkers} from "./vehicle_markers"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// What the browser tells the usage recorder about itself. The referrer is
// reduced to its host here, so its path and query never leave the browser.
function client() {
  let referrerHost = null

  try {
    referrerHost = new URL(document.referrer).hostname
  } catch {
    // An empty referrer is no URL, and a visit with none sends no host.
  }

  return {
    viewport_width: window.innerWidth,
    language: navigator.language,
    referrer_host: referrerHost
  }
}

// The parameters are a function, so each connection sends the viewport of
// its own moment.
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {
    Basemap,
    ColorTheme,
    FavoriteStop,
    FilterBar,
    LocalTime,
    OfflineSchedules,
    PanelSheet,
    RouteLines,
    RouteStopTiles,
    SnapToLocation,
    StopMarkers,
    VehicleFilter,
    VehicleMarkers
  },
  params: () => ({_csrf_token: csrfToken, client: client()})
})

followSystemTheme()
liveSocket.connect()

// Exposed for debugging from the browser console, such as liveSocket.enableDebug().
window.liveSocket = liveSocket
