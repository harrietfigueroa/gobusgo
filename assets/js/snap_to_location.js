import {readyEventName} from "./basemap"

const storageKey = "gobusgo:snap-to-location"
const storedValue = "true"
const buttonSelector = ".maplibregl-ctrl-geolocate"
const snapZoomMax = 15
const positionTimeoutMs = 10_000
const noticeMs = 8_000
const deniedText = "Location permission was denied, so the map stays where it is."
const unavailableText = "Your location could not be found, so the map stays where it is."
const outsideText = "Your location is outside the area this map covers."

// Whether this browser stored that the rider snaps to their location.
// Reading throws where storage is blocked, such as a private window, which
// reads as nothing stored.
function readStored() {
  try {
    return window.localStorage.getItem(storageKey) === storedValue
  } catch (error) {
    console.warn("Stored snap to location not readable", error)
    return false
  }
}

function writeStored() {
  try {
    window.localStorage.setItem(storageKey, storedValue)
  } catch (error) {
    console.warn("Snap to location not stored", error)
  }
}

// Whether the browser gives a position with no prompt. A browser without
// the Permissions API, and one that refuses the query, reads as one that
// prompts.
async function permissionGranted() {
  if (navigator.permissions === undefined) return false

  try {
    const status = await navigator.permissions.query({name: "geolocation"})
    return status.state === "granted"
  } catch (error) {
    console.warn("Location permission not readable", error)
    return false
  }
}

function inside({south, west, north, east}, {latitude, longitude}) {
  return latitude >= south && latitude <= north && longitude >= west && longitude <= east
}

function camera(map) {
  return {
    center: map.getCenter(),
    zoom: map.getZoom(),
    bearing: map.getBearing(),
    pitch: map.getPitch()
  }
}

// GeolocationPositionError names code 1 PERMISSION_DENIED; 2 and 3 are a
// position that is unavailable and one that timed out.
// https://developer.mozilla.org/en-US/docs/Web/API/GeolocationPositionError/code — checked 2026-10-09
function errorText(error) {
  return error.code === error.PERMISSION_DENIED ? deniedText : unavailableText
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
    window.addEventListener(readyEventName, this.onBasemapReady)
  },

  attach({map, maplibre}) {
    const control = new maplibre.GeolocateControl({
      positionOptions: {enableHighAccuracy: false, maximumAge: 0, timeout: positionTimeoutMs},
      fitBoundsOptions: {maxZoom: snapZoomMax},
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
      if (!moved.geolocateSource) this.restCamera = camera(map)
    })

    control.on("geolocate", (position) => { this.located(map, position.coords) })
    control.on("error", (error) => { this.explain(errorText(error)) })
    map.addControl(control)

    map.getContainer().querySelector(buttonSelector).addEventListener("click", () => {
      this.clicked = true
      this.hideNotice()
    })

    if (!this.loadSnapOffered) {
      this.loadSnapOffered = true
      this.snapOnLoad(control)
    }
  },

  async snapOnLoad(control) {
    if (!readStored()) return
    if (!(await permissionGranted())) return

    // The control finishes its setup after a permission query of its own
    // and refuses a trigger before that.
    if (!control.trigger()) console.warn("Map not snapped to location on load")
  },

  located(map, coords) {
    if (inside(JSON.parse(this.el.dataset.bounds), coords)) {
      writeStored()
    } else {
      map.jumpTo(this.restCamera)
      this.explain(outsideText)
    }
  },

  // Says why a snap did not happen, to a rider who asked for one. A snap
  // on load that fails says nothing.
  explain(text) {
    if (!this.clicked) return

    this.hideNotice()
    this.el.textContent = text
    this.el.hidden = false
    this.noticeTimer = window.setTimeout(() => { this.hideNotice() }, noticeMs)
  },

  hideNotice() {
    if (this.noticeTimer !== null) {
      window.clearTimeout(this.noticeTimer)
      this.noticeTimer = null
    }

    this.el.hidden = true
  },

  destroyed() {
    window.removeEventListener(readyEventName, this.onBasemapReady)
    this.hideNotice()
  }
}
