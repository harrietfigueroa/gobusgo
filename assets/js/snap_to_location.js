import {READY_EVENT_NAME} from "./basemap"
import {OutcomeKind, errorOutcome} from "./position_watch"
import {permissionGranted} from "./rider_position"
import {storedSettings} from "./stored_settings"

const BUTTON_SELECTOR = ".maplibregl-ctrl-geolocate"
const SNAP_ZOOM_MAX = 15
const POSITION_TIMEOUT_MS = 10_000
const NOTICE_MS = 8_000
const DENIED_TEXT = "Location permission was denied, so the map stays where it is."
const UNAVAILABLE_TEXT = "Your location could not be found, so the map stays where it is."
const OUTSIDE_TEXT = "Your location is outside the area this map covers."

function inside({south, west, north, east}, {latitude, longitude}) {
  const isWithinLatitude = latitude >= south && latitude <= north
  const isWithinLongitude = longitude >= west && longitude <= east
  const isInside = isWithinLatitude && isWithinLongitude
  return isInside
}

function camera(map) {
  return {
    center: map.getCenter(),
    zoom: map.getZoom(),
    bearing: map.getBearing(),
    pitch: map.getPitch()
  }
}

// The control's error event is the browser's GeolocationPositionError.
function errorText(error) {
  const outcome = errorOutcome(error.code)

  if (outcome.kind === OutcomeKind.denied) {
    return DENIED_TEXT
  } else {
    return UNAVAILABLE_TEXT
  }
}

// The hook of the notice beside the map. On each map the basemap announces
// it adds the library's geolocate control, which centers the map on the
// rider's position once per click and draws a dot there. A position never
// leaves this module: no event to the server carries one, and the browser
// stores only that a snap succeeded. The first map of a page whose browser
// stored that, and gives a position with no prompt, is centered on its own.
// The element's data-bounds are the area the map covers; a position outside
// them leaves the view where it was.
export const SnapToLocation = {
  mounted() {
    this.map = null
    this.control = null
    this.clicked = false
    this.loadSnapOffered = false
    this.noticeTimer = null
    this.restCamera = null

    this.onBasemapReady = (event) => { this.attach(event.detail) }
    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
  },

  attach({map, maplibre}) {
    const control = new maplibre.GeolocateControl({
      positionOptions: {enableHighAccuracy: false, maximumAge: 0, timeout: POSITION_TIMEOUT_MS},
      fitBoundsOptions: {maxZoom: SNAP_ZOOM_MAX},
      trackUserLocation: false,
      showUserLocation: true,
      showAccuracyCircle: true,
      zoomToUserAccuracy: true
    })

    this.map = map
    this.control = control
    this.restCamera = camera(map)

    // The control moves the map before it announces a position, so the view
    // to go back to is the one the last move of another origin ended on.
    map.on("moveend", (moved) => {
      if (!moved.geolocateSource) {
        this.restCamera = camera(map)
      }
    })

    control.on("geolocate", (position) => { this.located(map, position.coords) })
    control.on("error", (error) => { this.explain(errorText(error)) })
    map.addControl(control)

    map.getContainer().querySelector(BUTTON_SELECTOR).addEventListener("click", () => {
      this.clicked = true
      this.hideNotice()
    })

    if (!this.loadSnapOffered) {
      this.loadSnapOffered = true
      this.snapOnLoad(control)
    }
  },

  async snapOnLoad(control) {
    if (!storedSettings.readSnapToLocation()) {
      return
    }

    const granted = await permissionGranted()

    if (!granted) {
      return
    }

    // The control finishes its setup after a permission query of its own
    // and refuses a trigger before that.
    if (!control.trigger()) {
      console.warn("Map not snapped to location on load")
    }
  },

  located(map, coords) {
    if (inside(JSON.parse(this.el.dataset.bounds), coords)) {
      storedSettings.writeSnapToLocation()
    } else {
      map.jumpTo(this.restCamera)
      this.explain(OUTSIDE_TEXT)
    }
  },

  // Says why a snap did not happen, to a rider who asked for one. A snap
  // on load that fails says nothing.
  explain(text) {
    if (!this.clicked) {
      return
    }

    this.hideNotice()
    this.el.textContent = text
    this.el.hidden = false
    this.noticeTimer = window.setTimeout(() => { this.hideNotice() }, NOTICE_MS)
  },

  hideNotice() {
    if (this.noticeTimer !== null) {
      window.clearTimeout(this.noticeTimer)
      this.noticeTimer = null
    }

    this.el.hidden = true
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    this.hideNotice()
  }
}
