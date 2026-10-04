import {Protocol} from "../vendor/pmtiles/dist/esm/index.js"
import {layers, namedFlavor} from "../vendor/@protomaps/basemaps/dist/esm/index.js"

// MapLibre is served as its own module files and loaded at run time: it
// starts its worker from the file beside the one it was loaded from, which a
// bundle has no address for.
const maplibreUrl = "/assets/vendor/maplibre-gl/maplibre-gl.mjs"
const protocolName = "pmtiles"
const sourceName = "protomaps"
const flavorName = "light"
const labelLanguage = "en"
const fitPaddingPixels = 24
const failureText = "The map could not be loaded."

let maplibreLoading = null

// Loads the library once for the page and registers the protocol that reads
// tiles out of an archive with HTTP range requests.
function loadMaplibre() {
  if (maplibreLoading === null) {
    maplibreLoading = import(maplibreUrl).then((maplibre) => {
      maplibre.addProtocol(protocolName, new Protocol().tile)
      return maplibre
    })
  }

  return maplibreLoading
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
    sprite: `${absoluteUrl(spritesUrl)}/${flavorName}`,
    sources: {
      [sourceName]: {
        type: "vector",
        url: `${protocolName}://${absoluteUrl(archiveUrl)}`,
        attribution
      }
    },
    layers: layers(sourceName, namedFlavor(flavorName), {lang: labelLanguage})
  }
}

// Bounds arrive as {south, west, north, east}; the library takes the
// south-west corner, then the north-east one, each longitude first.
function cornerBounds({south, west, north, east}) {
  return [[west, south], [east, north]]
}

// The hook of the element the map is drawn in. The element's data
// attributes hold the basemap's sources and the bounds of the first view;
// the server moves the view with the "basemap:fit" event.
export const Basemap = {
  mounted() {
    const element = this.el
    const bounds = cornerBounds(JSON.parse(element.dataset.bounds))
    this.map = null
    this.fitBounds = bounds

    this.handleEvent("basemap:fit", (event) => {
      this.fitBounds = cornerBounds(event.bounds)

      if (this.map !== null) {
        this.map.fitBounds(this.fitBounds, {padding: fitPaddingPixels})
      }
    })

    loadMaplibre()
      .then((maplibre) => {
        this.map = new maplibre.Map({
          container: element,
          style: basemapStyle(element.dataset),
          bounds: this.fitBounds,
          fitBoundsOptions: {padding: fitPaddingPixels},
          attributionControl: false
        })

        // The attribution stays written out; the compact form hides it
        // behind a button on a narrow map.
        this.map.addControl(new maplibre.AttributionControl({compact: false}))
        this.map.addControl(new maplibre.NavigationControl({showCompass: false}))
        this.map.on("error", (event) => { console.error("basemap error", event.error) })
      })
      .catch((error) => {
        // The page leaves this element's content alone, so the message stays.
        element.textContent = failureText
        console.error("basemap not loaded", error)
      })
  },

  destroyed() {
    if (this.map !== null) {
      this.map.remove()
    }
  }
}
