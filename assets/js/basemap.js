import {Protocol} from "../vendor/pmtiles/dist/esm/index.js"
import {layers, namedFlavor} from "../vendor/@protomaps/basemaps/dist/esm/index.js"
import {sheetInsets} from "./panel_sheet"

const PROTOCOL_NAME = "pmtiles"
const SOURCE_NAME = "protomaps"
const FLAVOR_NAME = "light"
const LABEL_LANGUAGE = "en"
const FIT_PADDING_PIXELS = 24
const FAILURE_TEXT = "The map could not be loaded."
// A map takes the texts of its controls when it is made, so the label of
// the geolocate control is given here.
const locale = {"GeolocateControl.FindMyLocation": "Snap to my location"}

export const READY_EVENT_NAME = "basemap:ready"

let maplibreLoading = null

// Loads the library once for the page and registers the protocol that reads
// tiles out of an archive with HTTP range requests. MapLibre is served as
// its own module files and loaded at run time: it starts its worker from the
// file beside the one it was loaded from, which a bundle has no address for.
function loadMaplibre(maplibreUrl) {
  if (maplibreLoading === null) {
    maplibreLoading = import(maplibreUrl).then(registerProtocol)
  }

  return maplibreLoading
}

function registerProtocol(maplibre) {
  maplibre.addProtocol(PROTOCOL_NAME, new Protocol().tile)
  return maplibre
}

function logMapError(event) {
  console.error("basemap error", event.error)
}

// The style names its sources by absolute address, so a path the server
// gives is resolved against the page.
function absoluteUrl(path) {
  return new URL(path, window.location.href).href
}

// The basemap's style alone: where the tiles, the fonts, and the sprites
// come from and how the layers are drawn. Nothing here reads vehicle data.
function basemapStyle({archiveUrl, fontsUrl, spritesUrl, attribution}) {
  return {
    version: 8,
    glyphs: `${absoluteUrl(fontsUrl)}/{fontstack}/{range}.pbf`,
    sprite: `${absoluteUrl(spritesUrl)}/${FLAVOR_NAME}`,
    sources: {
      [SOURCE_NAME]: {
        type: "vector",
        url: `${PROTOCOL_NAME}://${absoluteUrl(archiveUrl)}`,
        attribution
      }
    },
    layers: layers(SOURCE_NAME, namedFlavor(FLAVOR_NAME), {lang: LABEL_LANGUAGE})
  }
}

// Bounds arrive as {south, west, north, east}; the library takes the
// south-west corner, then the north-east one, each longitude first.
function cornerBounds({south, west, north, east}) {
  return [[west, south], [east, north]]
}

// The padding a fit leaves around its bounds, wider by what the panel
// sheet covers of the map, so the fitted bounds stay in sight beside it.
function fitPadding({left, bottom}) {
  return {
    top: FIT_PADDING_PIXELS,
    right: FIT_PADDING_PIXELS,
    bottom: FIT_PADDING_PIXELS + bottom,
    left: FIT_PADDING_PIXELS + left
  }
}

// The hook of the element the map is drawn in. The element's data
// attributes hold the library's address, the basemap's sources, and the
// bounds of the first view;
// the server moves the view with the "basemap:fit" event. A new map is
// announced on the element as a bubbling "basemap:ready" DOM event whose
// detail holds the map and the library.
export const Basemap = {
  mounted() {
    const element = this.el
    const bounds = cornerBounds(JSON.parse(element.dataset.bounds))
    this.map = null
    this.fitBounds = bounds

    this.handleEvent("basemap:fit", (event) => {
      this.fitBounds = cornerBounds(event.bounds)

      if (this.map !== null) {
        const padding = fitPadding(sheetInsets())
        this.map.fitBounds(this.fitBounds, {padding})
      }
    })

    loadMaplibre(element.dataset.libraryUrl)
      .then((maplibre) => {
        const padding = fitPadding(sheetInsets())

        this.map = new maplibre.Map({
          container: element,
          style: basemapStyle(element.dataset),
          bounds: this.fitBounds,
          fitBoundsOptions: {padding},
          locale,
          attributionControl: false
        })

        // The attribution stays written out; the compact form hides it
        // behind a button on a narrow map.
        this.map.addControl(new maplibre.AttributionControl({compact: false}))
        this.map.addControl(new maplibre.NavigationControl({showCompass: false}))
        this.map.on("error", logMapError)

        element.dispatchEvent(new CustomEvent(READY_EVENT_NAME, {
          bubbles: true,
          detail: {map: this.map, maplibre}
        }))
      })
      .catch((error) => {
        // The page leaves this element's content alone, so the message stays.
        element.textContent = FAILURE_TEXT
        console.error("basemap not loaded", error)
      })
  },

  destroyed() {
    if (this.map !== null) {
      this.map.remove()
    }
  }
}
