import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {currentTheme} from "./color_theme"
import {announceRiderPopupChange, RIDER_POPUP_CLASS_NAME} from "./rider_popups"
import {DecodeKind, decodeBlock, fileUrl, readIndex} from "./shared_vehicle_format"
import {ViewKind, namesToFetch, tilesInView} from "./shared_vehicle_tiles"
import {storedSettings} from "./stored_settings"
import {MARKER_LAYER_NAME as STOP_LAYER_NAME} from "./stop_markers"
import {mapColors} from "./theme"

// The shared scooter and bike layer of the vehicle page. The server names
// the current index of each system's newest fetch in a data attribute of
// the layer's element, and the browser reads every file from the static
// path alone: the index, then the tiles of the index's zoom that the view
// covers and the index lists. The view reaches no server event, so the
// server never learns where the rider looks.
//
// A tile's address holds its fetch, so a tile read once for a fetch is
// read from memory while the rider pans back to it, and a new fetch's
// tiles replace the drawn ones once those in view have arrived.

const SOURCE_NAME = "shared-vehicles"
const LAYER_NAME = "shared-vehicles"
const FETCH_TIMEOUT_MS = 15_000
const TILE_CACHE_COUNT_MAX = 256
const MARKER_RADIUS_PIXELS = 4.5
const MARKER_STROKE_WIDTH_PIXELS = 1
const LOW_RANGE_OPACITY = 0.35
const FULL_OPACITY = 1
const METERS_PER_KILOMETER = 1000
const MS_PER_MINUTE = 60_000
const COMPRESSION_FORMAT = "gzip"
const FALLBACK_COLOR = "#64748b"
const POPUP_TITLE_CLASS_NAME = "popup-title"

/** The kinds of a file read from the static path. */
const ReadKind = Object.freeze({read: "read", failed: "failed"})

function emptyCollection() {
  return {type: "FeatureCollection", features: []}
}

// The bytes of the gzip stream at `url`, expanded, within the timeout. A
// failed request is a value: the layer draws what it has and tries again
// at the next fetch or move.
async function readExpanded(url) {
  try {
    const response = await fetch(url, {signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)})

    if (!response.ok) {
      return {kind: ReadKind.failed, status: response.status}
    }

    const expanded = response.body.pipeThrough(new DecompressionStream(COMPRESSION_FORMAT))
    const buffer = await new Response(expanded).arrayBuffer()
    return {kind: ReadKind.read, bytes: new Uint8Array(buffer)}
  } catch (error) {
    return {kind: ReadKind.failed, error}
  }
}

function parsedJson(bytes) {
  try {
    const text = new TextDecoder().decode(bytes)
    return {kind: ReadKind.read, value: JSON.parse(text)}
  } catch (error) {
    return {kind: ReadKind.failed, error}
  }
}

// The indexes the server names, each with its address and its operator.
function shownIndexes(element) {
  return JSON.parse(element.dataset.indexes)
}

function formColorCase({form_factor: formFactor, color}) {
  return [formFactor, color]
}

function formLabelEntry({form_factor: formFactor, label}) {
  return [formFactor, label]
}

function rangeText(rangeMeters) {
  if (typeof rangeMeters === "number") {
    const kilometers = rangeMeters / METERS_PER_KILOMETER
    return `Range left: ${kilometers.toFixed(1)} km`
  } else {
    return "Range left: not published"
  }
}

function seenText({operatorName, fetchedAtMs}) {
  const minutes = Math.floor((Date.now() - fetchedAtMs) / MS_PER_MINUTE)

  if (minutes < 1) {
    return `${operatorName}, seen under a minute ago`
  } else {
    return `${operatorName}, seen ${minutes} min ago`
  }
}

// A vehicle's popup is built as text nodes from the feature's properties.
function popupContent({properties, formLabels}) {
  const content = document.createElement("div")
  const title = document.createElement("p")
  title.className = POPUP_TITLE_CLASS_NAME
  title.textContent = formLabels.get(properties.formFactor)
  const range = document.createElement("p")
  range.textContent = rangeText(properties.rangeMeters)
  const seen = document.createElement("p")
  seen.textContent = seenText(properties)
  content.append(title, range, seen)
  return content
}

function isHeldNone() {
  return false
}

// The view of `map` as its west, south, east, and north in degrees.
function boundsOf(map) {
  const bounds = map.getBounds()
  return {west: bounds.getWest(), south: bounds.getSouth(), east: bounds.getEast(), north: bounds.getNorth()}
}

function vehicleFeature({vehicle, operatorName, fetchedAtMs}) {
  return {
    type: "Feature",
    geometry: {type: "Point", coordinates: [vehicle.lon, vehicle.lat]},
    properties: {formFactor: vehicle.formFactor, rangeMeters: vehicle.rangeMeters, operatorName, fetchedAtMs}
  }
}

// The hook of the element beside the map that carries the indexes. It
// draws the layer on each map the basemap announces, again in the theme of
// a map whose style is set anew.
export const SharedVehicles = {
  mounted() {
    const {dataset} = this.el
    this.zoomMin = Number(dataset.zoomMin)
    this.rangeLowMeters = Number(dataset.rangeLowMeters)
    this.formColors = JSON.parse(dataset.formColors)
    const labelEntries = Array.from(this.formColors, formLabelEntry)
    this.formLabels = new Map(labelEntries)
    this.map = null
    this.maplibre = null
    this.indexesText = dataset.indexes
    // The index of each shown system, once read, by its address.
    this.indexes = new Map()
    // The vehicles of each tile read, by the tile's address, oldest first.
    this.tiles = new Map()
    this.collection = emptyCollection()
    this.generation = 0

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      map.once("load", () => { this.attach(map, maplibre) })
    }

    this.onRestyled = (event) => {
      if (event.detail.map === this.map) {
        this.addLayer(this.map)
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
  },

  updated() {
    const indexesText = this.el.dataset.indexes

    if (indexesText !== this.indexesText) {
      this.indexesText = indexesText
      this.refresh()
    }
  },

  attach(map, maplibre) {
    this.map = map
    this.maplibre = maplibre
    this.addLayer(map)

    // A map keeps the listeners of a layer while the layer is added again.
    map.on("click", LAYER_NAME, (event) => { this.openPopup(event) })
    const canvas = map.getCanvas()
    map.on("mouseenter", LAYER_NAME, () => { canvas.style.cursor = "pointer" })
    map.on("mouseleave", LAYER_NAME, () => { canvas.style.cursor = "" })
    map.on("moveend", () => { this.refresh() })
    this.refresh()
  },

  // Adds the source with the vehicles drawn now and the layer in the
  // page's theme, under the stops where the map has them.
  addLayer(map) {
    const colors = mapColors(currentTheme())
    const colorCases = this.formColors.flatMap(formColorCase)
    const isLowRange = ["all", ["==", ["typeof", ["get", "rangeMeters"]], "number"], ["<", ["get", "rangeMeters"], this.rangeLowMeters]]
    map.addSource(SOURCE_NAME, {type: "geojson", data: this.collection})
    let beforeId

    if (map.getLayer(STOP_LAYER_NAME) !== undefined) {
      beforeId = STOP_LAYER_NAME
    }

    map.addLayer({
      id: LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      minzoom: this.zoomMin,
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": ["match", ["get", "formFactor"], ...colorCases, FALLBACK_COLOR],
        "circle-opacity": ["case", isLowRange, LOW_RANGE_OPACITY, FULL_OPACITY],
        "circle-stroke-color": colors.vehicleStroke,
        "circle-stroke-width": MARKER_STROKE_WIDTH_PIXELS,
        "circle-stroke-opacity": ["case", isLowRange, LOW_RANGE_OPACITY, FULL_OPACITY]
      }
    }, beforeId)
  },

  // Reads what the view needs of the shown indexes, then draws it. A
  // refresh that a later one overtakes draws nothing, so the drawn
  // vehicles are always the latest refresh's.
  async refresh() {
    if (this.map === null) {
      return
    }

    this.generation += 1
    const generation = this.generation
    const shown = shownIndexes(this.el)
    const isZoomedOut = this.map.getZoom() < this.zoomMin

    // The layer draws nothing below its zoom, so a zoomed-out map reads no
    // file and keeps the tiles it holds for when the rider zooms in again.
    if (isZoomedOut) {
      return
    }

    const pendingIndexes = Array.from(shown, (entry) => this.readIndexOnce(entry.url))
    await Promise.allSettled(pendingIndexes)
    const viewBounds = boundsOf(this.map)
    const urls = []

    for (const entry of shown) {
      const isHeld = (url) => this.tiles.has(url)
      const missing = this.urlsInView({entry, viewBounds, isHeld})

      for (const url of missing) {
        urls.push(url)
      }
    }

    const pendingTiles = Array.from(urls, (url) => this.readTile(url))
    await Promise.allSettled(pendingTiles)
    this.draw({shown, generation, viewBounds})
  },

  // The addresses of the tiles of `entry`'s index that the view covers and
  // `isHeld` does not hold; none for an index not read or a view that covers
  // too many tiles.
  urlsInView({entry, viewBounds, isHeld}) {
    const index = this.indexes.get(entry.url)

    if (index === undefined) {
      return []
    }

    const view = tilesInView({bounds: viewBounds, zoom: index.tileZoom})

    if (view.kind === ViewKind.tooMany) {
      return []
    }

    const isNameHeld = (name) => isHeld(fileUrl({indexUrl: entry.url, name}))
    const names = namesToFetch({tiles: view.tiles, listed: index.tiles, isHeld: isNameHeld})
    return Array.from(names, (name) => fileUrl({indexUrl: entry.url, name}))
  },

  // Reads the index at `url` unless it is read already.
  async readIndexOnce(url) {
    if (this.indexes.has(url)) {
      return
    }

    const read = await readExpanded(url)

    if (read.kind === ReadKind.failed) {
      console.warn("shared vehicle index not read", url, read)
      return
    }

    const parsed = parsedJson(read.bytes)

    if (parsed.kind === ReadKind.failed) {
      console.warn("shared vehicle index not JSON", url, parsed.error)
      return
    }

    const indexRead = readIndex(parsed.value)

    if (indexRead.kind === DecodeKind.refused) {
      console.warn("shared vehicle index refused", url, indexRead.reason)
      return
    }

    this.indexes.set(url, indexRead.index)
  },

  async readTile(url) {
    const read = await readExpanded(url)

    if (read.kind === ReadKind.failed) {
      console.warn("shared vehicle tile not read", url, read)
      return
    }

    const decoded = decodeBlock(read.bytes)

    if (decoded.kind === DecodeKind.refused) {
      console.warn("shared vehicle tile refused", url, decoded.reason)
      return
    }

    this.tiles.set(url, decoded.block.vehicles)

    // The oldest tile goes first once the cache is full; a Map iterates in
    // insertion order.
    if (this.tiles.size > TILE_CACHE_COUNT_MAX) {
      const [oldestUrl] = this.tiles.keys()
      this.tiles.delete(oldestUrl)
    }
  },

  // Draws the vehicles of the tiles in view of the shown indexes, and keeps
  // only the indexes and tiles of the shown fetches.
  draw({shown, generation, viewBounds}) {
    if (generation !== this.generation) {
      return
    }

    const features = []
    const shownUrls = new Set()

    for (const entry of shown) {
      shownUrls.add(entry.url)
      const tileUrls = this.urlsInView({entry, viewBounds, isHeld: isHeldNone})

      for (const url of tileUrls) {
        const vehicles = this.tiles.get(url)
        const {fetchedAtMs} = this.indexes.get(entry.url)

        // A tile whose read failed is left out until the next refresh.
        if (vehicles !== undefined) {
          for (const vehicle of vehicles) {
            features.push(vehicleFeature({vehicle, operatorName: entry.operator_name, fetchedAtMs}))
          }
        }
      }
    }

    this.forgetUnshown(shownUrls)
    this.collection = {type: "FeatureCollection", features}
    const source = this.map.getSource(SOURCE_NAME)

    // A map whose style is being set anew has no source until the style
    // has loaded, and adds it with this collection.
    if (source !== undefined) {
      source.setData(this.collection)
    }
  },

  forgetUnshown(shownUrls) {
    for (const url of this.indexes.keys()) {
      if (!shownUrls.has(url)) {
        this.indexes.delete(url)
      }
    }

    for (const url of this.tiles.keys()) {
      const directory = url.slice(0, url.lastIndexOf("/") + 1)
      let isShown = false

      for (const shownUrl of shownUrls) {
        isShown = isShown || shownUrl.startsWith(directory)
      }

      if (!isShown) {
        this.tiles.delete(url)
      }
    }
  },

  openPopup(event) {
    const [feature] = event.features
    const content = popupContent({properties: feature.properties, formLabels: this.formLabels})

    const popup = new this.maplibre.Popup({className: RIDER_POPUP_CLASS_NAME})
      .setLngLat(feature.geometry.coordinates)
      .setDOMContent(content)

    popup.on("close", announceRiderPopupChange)
    popup.addTo(this.map)
    announceRiderPopupChange()
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
  }
}

// The hook of the Filter tab's control. The rider's choice is kept in the
// browser, and a page that mounts or connects again with the layer kept on
// turns it on with the server, which holds the layer for the page's
// process alone.
export const SharedVehicleToggle = {
  mounted() {
    this.input = this.el.querySelector("input[type=checkbox]")

    this.input.addEventListener("change", () => {
      const shown = this.input.checked
      storedSettings.writeSharedVehiclesShown(shown)
      this.sendShown(shown)
    })

    this.restore()
  },

  reconnected() {
    this.restore()
  },

  restore() {
    const isKeptOn = storedSettings.readSharedVehiclesShown()

    if (isKeptOn) {
      this.sendShown(true)
    }
  },

  sendShown(shown) {
    if (shown) {
      this.pushEvent(this.el.dataset.showEvent, {})
    } else {
      this.pushEvent(this.el.dataset.hideEvent, {})
    }
  }
}
