import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Basemap} from "./basemap"
import {ColorTheme, followSystemTheme} from "./color_theme"
import {ConnectionSignal} from "./connection_signal.js"
import {ConnectionState, watchConnection} from "./connection_state.js"
import {FavoriteStop} from "./favorite_stop"
import {FilterBar} from "./filter_bar"
import {FollowLocation} from "./follow_location"
import {InstallApp} from "./install_app"
import {RouteLines} from "./route_lines"
import {RouteStopTiles} from "./route_stop_tiles"
import {OfflineBasemap} from "./offline_basemap_setting"
import {OfflineSchedules} from "./offline_schedules"
import {PanelSheet} from "./panel_sheet"
import {registerServiceWorker} from "./release_update"
import {LocalTime} from "./service_alerts"
import {SharedVehicles, SharedVehicleToggle} from "./shared_vehicles"
import {ShowDirection} from "./show_direction"
import {StopMarkers} from "./stop_markers"
import {TripPlanner} from "./trip_planner"
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
    ConnectionSignal,
    ConnectionState,
    FavoriteStop,
    FilterBar,
    FollowLocation,
    InstallApp,
    LocalTime,
    OfflineBasemap,
    OfflineSchedules,
    PanelSheet,
    RouteLines,
    RouteStopTiles,
    SharedVehicles,
    SharedVehicleToggle,
    ShowDirection,
    StopMarkers,
    TripPlanner,
    VehicleFilter,
    VehicleMarkers
  },
  params: () => ({_csrf_token: csrfToken, client: client()})
})

followSystemTheme()
// The state is read before the socket connects, so every hook reads it.
watchConnection()
liveSocket.connect()
registerServiceWorker()

// Exposed for debugging from the browser console, such as liveSocket.enableDebug().
window.liveSocket = liveSocket
