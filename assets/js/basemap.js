import {Protocol} from "../vendor/pmtiles/dist/esm/index.js"
import {layers, namedFlavor} from "../vendor/@protomaps/basemaps/dist/esm/index.js"
import {assertCondition} from "./assert"
import {sheetInsets} from "./panel_sheet"
import {CHANGE_EVENT_NAME as THEME_CHANGE_EVENT_NAME, currentTheme} from "./color_theme"
import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state"
import {CHANGE_EVENT_NAME as OFFLINE_BASEMAP_CHANGE_EVENT_NAME, drawnArchiveUrl, savedBasemapOf} from "./offline_basemap"
import {readSavedBasemap} from "./offline_basemap_setting"
import {flavorName} from "./theme"
import {HandoffKind, NO_HANDOFF, takeHandoffState} from "./hook_handoff"
import {pageEvents} from "./page_events"

const PROTOCOL_NAME = "pmtiles"
const SOURCE_NAME = "protomaps"
const LABEL_LANGUAGE = "en"
const FIT_PADDING_PIXELS = 24
const FAILURE_TEXT = "The map could not be loaded."

export const READY_EVENT_NAME = "basemap:ready"
export const RESTYLED_EVENT_NAME = "basemap:restyled"

/**
 * The event data of a camera move of the page's own that zooms, a fit of
 * the map to a set of bounds or a move to a place at a zoom, which its
 * camera events carry so that a listener tells it from a zoom by the rider.
 */
export const FIT_EVENT_DATA = Object.freeze({fitSource: true})

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

// The basemap's style alone, in `theme`, from the archive at `archiveUrl`:
// where the tiles, the fonts, and the sprites come from and how the layers
// are drawn. Nothing here reads vehicle data.
function basemapStyle({archiveUrl, sources: {fontsUrl, spritesUrl, attribution}, theme}) {
  const flavor = flavorName(theme)

  return {
    version: 8,
    glyphs: `${absoluteUrl(fontsUrl)}/{fontstack}/{range}.pbf`,
    sprite: `${absoluteUrl(spritesUrl)}/${flavor}`,
    sources: {
      [SOURCE_NAME]: {
        type: "vector",
        url: `${PROTOCOL_NAME}://${absoluteUrl(archiveUrl)}`,
        attribution
      }
    },
    layers: layers(SOURCE_NAME, namedFlavor(flavor), {lang: LABEL_LANGUAGE})
  }
}

// The address of the basemap's offline extract on `element`, or the empty
// string for a basemap without one.
function offlineArchiveUrlOf(element) {
  const url = element.dataset.offlineArchiveUrl

  if (url === undefined) {
    return ""
  }

  return url
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
// detail holds the map and the library. The map is drawn in the page's
// theme, and a change of the theme sets the map's style anew, which drops
// every source and layer the other hooks added; once the new style has
// loaded, a bubbling "basemap:restyled" DOM event whose detail holds the
// map tells them to add theirs again. The style is set anew the same way
// when the page goes offline with the basemap's offline extract saved,
// which the map then draws from, and when it comes back, to the full
// archive.
export const Basemap = {
  mounted() {
    const element = this.el
    const bounds = cornerBounds(JSON.parse(element.dataset.bounds))
    this.map = null
    this.fitBounds = bounds
    this.handedCamera = takeHandoffState(element.id)
    this.theme = null
    this.restyling = false
    // The theme and the archive the map was drawn in when its WebGL context
    // was lost, and whether a style set anew had not loaded by then.
    this.lostStyle = null
    this.archiveUrl = element.dataset.archiveUrl
    this.offlineArchiveUrl = offlineArchiveUrlOf(element)
    this.saved = savedBasemapOf({url: this.offlineArchiveUrl, isStored: false})
    this.drawnUrl = this.archiveUrl

    this.onThemeChange = (event) => { this.restyle({theme: event.detail.theme, archiveUrl: this.drawnUrl}) }
    window.addEventListener(THEME_CHANGE_EVENT_NAME, this.onThemeChange)
    this.onConnectionChange = () => { this.followArchive() }
    window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onConnectionChange)

    this.onOfflineBasemapChange = (event) => {
      this.saved = event.detail.saved
      this.followArchive()
    }

    window.addEventListener(OFFLINE_BASEMAP_CHANGE_EVENT_NAME, this.onOfflineBasemapChange)
    this.readSaved()

    this.events = pageEvents(this)
    this.events.handle("basemap:fit", (event) => {
      this.fitBounds = cornerBounds(event.bounds)

      if (this.map !== null) {
        const padding = fitPadding(sheetInsets())
        this.map.fitBounds(this.fitBounds, {padding}, FIT_EVENT_DATA)
      }
    })

    loadMaplibre(element.dataset.libraryUrl)
      .then((maplibre) => { this.createMap(maplibre) })
      .catch((error) => {
        // The page leaves this element's content alone, so the message stays.
        element.textContent = FAILURE_TEXT
        console.error("basemap not loaded", error)
      })
  },

  createMap(maplibre) {
    const element = this.el
    const padding = fitPadding(sheetInsets())
    this.theme = currentTheme()

    this.map = new maplibre.Map({
      container: element,
      style: basemapStyle({archiveUrl: this.drawnUrl, sources: element.dataset, theme: this.theme}),
      ...this.firstView(padding),
      attributionControl: false
    })

    // The attribution stays written out; the compact form hides it
    // behind a button on a narrow map.
    this.map.addControl(new maplibre.AttributionControl({compact: false}))
    this.map.addControl(new maplibre.NavigationControl({showCompass: false}))
    this.map.on("error", logMapError)
    this.map.on("style.load", () => {
      if (this.restyling) {
        this.restyling = false
        element.dispatchEvent(new CustomEvent(RESTYLED_EVENT_NAME, {
          bubbles: true,
          detail: {map: this.map}
        }))
      }
    })

    // MapLibre keeps the style the map has when its WebGL context is lost,
    // and sets that style again when the context is restored, over any
    // style set in between (maplibre-gl 6.12.0, Map._contextRestored). A
    // page in the background can lose its context, so the theme can change
    // while it is lost.
    this.map.on("webglcontextlost", () => {
      this.lostStyle = {theme: this.theme, archiveUrl: this.drawnUrl, isRestyling: this.restyling}
    })
    this.map.on("webglcontextrestored", () => { this.restoreStyle() })

    element.dispatchEvent(new CustomEvent(READY_EVENT_NAME, {
      bubbles: true,
      detail: {map: this.map, maplibre}
    }))
  },

  // The map's first view: the camera the offline host's map handed over,
  // so the page joining LiveView keeps the place the rider was looking at,
  // and otherwise the element's bounds.
  firstView(padding) {
    if (this.handedCamera.kind === HandoffKind.found) {
      return this.handedCamera.state
    }

    return {bounds: this.fitBounds, fitBoundsOptions: {padding}}
  },

  // The camera of a map the offline host made, for the map LiveView makes
  // on the same element.
  handoffState() {
    if (this.map === null) {
      return NO_HANDOFF
    }

    const center = this.map.getCenter()
    const camera = {center: [center.lng, center.lat], zoom: this.map.getZoom(), bearing: this.map.getBearing(), pitch: this.map.getPitch()}
    return {kind: HandoffKind.found, state: camera}
  },

  // Reads whether the page's offline extract is saved, and draws from it
  // where the page is offline.
  async readSaved() {
    const hasExtract = this.offlineArchiveUrl !== ""

    if (!hasExtract) {
      return
    }

    try {
      this.saved = await readSavedBasemap(this.offlineArchiveUrl)
    } catch (error) {
      console.warn("Saved map not read", error)
      return
    }

    this.followArchive()
  },

  // Draws the archive the connection and the saved map call for. A map not
  // made yet is made from it.
  followArchive() {
    const archiveUrl = drawnArchiveUrl({
      connection: connectionState(),
      saved: this.saved,
      archiveUrl: this.archiveUrl,
      offlineArchiveUrl: this.offlineArchiveUrl
    })

    if (this.map === null) {
      this.drawnUrl = archiveUrl
      return
    }

    this.restyle({theme: this.theme, archiveUrl})
  },

  // Sets the style of the map anew in `theme` from the archive at
  // `archiveUrl`, unless the map is drawn so already or there is no map
  // yet, which is drawn in the page's theme when it is made.
  restyle({theme, archiveUrl}) {
    const hasMap = this.map !== null
    const isStyleChanged = theme !== this.theme || archiveUrl !== this.drawnUrl
    const isRestyled = hasMap && isStyleChanged

    if (isRestyled) {
      this.setStyleAnew({theme, archiveUrl})
    }
  },

  // Sets the style of the map anew in `theme` from the archive at
  // `archiveUrl`, and has the other hooks add theirs once it has loaded.
  setStyleAnew({theme, archiveUrl}) {
    this.theme = theme
    this.drawnUrl = archiveUrl
    this.restyling = true
    // The style is set whole, not diffed, which fires "style.load" once
    // it has loaded.
    const style = basemapStyle({archiveUrl, sources: this.el.dataset, theme})
    this.map.setStyle(style, {diff: false})
  },

  // Once the context is restored the map holds the style it had when the
  // context was lost, with the other hooks' sources and layers as they
  // were then. The style is set anew when the page wants another theme or
  // archive since, and when a style set anew had not loaded at the loss,
  // since the other hooks may not have added theirs to it.
  restoreStyle() {
    assertCondition(this.lostStyle !== null, "a restored context must have been lost")
    const {theme, archiveUrl, isRestyling} = this.lostStyle
    const wanted = {theme: this.theme, archiveUrl: this.drawnUrl}
    this.lostStyle = null
    const isThemeChanged = theme !== wanted.theme
    const isArchiveChanged = archiveUrl !== wanted.archiveUrl
    const isStyleChanged = isThemeChanged || isArchiveChanged
    const isSetAnew = isRestyling || isStyleChanged

    if (isSetAnew) {
      this.setStyleAnew(wanted)
    } else {
      // The restored style holds the other hooks' layers already.
      this.restyling = false
    }
  },

  destroyed() {
    window.removeEventListener(THEME_CHANGE_EVENT_NAME, this.onThemeChange)
    this.events.release()
    window.removeEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onConnectionChange)
    window.removeEventListener(OFFLINE_BASEMAP_CHANGE_EVENT_NAME, this.onOfflineBasemapChange)

    if (this.map !== null) {
      this.map.remove()
    }
  }
}
