import {READY_EVENT_NAME} from "./basemap"
import {placePopups} from "./popup_placement"
import {
  announceRiderPopupChange,
  riderPopupBoxes,
  RIDER_POPUP_CHANGE_EVENT_NAME,
  RIDER_POPUP_CLASS_NAME
} from "./rider_popups"
import {alertLines} from "./service_alerts"
import {compactPopupContent} from "./route_chips"
import {appendParagraph, writeArrivals} from "./stop_arrivals"
import {
  addFavorite,
  CHANGE_EVENT_NAME as FAVORITE_CHANGE_EVENT_NAME,
  favoriteCountMax,
  favoritesFullText,
  removeFavorite,
  storedFavorites
} from "./favorite_stop"
import {holdStop, POPUP_HOLDER, releaseStop} from "./stop_holds"
import {
  addSource,
  CHANGE_EVENT_NAME,
  filterProperties,
  SOURCE_NAME,
  FilterKind,
  setLayerFilter,
  stopFilter,
  STOP_LAYER_NAME
} from "./route_stop_tiles"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"

// The layer a stop's marker is drawn in.
export const MARKER_LAYER_NAME = "stop-markers"
// The zoom from which a street's stops stand apart; below it the stops of a
// region cover its routes.
const ZOOM_MIN = 14
const MARKER_RADIUS_PIXELS = 7
const MARKER_COLOR = "#ffffff"
const MARKER_STROKE_COLOR = "#334155"
const MARKER_STROKE_WIDTH_PIXELS = 2
const LABEL_LAYER_NAME = "stop-markers-label"
const labelFont = ["Noto Sans Medium"]
const LABEL_TEXT_SIZE_PIXELS = 11
const labelTextOffsetEms = [0, 1]
const LABEL_TEXT_WIDTH_EMS_MAX = 12
const LABEL_TEXT_COLOR = "#334155"
const LABEL_HALO_COLOR = "#ffffff"
const LABEL_HALO_WIDTH_PIXELS = 1.5
const hasLabel = ["!=", ["get", "label"], ""]
// The zoom from which a screen holds few enough stops that their popups
// stand apart.
const AUTO_OPEN_ZOOM_MIN = 16
// The room between two popups, and between a popup and a rider's.
const POPUP_GAP_PIXELS = 4
// MapLibre names the edge of a popup that touches its point, which is the
// edge across from the side of the point the popup stands on.
const anchorBySide = {above: "bottom", below: "top", left: "right", right: "left"}
// The side a popup stands on while it is only measured.
const MEASURED_SIDE = "above"
const NOT_SUPPLIED = "Not supplied"
const TITLE_CLASS_NAME = "popup-title"
const FAVORITE_BUTTON_CLASS_NAME = "mt-1 text-left underline"
const FAVORITE_TEXT = "★ Your favorite stop"
const NOT_FAVORITE_TEXT = "☆ Make this your favorite stop"
// A compact stop popup shows as many route numbers as the stop's label does.
const CHIP_COUNT_MAX = 4

// A stop as its feature in the tile archive holds it: its position, and the
// texts its popup shows, the routes and the agencies each one text. A text
// the source does not supply is absent from the feature. The feature holds
// its routes' identifiers with a comma before, between, and after them.
function stopFromFeature({geometry, properties}) {
  const [lon, lat] = geometry.coordinates

  return {
    id: properties.stopId,
    lon,
    lat,
    name: properties.name,
    code: properties.code,
    direction: properties.direction,
    routes: properties.routes,
    agencies: properties.agencies,
    routeIds: routeIdsOf(properties.routeIds),
    routeChips: routeChips(properties.routeChips)
  }
}

function isRouteId(routeId) {
  return routeId !== ""
}

function routeIdsOf(text) {
  const isAbsent = text === undefined || text === null

  if (isAbsent) {
    return []
  }

  const parts = text.split(",")
  return parts.filter(isRouteId)
}

// The feature holds its route chips as a JSON list of name and color pairs.
// An archive built before the feature held them gives a stop no chips.
function routeChips(text) {
  if (typeof text === "string") {
    const pairs = JSON.parse(text)
    return Array.from(pairs, routeChip)
  } else {
    return []
  }
}

function routeChip([name, color]) {
  return {name, color}
}

// The stops drawn in the view of `map`, by identifier. A stop near a tile's
// edge is returned by each tile that holds it, and comes out once here.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#queryrenderedfeatures — checked 2026-10-14
function renderedStops(map) {
  const stopsById = new Map()

  for (const feature of map.queryRenderedFeatures({layers: [MARKER_LAYER_NAME]})) {
    stopsById.set(feature.properties.stopId, stopFromFeature(feature))
  }

  return stopsById
}

// The first marker layer of the vehicles in the style, which the stops go
// under, or undefined while the vehicles have none.
function firstVehicleLayerName(map) {
  return vehicleMarkerLayerNames.find((layerName) => map.getLayer(layerName) !== undefined)
}

// The filter of the label layer: a stop with a label, of the kept routes.
function labelFilter() {
  const kept = stopFilter()

  if (kept.kind === FilterKind.none) {
    return hasLabel
  } else {
    return ["all", hasLabel, kept.filter]
  }
}

// The stops whose popups are open by themselves in a view at `zoom` that
// shows the stops of `visibleStopIds`: all of them in a view zoomed in
// close that shows at most `countMax`, and none in any other view.
export function autoOpenStopIds({zoom, visibleStopIds, countMax}) {
  const isZoomedIn = zoom >= AUTO_OPEN_ZOOM_MIN
  const opensAll = isZoomedIn && visibleStopIds.length <= countMax

  if (opensAll) {
    return visibleStopIds
  } else {
    return []
  }
}

function suppliedText(value) {
  const isSupplied = typeof value === "string" && value !== ""

  if (isSupplied) {
    return value
  } else {
    return NOT_SUPPLIED
  }
}

// A popup's content is built as text nodes: a stop's texts come from
// outside the application and are never parsed as HTML. The current alerts
// of the stop's routes, those of a route as a whole and those that name the
// stop, stand under its texts.
function popupContent(stop) {
  const lines = [
    stop.name,
    `Stop code: ${suppliedText(stop.code)}`,
    `Direction: ${suppliedText(stop.direction)}`,
    `Routes: ${suppliedText(stop.routes)}`,
    `Agencies: ${suppliedText(stop.agencies)}`
  ]
  const content = document.createElement("div")

  for (const line of lines) {
    appendParagraph(content, line)
  }

  for (const alertLine of alertLines({routeIds: stop.routeIds, stopId: stop.id})) {
    content.append(alertLine)
  }

  content.firstElementChild.className = TITLE_CLASS_NAME
  return content
}

// A popup's content with the element its stop's arrivals are written into,
// which says that it is waiting for them.
function popupElements(stop) {
  const details = popupContent(stop)
  const favoriteButton = favoriteButtonOf(stop)
  const arrivalsElement = document.createElement("div")
  writeArrivals(arrivalsElement, {status: "waiting"})
  details.append(favoriteButton, arrivalsElement)

  const content = compactPopupContent({
    chips: stop.routeChips,
    countMax: CHIP_COUNT_MAX,
    emptyText: suppliedName(stop),
    label: `${suppliedName(stop)}: show details`,
    details
  })

  return {content, favoriteButton, arrivalsElement}
}

function isFavoriteStop(stopId) {
  return storedFavorites().some((favorite) => favorite.stopId === stopId)
}

// The button that makes a popup's stop one of the rider's favorites, or
// removes it when it is one already. A stop the source names no name for is
// stored under its identifier. A rider with every favorite taken removes one
// before adding another.
function favoriteButtonOf(stop) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = FAVORITE_BUTTON_CLASS_NAME
  button.addEventListener("click", () => {
    if (isFavoriteStop(stop.id)) {
      removeFavorite(stop.id)
    } else {
      addFavorite({stopId: stop.id, name: suppliedName(stop)})
    }
  })

  const shown = favoriteButtonState({stopId: stop.id, favorites: storedFavorites()})
  button.textContent = shown.text
  button.disabled = shown.disabled
  button.setAttribute("aria-pressed", shown.pressed)
  return button
}

function suppliedName(stop) {
  const isNamed = typeof stop.name === "string" && stop.name !== ""

  if (isNamed) {
    return stop.name
  } else {
    return stop.id
  }
}

// What a popup's favorite button of the stop `stopId` shows while the
// rider's favorites are `favorites`.
function favoriteButtonState({stopId, favorites}) {
  const isFavorite = favorites.some((favorite) => favorite.stopId === stopId)
  const isFull = isFavorite === false && favorites.length >= favoriteCountMax()
  let text = NOT_FAVORITE_TEXT

  if (isFavorite) {
    text = FAVORITE_TEXT
  } else if (isFull) {
    text = favoritesFullText(favoriteCountMax())
  }

  return {text, disabled: isFull, pressed: String(isFavorite)}
}

// The options of a stop's popup. One that opens by itself stands on the
// side it is given, stays through a click on the map, and leaves the
// keyboard's focus where the rider has it. One the rider opens is placed by
// MapLibre and closes on a click on the map.
function popupOptions({auto, side}) {
  if (auto) {
    return {anchor: anchorBySide[side], closeOnClick: false, focusAfterOpen: false}
  } else {
    return {className: RIDER_POPUP_CLASS_NAME, closeOnClick: true, focusAfterOpen: true}
  }
}

// The size of the box MapLibre draws around `content`, the content of a
// popup that is on a map.
function contentBoxSize(content) {
  const {width, height} = content.parentElement.getBoundingClientRect()
  return {width, height}
}

function largerSize(size, other) {
  return {width: Math.max(size.width, other.width), height: Math.max(size.height, other.height)}
}

// The hook of the element beside the map. It draws the stops layer of the
// route and stop tile archive on each map the basemap announces, so a map
// drawn anew for another archive shows them too, and keeps the stops to
// those of the routes the page's filter keeps. Its layers go under the
// vehicle markers' layers.
export const StopMarkers = {
  mounted() {
    // The stops drawn in the view as the map last came to rest.
    this.stopsById = new Map()
    this.map = null
    this.maplibre = null
    this.attached = false
    this.followTimer = null
    // The popup that is open for each stop, with its content, the element
    // its arrivals are written into, whether it opened by itself, and the
    // side of its stop it then stands on.
    this.openPopups = new Map()
    // The stops on screen whose popup the rider closed after it opened by
    // itself; such a popup stays closed until its stop leaves the screen.
    this.dismissedStopIds = new Set()
    // The largest size the popup of each stop on screen has had, which is
    // the room its stop is given. A popup grows when its arrivals come, and
    // a stop left closed for lack of that room stays closed while its popup
    // would open small and close again.
    this.popupSizes = new Map()
    this.tipLength = null
    this.zoom = null
    this.push = (event, payload) => { this.pushEvent(event, payload) }
    // The most stops on screen whose popups open by themselves, which the
    // page's element carries.
    this.autoOpenCountMax = Number(this.el.dataset.autoOpenCountMax)

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.maplibre = null
      this.attached = false
      this.zoom = null
      this.tipLength = null
      this.stopsById.clear()
      this.dismissedStopIds.clear()
      this.popupSizes.clear()

      // A popup belongs to the map it was opened on.
      this.closePopups([...this.openPopups.keys()])

      // The map takes sources and layers once its style has loaded.
      map.once("load", () => {
        this.map = map
        this.maplibre = maplibre
        map.on("idle", () => { this.followView() })
        this.attach()
      })
    }

    this.onChange = () => {
      if (this.map === null) {
        return
      } else if (this.attached) {
        setLayerFilter({map: this.map, layerName: MARKER_LAYER_NAME, layerFilter: stopFilter()})
        this.map.setFilter(LABEL_LAYER_NAME, labelFilter())
      } else {
        this.attach()
      }
    }

    this.onRiderPopupChange = () => { this.scheduleFollow() }

    // A favorite added from one popup, or removed from the panel, changes
    // the button of every open popup.
    this.onFavoriteChange = (event) => {
      const {favorites} = event.detail

      for (const [stopId, open] of this.openPopups) {
        const shown = favoriteButtonState({stopId, favorites})
        open.favoriteButton.textContent = shown.text
        open.favoriteButton.disabled = shown.disabled
        open.favoriteButton.setAttribute("aria-pressed", shown.pressed)
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.addEventListener(RIDER_POPUP_CHANGE_EVENT_NAME, this.onRiderPopupChange)
    window.addEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)

    // Arrivals of a stop whose popup has closed are dropped.
    this.handleEvent("stop-arrivals:arrivals", (shown) => {
      const open = this.openPopups.get(shown.stop_id)

      if (open !== undefined) {
        writeArrivals(open.arrivalsElement, shown)
        // The popup has another size with these lines.
        this.scheduleFollow()
      }
    })
  },

  // The page that connects again knows nothing of the stops this hook has
  // open, and is told them again.
  reconnected() {
    for (const stopId of this.openPopups.keys()) {
      this.pushEvent("stop-arrivals:open", {stop_id: stopId})
    }
  },

  // Opens a stop's popup and tells the page, which answers with the stop's
  // arrivals and sends them again whenever they change, until the popup
  // closes and nothing else holds the stop.
  // `auto` says the popup opens by itself, for a view that shows few stops,
  // and `side` is then the side of its stop it stands on; a popup the rider
  // opens has a null `side`.
  openPopup({stop, auto, side}) {
    const {content, favoriteButton, arrivalsElement} = popupElements(stop)
    const open = {popup: null, content, favoriteButton, arrivalsElement, auto, side, closedByRider: true}

    this.openPopups.set(stop.id, open)
    this.showPopup({stop, open})
    holdStop({pushEvent: this.push, stopId: stop.id, holder: POPUP_HOLDER})

    if (auto === false) {
      announceRiderPopupChange()
    }
  },

  // Puts the popup of `open` on the map, on the side `open` names.
  showPopup({stop, open}) {
    const stopId = stop.id
    const popup = new this.maplibre.Popup(popupOptions(open))
      .setLngLat([stop.lon, stop.lat])
      .setDOMContent(open.content)

    // A popup opened anew for a stop, or put on another side of it, takes
    // the stop's place before the earlier one closes, and the earlier one's
    // closing then changes nothing.
    popup.on("close", () => {
      const isCurrentOpen = this.openPopups.get(stopId) === open
      const isCurrentPopup = isCurrentOpen && open.popup === popup

      if (isCurrentPopup) {
        this.openPopups.delete(stopId)
        releaseStop({pushEvent: this.push, stopId, holder: POPUP_HOLDER})

        if (open.auto) {
          if (open.closedByRider) {
            this.dismissedStopIds.add(stopId)
          }
        } else {
          announceRiderPopupChange()
        }
      }
    })

    open.popup = popup
    popup.addTo(this.map)
  },

  // Puts an open popup on another side of its stop. The stop stays open
  // for the page, and the popup keeps its content.
  movePopup({stop, open, side}) {
    const earlier = open.popup
    open.side = side
    this.showPopup({stop, open})
    earlier.remove()
  },

  // The size of the content box of a stop's popup and the length of a
  // popup's tip, read from a popup that is on the map only while it is
  // measured and that the page is told nothing of.
  measuredPopup(stop) {
    const {content} = popupElements(stop)
    const popup = new this.maplibre.Popup(popupOptions({auto: true, side: MEASURED_SIDE}))
      .setLngLat([stop.lon, stop.lat])
      .setDOMContent(content)
      .addTo(this.map)
    const size = contentBoxSize(content)
    const tipLength = popup.getElement().getBoundingClientRect().height - size.height

    popup.remove()
    return {size, tipLength}
  },

  // The room a stop's popup is given: the largest size it has had since its
  // stop came on screen.
  popupSize(stop) {
    const open = this.openPopups.get(stop.id)
    const kept = this.popupSizes.get(stop.id)
    let size

    if (open === undefined) {
      if (kept === undefined) {
        const measured = this.measuredPopup(stop)
        size = measured.size
        this.tipLength = measured.tipLength
      } else {
        size = kept
      }
    } else {
      const shown = contentBoxSize(open.content)

      if (kept === undefined) {
        size = shown
      } else {
        size = largerSize(shown, kept)
      }
    }

    this.popupSizes.set(stop.id, size)
    return size
  },

  // The side of its stop on which the popup of each stop of `stopIds`
  // stands, so that no two of them cross and none crosses a rider's popup.
  // A stop whose popup has no such side is left out.
  popupSides(stopIds) {
    if (stopIds.length === 0) {
      return new Map()
    }

    const popups = Array.from(stopIds, (stopId) => {
      const stop = this.stopsById.get(stopId)
      const point = this.map.project([stop.lon, stop.lat])

      // MapLibre draws a popup at a whole pixel.
      return {id: stopId, point: {x: Math.round(point.x), y: Math.round(point.y)}, size: this.popupSize(stop)}
    })
    const container = this.map.getContainer()

    if (this.tipLength === null) {
      throw new Error("a popup's size is known before the length of a popup's tip")
    }

    return placePopups({
      popups,
      obstacles: riderPopupBoxes(this.map),
      view: {width: container.clientWidth, height: container.clientHeight},
      tipLength: this.tipLength,
      gapPixels: POPUP_GAP_PIXELS
    })
  },

  // Closes the popups of the stops of `stopIds` as the hook's own doing,
  // which dismisses none of them.
  closePopups(stopIds) {
    for (const stopId of stopIds) {
      const open = this.openPopups.get(stopId)

      if (open !== undefined) {
        open.closedByRider = false
        open.popup.remove()
      }
    }
  },

  // Brings the open popups in line with the map's view: a view zoomed out
  // from, to below the zoom where popups open by themselves, closes every
  // popup, and the popups that opened by themselves are those of the stops
  // the view opens now, less the ones the rider closed, the ones the rider
  // opened, and the ones with no side of their stop to stand on.
  followView() {
    if (this.map === null) {
      return
    }

    const zoom = this.map.getZoom()
    const zoomedOut = this.zoom !== null && zoom < this.zoom
    this.zoom = zoom

    const isZoomedOutPastAutoOpen = zoomedOut && zoom < AUTO_OPEN_ZOOM_MIN

    if (isZoomedOutPastAutoOpen) {
      this.closePopups([...this.openPopups.keys()])
    }

    // Below the zoom that draws stops, none is on screen.
    const drawsStops = this.attached && zoom >= ZOOM_MIN

    if (drawsStops) {
      this.stopsById = renderedStops(this.map)
    } else {
      this.stopsById = new Map()
    }

    const visibleStopIds = [...this.stopsById.keys()]
    const visible = new Set(visibleStopIds)

    for (const stopId of [...this.dismissedStopIds]) {
      if (visible.has(stopId) === false) {
        this.dismissedStopIds.delete(stopId)
      }
    }

    for (const stopId of [...this.popupSizes.keys()]) {
      if (visible.has(stopId) === false) {
        this.popupSizes.delete(stopId)
      }
    }

    const wanted = autoOpenStopIds({zoom, visibleStopIds, countMax: this.autoOpenCountMax})
      .filter((stopId) => this.opensByItself(stopId))
    const sidesByStop = this.popupSides(wanted)

    // The closings go first, so the page never holds more stops open than
    // the server keeps for it.
    const closing = []

    for (const [stopId, open] of this.openPopups) {
      const isUnplacedAuto = open.auto && sidesByStop.has(stopId) === false

      if (isUnplacedAuto) {
        closing.push(stopId)
      }
    }

    this.closePopups(closing)

    for (const [stopId, side] of sidesByStop) {
      const stop = this.stopsById.get(stopId)
      const open = this.openPopups.get(stopId)

      if (open === undefined) {
        this.openPopup({stop, auto: true, side})
      } else if (open.side !== side) {
        this.movePopup({stop, open, side})
      }
    }
  },

  // Whether a stop the view opens gets a popup that opens by itself: one
  // whose popup the rider neither closed nor opened.
  opensByItself(stopId) {
    const open = this.openPopups.get(stopId)
    const openedByRider = open !== undefined && open.auto === false

    return this.dismissedStopIds.has(stopId) === false && openedByRider === false
  },

  // Follows the view once the events that are being handled are done, so a
  // popup that closes inside `followView` starts no second run inside it.
  scheduleFollow() {
    if (this.followTimer === null) {
      this.followTimer = window.setTimeout(() => {
        this.followTimer = null
        this.followView()
      }, 0)
    }
  },

  // Adds the layers, once the page has an archive to draw them from.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    map.addLayer({
      id: MARKER_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      "source-layer": STOP_LAYER_NAME,
      minzoom: ZOOM_MIN,
      ...filterProperties(stopFilter()),
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": MARKER_COLOR,
        "circle-stroke-color": MARKER_STROKE_COLOR,
        "circle-stroke-width": MARKER_STROKE_WIDTH_PIXELS
      }
    }, firstVehicleLayerName(map))

    // A label is left out where it would cover another label, so a crowded
    // street shows the labels of some of its stops.
    map.addLayer({
      id: LABEL_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      "source-layer": STOP_LAYER_NAME,
      minzoom: ZOOM_MIN,
      filter: labelFilter(),
      layout: {
        "text-field": ["get", "label"],
        "text-font": labelFont,
        "text-size": LABEL_TEXT_SIZE_PIXELS,
        "text-anchor": "top",
        "text-offset": labelTextOffsetEms,
        "text-max-width": LABEL_TEXT_WIDTH_EMS_MAX,
        "text-allow-overlap": false
      },
      paint: {
        "text-color": LABEL_TEXT_COLOR,
        "text-halo-color": LABEL_HALO_COLOR,
        "text-halo-width": LABEL_HALO_WIDTH_PIXELS
      }
    }, firstVehicleLayerName(map))

    // A click on a stop whose popup opened by itself leaves that popup as
    // it is.
    map.on("click", MARKER_LAYER_NAME, (event) => {
      const stop = stopFromFeature(event.features[0])
      const stopId = stop.id
      const open = this.openPopups.get(stopId)

      const isRiderOpenable = open === undefined || open.auto === false

      if (isRiderOpenable) {
        this.dismissedStopIds.delete(stopId)
        this.openPopup({stop, auto: false, side: null})
      }
    })

    map.on("mouseenter", MARKER_LAYER_NAME, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", MARKER_LAYER_NAME, () => { map.getCanvas().style.cursor = "" })

    this.attached = true
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.removeEventListener(RIDER_POPUP_CHANGE_EVENT_NAME, this.onRiderPopupChange)
    window.removeEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    window.clearTimeout(this.followTimer)
  }
}
