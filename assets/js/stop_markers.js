import {assertCondition} from "./assert.js"
import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {currentTheme} from "./color_theme"
import {placePopups} from "./popup_placement"
import {
  announceRiderPopupChange,
  riderPopupBoxes,
  RIDER_POPUP_CHANGE_EVENT_NAME,
  RIDER_POPUP_CLASS_NAME
} from "./rider_popups"
import {compactPopupContent, nameCloseButton, writeChipNote} from "./route_chips"
import {NEEDS_CONNECTION_CLASS_NAME, markArrivalNote, nextArrivalTimeText, writeArrivals} from "./stop_arrivals"
import {CHANGE_EVENT_NAME as FAVORITE_CHANGE_EVENT_NAME, storedFavorites} from "./favorite_stop"
import {holdStop, POPUP_HOLDER, releaseStop, VIEW_HOLDER} from "./stop_holds"
import {AUTO_OPEN_ZOOM_MIN, autoOpenCountMax} from "./open_stop_budget"
import {
  CHANGE_EVENT_NAME as DETAIL_CHANGE_EVENT_NAME,
  DetailKind,
  showDetail,
  showsDetail
} from "./panel_detail"
import {stopViewElements, suppliedName, writeFavoriteButton} from "./stop_view"
import {isPicking, pickStop} from "./trip_ends"
import {revealOnMap} from "./panel_sheet"
import {pageEvents} from "./page_events"
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
import {mapColors} from "./theme"

// The layer a stop's marker is drawn in.
export const MARKER_LAYER_NAME = "stop-markers"
// The zoom from which a street's stops stand apart; below it the stops of a
// region cover its routes.
const ZOOM_MIN = 14
const MARKER_RADIUS_PIXELS = 7
const MARKER_STROKE_WIDTH_PIXELS = 2
const LABEL_LAYER_NAME = "stop-markers-label"
const labelFont = ["Noto Sans Medium"]
const LABEL_TEXT_SIZE_PIXELS = 11
const labelTextOffsetEms = [0, 1]
const LABEL_TEXT_WIDTH_EMS_MAX = 12
const LABEL_HALO_WIDTH_PIXELS = 1.5
const hasLabel = ["!=", ["get", "label"], ""]
// The room between two popups, and between a popup and a rider's.
const POPUP_GAP_PIXELS = 4
// MapLibre names the edge of a popup that touches its point, which is the
// edge across from the side of the point the popup stands on.
const anchorBySide = {above: "bottom", below: "top", left: "right", right: "left"}
// The side a popup stands on while it is only measured.
const MEASURED_SIDE = "above"
// A popup is measured with the longest next arrival it shows, so the room
// its stop is given holds the arrival that comes later.
const MEASURED_NOTE_TEXT = "99 min"
// A compact stop popup shows as many route numbers as the stop's label does.
const CHIP_COUNT_MAX = 4
// The stop the details view shows is marked on the map at every zoom, from
// a source of its own, since the archive holds stops from zoom 14 alone.
const SELECTED_SOURCE_NAME = "stop-selected"
const SELECTED_HALO_LAYER_NAME = "stop-selected-halo"
const SELECTED_RING_LAYER_NAME = "stop-selected-ring"
const SELECTED_COLOR = "#16a34a"
const SELECTED_HALO_RADIUS_PIXELS = 12
const SELECTED_HALO_OPACITY = 0.25
const SELECTED_RING_STROKE_WIDTH_PIXELS = 3
// The class of the popup of the stop the details view shows.
const SELECTED_POPUP_CLASS_NAME = "popup-selected"

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

// A popup's compact content: the stop's first route numbers and, in the
// note beside them, its next arrival once the page has sent its arrivals.
// A click on it hands the stop to `onSelect`. The next arrival is a live
// one, so the stylesheet hides the note while the page is offline.
function popupElements({stop, noteText, onSelect}) {
  const elements = compactPopupContent({
    chips: stop.routeChips,
    countMax: CHIP_COUNT_MAX,
    emptyText: suppliedName(stop),
    noteText,
    itemName: suppliedName(stop),
    action: "show the stop",
    onSelect
  })

  elements.note.classList.add(NEEDS_CONNECTION_CLASS_NAME)
  return elements
}

function favoriteStopId(favorite) {
  return favorite.stopId
}

// The collection the selected stop's source draws: the stop, or nothing.
function selectedCollection(stop) {
  const features = []

  if (stop !== null) {
    features.push({type: "Feature", geometry: {type: "Point", coordinates: [stop.lon, stop.lat]}, properties: {}})
  }

  return {type: "FeatureCollection", features}
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
// drawn anew for another archive shows them too, draws them again in the
// theme of a map whose style is set anew, and keeps the stops to those of
// the routes the page's filter keeps. Its layers go under the vehicle
// markers' layers.
export const StopMarkers = {
  mounted() {
    // The stops drawn in the view as the map last came to rest.
    this.stopsById = new Map()
    this.map = null
    this.maplibre = null
    this.attached = false
    this.clicksAttached = false
    this.followTimer = null
    // The popup that is open for each stop, with its content, the note its
    // next arrival is written into, whether it opened by itself, and the
    // side of its stop it then stands on.
    this.openPopups = new Map()
    // The stop the details view shows, with its favorite button and the
    // element its arrivals are written into, or null while it shows none.
    this.view = null
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
    this.events = pageEvents(this)
    this.push = (name, payload) => { this.events.push({name, payload}) }
    // The most stops on screen whose popups open by themselves, which the
    // page's element carries.
    this.autoOpenCountMax = Number(this.el.dataset.autoOpenCountMax)

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.maplibre = null
      this.attached = false
      this.clicksAttached = false
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

    // A style set anew holds none of the layers, nor the source. The
    // popups stand over the map and stay open.
    this.onRestyled = (event) => {
      if (event.detail.map === this.map) {
        this.attached = false
        this.attach()
      }
    }

    // A favorite added from the stop view, or removed from the panel,
    // changes the view's button.
    this.onFavoriteChange = (event) => {
      if (this.view !== null) {
        const {favorites} = event.detail
        writeFavoriteButton({button: this.view.favoriteButton, stopId: this.view.stop.id, favorites})
      }
    }

    // The view moving to a vehicle, or closing, lets go of its stop.
    this.onDetailChange = () => {
      const isViewLeft = this.view !== null && showsDetail({kind: DetailKind.stop, id: this.view.stop.id}) === false

      if (isViewLeft) {
        const stopId = this.view.stop.id
        this.view = null
        releaseStop({pushEvent: this.push, stopId, holder: VIEW_HOLDER})
        this.markSelected()
        this.scheduleFollow()
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.addEventListener(RIDER_POPUP_CHANGE_EVENT_NAME, this.onRiderPopupChange)
    window.addEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    window.addEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)

    // Arrivals of a stop with neither a popup nor the view are dropped.
    this.events.handle("stop-arrivals:arrivals", (shown) => {
      const open = this.openPopups.get(shown.stop_id)
      const isViewStop = this.view !== null && this.view.stop.id === shown.stop_id

      if (open !== undefined) {
        writeChipNote(open.note, nextArrivalTimeText(shown))
        markArrivalNote({note: open.note, shown})
        // The popup has another size with its next arrival.
        this.scheduleFollow()
      }

      if (isViewStop) {
        writeArrivals(this.view.arrivalsElement, shown)
      }
    })

    // The page that is live again knows nothing of the stops this hook has
    // open, and is told them again.
    this.events.whenLive(() => { this.sendOpenStops() })
  },

  sendOpenStops() {
    const stopIds = new Set(this.openPopups.keys())

    if (this.view !== null) {
      stopIds.add(this.view.stop.id)
    }

    for (const stopId of stopIds) {
      this.events.push({name: "stop-arrivals:open", payload: {stop_id: stopId}})
    }
  },

  // Shows `stop` in the details view and holds it for its arrivals, which
  // the page answers with, and lets go of the stop the view showed before.
  // The stop is marked on the map while the view shows it. The stop the
  // view shows already is shown again as it is, which expands a collapsed
  // sheet.
  selectStop(stop) {
    const isSameStop = this.view !== null && this.view.stop.id === stop.id

    if (isSameStop) {
      showDetail({kind: DetailKind.stop, id: stop.id, title: suppliedName(stop), content: this.view.content})
      this.revealStop(stop)
      return
    }

    const {content, favoriteButton, arrivalsElement} = stopViewElements(stop)
    const earlier = this.view
    this.view = {stop, content, favoriteButton, arrivalsElement}

    if (earlier !== null) {
      releaseStop({pushEvent: this.push, stopId: earlier.stop.id, holder: VIEW_HOLDER})
    }

    holdStop({pushEvent: this.push, stopId: stop.id, holder: VIEW_HOLDER})
    showDetail({kind: DetailKind.stop, id: stop.id, title: suppliedName(stop), content})
    this.markSelected()
    this.revealStop(stop)
  },

  // Moves the map so the stop stands beside the expanded sheet.
  revealStop(stop) {
    if (this.map !== null) {
      revealOnMap({map: this.map, lngLat: [stop.lon, stop.lat]})
    }
  },

  // Marks the stop the view shows on the map and its popup, and unmarks
  // every other.
  markSelected() {
    let selected = null

    if (this.view !== null) {
      selected = this.view.stop
    }

    for (const [stopId, open] of this.openPopups) {
      const isSelected = selected !== null && selected.id === stopId
      open.popup.getElement().classList.toggle(SELECTED_POPUP_CLASS_NAME, isSelected)
    }

    // The map takes the source once the page has an archive to draw the
    // stops from.
    const hasSource = this.map !== null && this.map.getSource(SELECTED_SOURCE_NAME) !== undefined

    if (hasSource) {
      this.map.getSource(SELECTED_SOURCE_NAME).setData(selectedCollection(selected))
    }
  },

  // Opens a stop's popup and tells the page, which answers with the stop's
  // arrivals and sends them again whenever they change, until the popup
  // closes and nothing else holds the stop.
  // `auto` says the popup opens by itself, for a view that shows few stops,
  // and `side` is then the side of its stop it stands on; a popup the rider
  // opens has a null `side`.
  openPopup({stop, auto, side}) {
    const {content, note} = popupElements({stop, noteText: "", onSelect: () => { this.selectStop(stop) }})
    const open = {popup: null, content, note, auto, side, closedByRider: true}

    this.openPopups.set(stop.id, open)
    open.popup = this.showPopup({stop, open})
    holdStop({pushEvent: this.push, stopId: stop.id, holder: POPUP_HOLDER})

    if (auto === false) {
      announceRiderPopupChange()
    }
  },

  // Puts the popup of `open` on the map, on the side `open` names, and
  // returns it to be the popup `open` holds.
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

    popup.addTo(this.map)
    nameCloseButton({content: open.content, itemName: suppliedName(stop)})

    const isSelected = this.view !== null && this.view.stop.id === stopId
    popup.getElement().classList.toggle(SELECTED_POPUP_CLASS_NAME, isSelected)
    return popup
  },

  // Puts the open popup of `stop` on another side of it. The stop stays
  // open for the page, and the popup keeps its content.
  movePopup({stop, side}) {
    const open = this.openPopups.get(stop.id)
    const earlier = open.popup
    open.side = side
    open.popup = this.showPopup({stop, open})
    earlier.remove()
  },

  // The size of the content box of a stop's popup and the length of a
  // popup's tip, read from a popup that is on the map only while it is
  // measured and that the page is told nothing of.
  measuredPopup(stop) {
    const {content} = popupElements({stop, noteText: MEASURED_NOTE_TEXT, onSelect: () => { this.selectStop(stop) }})
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

    assertCondition(this.tipLength !== null, "a popup's size is known before the length of a popup's tip")

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

    // A style set anew holds the stops again once it has loaded, and the
    // popups stay as they are until then.
    const isRestyling = this.attached && this.map.getLayer(MARKER_LAYER_NAME) === undefined

    if (isRestyling) {
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

    const countMax = this.autoOpenCountMaxNow(visibleStopIds)
    const opened = autoOpenStopIds({zoom, visibleStopIds, countMax})
    const wanted = opened.filter((stopId) => this.opensByItself(stopId))
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
        this.movePopup({stop, side})
      }
    }
  },

  // The most popups that open by themselves for a view that shows the
  // stops of `visibleStopIds`, with the stop the details view holds.
  autoOpenCountMaxNow(visibleStopIds) {
    let detailStopId = null

    if (this.view !== null) {
      detailStopId = this.view.stop.id
    }

    const favoriteStopIds = Array.from(storedFavorites(), favoriteStopId)
    return autoOpenCountMax({countMax: this.autoOpenCountMax, detailStopId, visibleStopIds, favoriteStopIds})
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

  // Adds the layers, once the page has an archive to draw them from, in the
  // page's theme, and answers clicks on them, once for each map.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    const colors = mapColors(currentTheme())

    map.addLayer({
      id: MARKER_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      "source-layer": STOP_LAYER_NAME,
      minzoom: ZOOM_MIN,
      ...filterProperties(stopFilter()),
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": colors.stopFill,
        "circle-stroke-color": colors.stopStroke,
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
        "text-color": colors.stopLabel,
        "text-halo-color": colors.stopHalo,
        "text-halo-width": LABEL_HALO_WIDTH_PIXELS
      }
    }, firstVehicleLayerName(map))

    this.attachSelected()

    if (!this.clicksAttached) {
      this.attachClicks()
      this.clicksAttached = true
    }

    this.attached = true
  },

  // A map keeps the listeners of a layer while the layer is added again.
  attachClicks() {
    const map = this.map

    // A click on a stop shows it in the details view. A click on a stop
    // whose popup opened by itself leaves that popup as it is, and any
    // other opens the rider's popup. While the Trip tab waits for a stop,
    // the stop clicked is its end instead.
    map.on("click", MARKER_LAYER_NAME, (event) => {
      const stop = stopFromFeature(event.features[0])
      const stopId = stop.id

      if (isPicking()) {
        pickStop({stopId, name: suppliedName(stop)})
        return
      }
      const open = this.openPopups.get(stopId)

      const isRiderOpenable = open === undefined || open.auto === false

      if (isRiderOpenable) {
        this.dismissedStopIds.delete(stopId)
        this.openPopup({stop, auto: false, side: null})
      }

      this.selectStop(stop)
    })

    map.on("mouseenter", MARKER_LAYER_NAME, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", MARKER_LAYER_NAME, () => { map.getCanvas().style.cursor = "" })
  },

  // Adds the source and the layers that mark the stop the details view
  // shows, over the stops and under the vehicles.
  attachSelected() {
    const map = this.map
    let selected = null

    if (this.view !== null) {
      selected = this.view.stop
    }

    map.addSource(SELECTED_SOURCE_NAME, {type: "geojson", data: selectedCollection(selected)})

    map.addLayer({
      id: SELECTED_HALO_LAYER_NAME,
      type: "circle",
      source: SELECTED_SOURCE_NAME,
      paint: {
        "circle-radius": SELECTED_HALO_RADIUS_PIXELS,
        "circle-color": SELECTED_COLOR,
        "circle-opacity": SELECTED_HALO_OPACITY
      }
    }, firstVehicleLayerName(map))

    map.addLayer({
      id: SELECTED_RING_LAYER_NAME,
      type: "circle",
      source: SELECTED_SOURCE_NAME,
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": mapColors(currentTheme()).stopFill,
        "circle-stroke-color": SELECTED_COLOR,
        "circle-stroke-width": SELECTED_RING_STROKE_WIDTH_PIXELS
      }
    }, firstVehicleLayerName(map))
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.removeEventListener(RIDER_POPUP_CHANGE_EVENT_NAME, this.onRiderPopupChange)
    window.removeEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    window.removeEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
    window.clearTimeout(this.followTimer)
    this.events.release()
  }
}
