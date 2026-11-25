import {assertCondition, unreachable} from "#core/assert.js"
import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {currentTheme} from "./color_theme"
import {writeArrivals} from "./stop_arrivals"
import {shownAt} from "./arrival_countdown"
import {startArrivalTicker} from "./arrival_ticker"
import {CHANGE_EVENT_NAME as FAVORITE_CHANGE_EVENT_NAME} from "./favorite_stop"
import {holdStop, releaseStop, VIEW_HOLDER} from "./stop_holds"
import {
  CHANGE_EVENT_NAME as DETAIL_CHANGE_EVENT_NAME,
  DESELECT_EVENT_NAME,
  DetailKind,
  NO_PARENT,
  clearParentDetail,
  detailParent,
  showDetail,
  showsDetail,
  shownDetail
} from "./panel_detail"
import {chosenStopMark, stopListElement, stopViewElements, suppliedName, writeFavoriteButton, writeTripLine} from "./stop_view"
import {stopListTitle} from "./stop_text"
import {StopTapKind, stopTapOutcome} from "./map_selection"
import {DeviceKind, ENTRY_COUNT_MAX, HOVER_NONE_MEDIA_QUERY, TAP_TOLERANCE_PIXELS, deviceKind} from "./route_tap"
import {CHANGE_EVENT_NAME as CHOSEN_CHANGE_EVENT_NAME} from "./chosen_journey"
import {yourBusRow} from "./journey_stop_marks"
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
import {markerLayerNames as vehicleMarkerLayerNames, stackedLayerNames as vehicleStackedLayerNames} from "./vehicle_markers"
import {HitKind, overlayHitAt} from "./vehicle_overlay"
import {mapColors} from "./theme"
import {MapItemKind, OPEN_EVENT_NAME} from "./map_items"
import {selectionHaloPaint, selectionRingPaint} from "./selection_mark"
import {registerImageResolver} from "./style_images"
import {
  ARROW_SIZE_PIXELS,
  CHIPS_IMAGE_PREFIX,
  CURB_OFFSET_UNITS,
  ChipsImageKind,
  ICON_SIZE_AT_ZOOM_MIN,
  ICON_WHOLE_ZOOM,
  SIGN_SIZE_PIXELS,
  SIGN_ZOOM_MIN,
  chipFont,
  chipsImageSize,
  chipsOffsetCases,
  curbOffset,
  curbOffsetCases,
  directionAngleCases,
  drawChips,
  drawStopArrow,
  drawStopSign,
  parseChipsImageName,
  shownChips,
  signBox,
  southwardDirections
} from "./stop_marker_shapes"

// The layer a stop's marker is drawn in.
export const MARKER_LAYER_NAME = "stop-markers"
// The zoom from which a street's stops stand apart; below it the stops of a
// region cover its routes.
export const ZOOM_MIN = SIGN_ZOOM_MIN
const ARROW_LAYER_NAME = "stop-markers-arrow"
const LABEL_LAYER_NAME = "stop-markers-label"
const IMAGE_RESOLVER_KEY = "stop-markers"
const SIGN_IMAGE_PREFIX = "stop-sign-"
const ARROW_IMAGE_PREFIX = "stop-arrow-"
const IMAGE_PIXEL_RATIO = 2
const themes = ["light", "dark"]
// The sign, its arrow, and its chips are drawn smaller at zoom 14, where a
// street's stops first stand apart, and whole from zoom 16.
const iconSize = ["interpolate", ["linear"], ["zoom"], ZOOM_MIN, ICON_SIZE_AT_ZOOM_MIN, ICON_WHOLE_ZOOM, 1]
// The arrow's center stands this far ahead of the sign's, before it turns.
const ARROW_OFFSET_PIXELS = 17
// MapLibre turns an icon's offset with its `icon-rotate`, so the arrow's x
// is to the right of the stop's direction, where its sign stands.
const arrowOffsetPixels = [CURB_OFFSET_UNITS, -ARROW_OFFSET_PIXELS]
// The chips stand clear of the sign, and of an arrow on the same side.
const CHIPS_OFFSET_PIXELS = 13
const chipsBelowOffsetPixels = [0, CHIPS_OFFSET_PIXELS]
const signOffset = ["match", ["get", "direction"], ...curbOffsetCases(), ["literal", [0, 0]]]
const chipsOffset = ["match", ["get", "direction"], ...chipsOffsetCases(CHIPS_OFFSET_PIXELS), ["literal", chipsBelowOffsetPixels]]
// The selected stop's mark stands around the stop itself below zoom 14,
// where no sign is drawn, and around its sign from zoom 14.
const SIGN_ZOOM_STEP = 0.01
const ZOOM_BEFORE_SIGNS = ZOOM_MIN - SIGN_ZOOM_STEP
const hasChips = ["all", ["has", "routeChips"], ["!=", ["get", "routeChips"], "[]"]]
const hasCompassDirection = ["match", ["get", "direction"], ["N", "NE", "E", "SE", "S", "SW", "W", "NW"], true, false]
// The stop the details view shows is marked on the map at every zoom, from
// a source of its own, since the archive holds stops from zoom 14 alone.
const SELECTED_SOURCE_NAME = "stop-selected"
const SELECTED_HALO_LAYER_NAME = "stop-selected-halo"
const SELECTED_RING_LAYER_NAME = "stop-selected-ring"
// The radius of a stop's sign, which the mark stands around.
const HALVING_DIVISOR = 2
const SIGN_RADIUS_PIXELS = SIGN_SIZE_PIXELS / HALVING_DIVISOR

// A stop as its feature in the tile archive holds it: its position, and the
// texts its view shows, the routes and the agencies each one text. A text
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

// The lowest layer of the vehicles in the style, the selected vehicle's
// mark or its marker, which the stops go under, or undefined while the
// vehicles have none.
function firstVehicleLayerName(map) {
  return vehicleStackedLayerNames.find((layerName) => map.getLayer(layerName) !== undefined)
}

// Whether a vehicle stands at `point`, on the canvas over the map or in its
// layers. The vehicle stands above the stop, and its tap opens it.
function isVehicleAt({map, point}) {
  const hit = overlayHitAt({map, point})

  if (hit.kind === HitKind.found) {
    return true
  }

  const layers = vehicleMarkerLayerNames.filter((layerName) => map.getLayer(layerName) !== undefined)

  if (layers.length === 0) {
    return false
  }

  return map.queryRenderedFeatures(point, {layers}).length > 0
}

// How far from a stop's sign a tap on a sign still reaches it on a device
// of `kind`: a finger's reach on a device whose primary pointer cannot
// hover, and the sign itself under a pointer that hovers, which lands where
// it is aimed.
function tapRadiusPixels(kind) {
  if (kind === DeviceKind.touch) {
    return TAP_TOLERANCE_PIXELS
  }

  return 0
}

// A stop's feature as a candidate of `stopTapOutcome`, with its sign's box
// at `zoom` and whether its stop is one of `underTapIds`, the stops the map
// draws a sign of under the tap.
function tapCandidate({map, feature, zoom, underTapIds}) {
  const stopPoint = map.project(feature.geometry.coordinates)
  const box = signBox({stopPoint, direction: feature.properties.direction, zoom})
  const id = feature.properties.stopId
  return {id, item: feature, center: box.center, halfSize: box.halfSize, isUnderTap: underTapIds.has(id)}
}

function featureStopId(feature) {
  return feature.properties.stopId
}

// The signs drawn within reach of a tap at `point`: those under it for a
// radius of 0, and those in the square that holds every point within
// `radiusPixels` of it otherwise, which holds the point too.
function reachedFeatures({map, point, radiusPixels, underTap}) {
  if (radiusPixels === 0) {
    return underTap
  }

  const square = [[point.x - radiusPixels, point.y - radiusPixels], [point.x + radiusPixels, point.y + radiusPixels]]
  return map.queryRenderedFeatures(square, {layers: [MARKER_LAYER_NAME]})
}

// What a tap at `point` of `map` opens among the stop signs the map draws,
// by `stopTapOutcome`: none where the map draws no sign under the point, as
// `queryRenderedFeatures` reports it at the point, and otherwise one
// stop's feature, or a list of every sign within `radiusPixels` of it,
// nearest first.
function stopTapAt({map, point, radiusPixels}) {
  if (map.getLayer(MARKER_LAYER_NAME) === undefined) {
    return {kind: StopTapKind.none}
  }

  const underTap = map.queryRenderedFeatures(point, {layers: [MARKER_LAYER_NAME]})
  const underTapIdList = Array.from(underTap, featureStopId)
  const underTapIds = new Set(underTapIdList)
  const features = reachedFeatures({map, point, radiusPixels, underTap})
  const zoom = map.getZoom()
  const candidates = Array.from(features, (feature) => tapCandidate({map, feature, zoom, underTapIds}))
  return stopTapOutcome({candidates, point, radiusPixels, countMax: ENTRY_COUNT_MAX})
}

/** Whether `map` draws a stop's sign under `point`. */
export function isStopAt({map, point}) {
  const outcome = stopTapAt({map, point, radiusPixels: 0})
  return outcome.kind !== StopTapKind.none
}

function stopIdOf(stop) {
  return stop.id
}

// A pan or zoom of the rider's own, a move whose event carries the input
// event that started it, deselects a shown list of stops, and drops a list
// kept as the shown stop's parent, since the move can take its stops off
// screen.
function closeListOnRiderMove(event) {
  const isRiderMove = event.originalEvent !== undefined
  const isListMoved = isRiderMove && shownDetail().kind === DetailKind.stopList

  if (isListMoved) {
    window.dispatchEvent(new CustomEvent(DESELECT_EVENT_NAME))
  } else if (isRiderMove) {
    clearParentDetail()
  }
}

// The filter of a layer that draws the stops of the kept routes that meet
// `condition`.
function keptFilter(condition) {
  const kept = stopFilter()

  if (kept.kind === FilterKind.none) {
    return condition
  } else {
    return ["all", condition, kept.filter]
  }
}

// Draws the image named `id` for `map` where it is a stop's sign, arrow, or
// chips, and leaves any other name alone.
function addStopImage({map, id}) {
  const chips = parseChipsImageName(id)

  if (chips.kind === ChipsImageKind.chips) {
    const colors = mapColors(chips.theme)
    const shown = shownChips({chips: chips.chips, count: {fill: colors.chipCountFill, ink: colors.chipCountInk}})
    addDrawnImage({map, id, draw: (canvas) => { drawChips(canvas, {shown}) }, size: chipsSize(shown)})
    return
  }

  for (const theme of themes) {
    const colors = mapColors(theme)

    if (id === SIGN_IMAGE_PREFIX + theme) {
      const draw = (canvas) => { drawStopSign(canvas, {fill: colors.stopSignFill, ink: colors.stopSignInk}) }
      addDrawnImage({map, id, draw, size: {width: SIGN_SIZE_PIXELS, height: SIGN_SIZE_PIXELS}})
    } else if (id === ARROW_IMAGE_PREFIX + theme) {
      const draw = (canvas) => { drawStopArrow(canvas, {fill: colors.stopSignFill, halo: colors.stopSignInk}) }
      addDrawnImage({map, id, draw, size: {width: ARROW_SIZE_PIXELS, height: ARROW_SIZE_PIXELS}})
    }
  }
}

// The size of the image of the chips `shown`, measured in the chips' font.
function chipsSize(shown) {
  const context = document.createElement("canvas").getContext("2d")
  context.font = chipFont()
  return chipsImageSize({shown, measure: (text) => context.measureText(text).width})
}

// Adds to `map` the image `id` of `size`, in CSS pixels, that `draw` draws
// onto a canvas scaled to the image's pixel ratio.
function addDrawnImage({map, id, draw, size}) {
  const canvas = document.createElement("canvas")
  canvas.width = Math.ceil(size.width * IMAGE_PIXEL_RATIO)
  canvas.height = Math.ceil(size.height * IMAGE_PIXEL_RATIO)
  const context = canvas.getContext("2d")
  context.scale(IMAGE_PIXEL_RATIO, IMAGE_PIXEL_RATIO)
  draw(canvas)
  const image = context.getImageData(0, 0, canvas.width, canvas.height)
  map.addImage(id, image, {pixelRatio: IMAGE_PIXEL_RATIO})
}

// The collection the selected stop's source draws: the stop, or nothing.
function selectedCollection(stop) {
  const features = []

  if (stop !== null) {
    features.push({type: "Feature", geometry: {type: "Point", coordinates: [stop.lon, stop.lat]}, properties: {}})
  }

  return {type: "FeatureCollection", features}
}

// The selected stop's mark moved onto its sign: the sign's curb offset at
// the icon size of each zoom, since the offset is in icon units and the
// mark's translation in pixels.
function selectedTranslate(stop) {
  let offset = [0, 0]

  if (stop !== null) {
    offset = curbOffset(stop.direction)
  }

  const [x, y] = offset
  const offsetAtZoomMin = [x * ICON_SIZE_AT_ZOOM_MIN, y * ICON_SIZE_AT_ZOOM_MIN]
  return [
    "interpolate", ["linear"], ["zoom"],
    ZOOM_BEFORE_SIGNS, ["literal", [0, 0]],
    ZOOM_MIN, ["literal", offsetAtZoomMin],
    ICON_WHOLE_ZOOM, ["literal", offset]
  ]
}

// The hook of the element beside the map. It draws the stops layer of the
// route and stop tile archive on each map the basemap announces, so a map
// drawn anew for another archive shows them too, draws them again in the
// theme of a map whose style is set anew, and keeps the stops to those of
// the routes the page's filter keeps. Its layers go under the vehicle
// markers' layers. A tap on a stop selects it: it shows the stop in the
// details view, which holds the stop open for its arrivals while it shows
// it, and marks it on the map.
export const StopMarkers = {
  mounted() {
    this.map = null
    this.attached = false
    this.clicksAttached = false
    // The stop the details view shows, with its favorite button, the
    // element its arrivals are written into, and the answer it last got,
    // or null while the view shows none.
    this.view = null
    this.events = pageEvents(this)
    this.push = (name, payload) => { this.events.push({name, payload}) }
    this.arrivalCountMax = Number(this.el.dataset.arrivalCountMax)

    this.onBasemapReady = (event) => {
      const {map} = event.detail
      this.map = null
      this.attached = false
      this.clicksAttached = false

      // The map takes sources and layers once its style has loaded.
      map.once("load", () => {
        this.map = map
        this.attach()
      })
    }

    this.onChange = () => {
      if (this.map === null) {
        return
      } else if (this.attached) {
        setLayerFilter({map: this.map, layerName: MARKER_LAYER_NAME, layerFilter: stopFilter()})
        this.map.setFilter(ARROW_LAYER_NAME, keptFilter(hasCompassDirection))
        this.map.setFilter(LABEL_LAYER_NAME, keptFilter(hasChips))
      } else {
        this.attach()
      }
    }

    // A style set anew holds none of the layers, nor the source.
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
        writeFavoriteButton({button: this.view.favoriteButton, note: this.view.note, stopId: this.view.stop.id, favorites})
      }
    }

    // The view moving to another item, or closing, lets go of its stop and
    // unmarks it.
    this.onDetailChange = () => {
      const isViewLeft = this.view !== null && showsDetail({kind: DetailKind.stop, id: this.view.stop.id}) === false

      if (isViewLeft) {
        const stopId = this.view.stop.id
        this.view = null
        releaseStop({pushEvent: this.push, stopId, holder: VIEW_HOLDER})
        this.markSelected()
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)

    // A journey chosen, changed, or cleared rewrites the view's trip line
    // and the mark on its arrivals.
    this.onChosenChange = () => {
      if (this.view !== null) {
        writeTripLine({line: this.view.tripLine, stopId: this.view.stop.id})
        this.tickArrivals(Date.now())
      }
    }

    window.addEventListener(CHOSEN_CHANGE_EVENT_NAME, this.onChosenChange)
    window.addEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.addEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    window.addEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)

    // The list of what is in view opens a stop as a tap on its marker does.
    this.onItemOpen = (event) => {
      const {kind, feature} = event.detail
      const isStop = kind === MapItemKind.stop && this.map !== null

      if (isStop) {
        this.openStop(stopFromFeature(feature))
      }
    }

    window.addEventListener(OPEN_EVENT_NAME, this.onItemOpen)

    // Arrivals of any stop but the one the view shows are dropped.
    this.events.handle("stop-arrivals:arrivals", (shown) => {
      const isViewStop = this.view !== null && this.view.stop.id === shown.stop_id

      if (isViewStop) {
        this.view.shown = shown
        this.writeViewArrivals(Date.now())
      }
    })

    this.stopTicker = startArrivalTicker((nowMs) => { this.tickArrivals(nowMs) })

    // The page that is live again knows nothing of the stop this hook holds
    // open, and is told it again.
    this.events.whenLive(() => { this.sendOpenStop() })
  },

  // Writes the view's arrivals as of `nowMs`, from the answer the view last got.
  writeViewArrivals(nowMs) {
    const shown = shownAt({shown: this.view.shown, nowMs, countMax: this.arrivalCountMax})
    const yourBus = yourBusRow({mark: chosenStopMark(this.view.stop.id), shown})
    writeArrivals({element: this.view.arrivalsElement, shown, withKey: true, yourBus, canFollow: true})
  },

  // Writes the view's arrivals again as of `nowMs`, once it has had an answer.
  tickArrivals(nowMs) {
    const isViewAnswered = this.view !== null && this.view.shown !== null

    if (isViewAnswered) {
      this.writeViewArrivals(nowMs)
    }
  },

  sendOpenStop() {
    if (this.view !== null) {
      this.events.push({name: "stop-arrivals:open", payload: {stop_id: this.view.stop.id}})
    }
  },

  // Shows `stop` in the details view and holds it for its arrivals, which
  // the page answers with, and lets go of the stop the view showed before.
  // The stop is marked on the map while the view shows it. The stop the
  // view shows already is shown again as it is, which expands a collapsed
  // sheet. `parent` is the item the stop was opened from, which the view's
  // back button returns to.
  selectStop({stop, parent}) {
    const isSameStop = this.view !== null && this.view.stop.id === stop.id

    if (isSameStop) {
      showDetail({kind: DetailKind.stop, id: stop.id, title: suppliedName(stop), content: this.view.content, parent})
      this.revealStop(stop)
      return
    }

    const {content, favoriteButton, note, arrivalsElement, tripLine} = stopViewElements(stop)
    const earlier = this.view
    this.view = {stop, content, favoriteButton, note, arrivalsElement, tripLine, shown: null}

    if (earlier !== null) {
      releaseStop({pushEvent: this.push, stopId: earlier.stop.id, holder: VIEW_HOLDER})
    }

    holdStop({pushEvent: this.push, stopId: stop.id, holder: VIEW_HOLDER})
    showDetail({kind: DetailKind.stop, id: stop.id, title: suppliedName(stop), content, parent})
    this.markSelected()
    this.revealStop(stop)
  },

  // Moves the map so the stop stands beside the expanded sheet.
  revealStop(stop) {
    if (this.map !== null) {
      revealOnMap({map: this.map, lngLat: [stop.lon, stop.lat]})
    }
  },

  // Marks the stop the view shows on the map, and unmarks every other.
  markSelected() {
    let selected = null

    if (this.view !== null) {
      selected = this.view.stop
    }

    // The map takes the source once the page has an archive to draw the
    // stops from.
    const hasSource = this.map !== null && this.map.getSource(SELECTED_SOURCE_NAME) !== undefined

    if (hasSource) {
      this.map.getSource(SELECTED_SOURCE_NAME).setData(selectedCollection(selected))
      const translate = selectedTranslate(selected)
      this.map.setPaintProperty(SELECTED_HALO_LAYER_NAME, "circle-translate", translate)
      this.map.setPaintProperty(SELECTED_RING_LAYER_NAME, "circle-translate", translate)
    }
  },

  // Adds the layers, once the page has an archive to draw them from, in the
  // page's theme, and answers taps on them, once for each map.
  attach() {
    const map = this.map

    if (!addSource(map)) {
      return
    }

    const theme = currentTheme()
    registerImageResolver({map, key: IMAGE_RESOLVER_KEY, resolve: (id) => { addStopImage({map, id}) }})

    // Every sign is drawn, however crowded the street, toward the curb its
    // buses stop at.
    map.addLayer({
      id: MARKER_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      "source-layer": STOP_LAYER_NAME,
      minzoom: ZOOM_MIN,
      ...filterProperties(stopFilter()),
      layout: {
        "icon-image": SIGN_IMAGE_PREFIX + theme,
        "icon-size": iconSize,
        "icon-offset": signOffset,
        "icon-allow-overlap": true,
        "icon-ignore-placement": true
      }
    }, firstVehicleLayerName(map))

    // The arrow stands beside the sign on the side the stop faces, and turns
    // with the map.
    map.addLayer({
      id: ARROW_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      "source-layer": STOP_LAYER_NAME,
      minzoom: ZOOM_MIN,
      filter: keptFilter(hasCompassDirection),
      layout: {
        "icon-image": ARROW_IMAGE_PREFIX + theme,
        "icon-size": iconSize,
        "icon-rotate": ["match", ["get", "direction"], ...directionAngleCases(), 0],
        "icon-rotation-alignment": "map",
        "icon-offset": arrowOffsetPixels,
        "icon-allow-overlap": true,
        "icon-ignore-placement": true
      }
    }, firstVehicleLayerName(map))

    // The chips are left out where they would cover other chips, so a
    // crowded street shows the chips of some of its stops.
    map.addLayer({
      id: LABEL_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      "source-layer": STOP_LAYER_NAME,
      minzoom: ZOOM_MIN,
      filter: keptFilter(hasChips),
      layout: {
        "icon-image": ["concat", CHIPS_IMAGE_PREFIX, theme, ":", ["get", "routeChips"]],
        "icon-size": iconSize,
        "icon-anchor": ["match", ["get", "direction"], southwardDirections(), "bottom", "top"],
        "icon-offset": chipsOffset,
        "icon-allow-overlap": false
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
  // The device kind, and with it how far a tap reaches, is read once here.
  attachClicks() {
    const map = this.map
    const kind = deviceKind({isHoverNone: window.matchMedia(HOVER_NONE_MEDIA_QUERY).matches})
    const radiusPixels = tapRadiusPixels(kind)

    map.on("click", (event) => { this.answerTap({point: event.point, radiusPixels}) })
    map.on("movestart", closeListOnRiderMove)

    map.on("mouseenter", MARKER_LAYER_NAME, () => { map.getCanvas().style.cursor = "pointer" })
    map.on("mouseleave", MARKER_LAYER_NAME, () => { map.getCanvas().style.cursor = "" })
  },

  // Opens what a tap at `point` reaches among the stop signs within
  // `radiusPixels` once one lies under it: one stop, or the list of them. A
  // vehicle stands above the stops, so a tap on one opens no stop.
  answerTap({point, radiusPixels}) {
    const map = this.map

    if (map.getLayer(MARKER_LAYER_NAME) === undefined) {
      return
    }

    if (isVehicleAt({map, point})) {
      return
    }

    const outcome = stopTapAt({map, point, radiusPixels})

    switch (outcome.kind) {
      case StopTapKind.none:
        return
      case StopTapKind.one: {
        const stop = stopFromFeature(outcome.item)
        this.openStop(stop)
        return
      }
      case StopTapKind.list: {
        const stops = Array.from(outcome.items, stopFromFeature)
        this.openStopList({stops, count: outcome.count})
        return
      }
      default:
        unreachable(outcome.kind, "stop markers: a stop tap of unknown kind")
    }
  },

  // Shows `stops`, the nearest of the `count` stops under a tap, as a list
  // in the details view titled with `count`; a stop chosen from it opens
  // with the list as its parent. The list marks nothing on the map and
  // holds no stop open.
  openStopList({stops, count}) {
    assertCondition(count >= stops.length, `a list's count holds its stops, count: ${count}, stops: ${stops.length}`)
    const id = Array.from(stops, stopIdOf).join(",")
    const title = stopListTitle(count)
    const restCount = count - stops.length
    const chooseCallback = (stop) => {
      this.chooseListedStop({stop, parent: detailParent({kind: DetailKind.stopList, id, title, content})})
    }
    const content = stopListElement({stops, restCount, onChoose: chooseCallback})
    showDetail({kind: DetailKind.stopList, id, title, content, parent: NO_PARENT})
  },

  // Opens `stop`, chosen from a list, over `parent`, the list. While the
  // Trip tab waits for a stop, `stop` is its end instead, and the list
  // closes.
  chooseListedStop({stop, parent}) {
    if (isPicking()) {
      pickStop({stopId: stop.id, name: suppliedName(stop)})
      window.dispatchEvent(new CustomEvent(DESELECT_EVENT_NAME))
      return
    }

    this.selectStop({stop, parent})
  },

  // Selects `stop` and shows it in the details view. While the Trip tab
  // waits for a stop, `stop` is its end instead.
  openStop(stop) {
    if (isPicking()) {
      pickStop({stopId: stop.id, name: suppliedName(stop)})
      return
    }

    this.selectStop({stop, parent: NO_PARENT})
  },

  // Adds the source and the layers that mark the stop the details view
  // shows: a halo under the signs, and a ring over them and under the
  // vehicles.
  attachSelected() {
    const map = this.map
    let selected = null

    if (this.view !== null) {
      selected = this.view.stop
    }

    map.addSource(SELECTED_SOURCE_NAME, {type: "geojson", data: selectedCollection(selected)})

    const translate = selectedTranslate(selected)

    map.addLayer({
      id: SELECTED_HALO_LAYER_NAME,
      type: "circle",
      source: SELECTED_SOURCE_NAME,
      paint: {...selectionHaloPaint(SIGN_RADIUS_PIXELS), "circle-translate": translate}
    }, MARKER_LAYER_NAME)

    map.addLayer({
      id: SELECTED_RING_LAYER_NAME,
      type: "circle",
      source: SELECTED_SOURCE_NAME,
      paint: {...selectionRingPaint(SIGN_RADIUS_PIXELS), "circle-translate": translate}
    }, firstVehicleLayerName(map))
  },

  destroyed() {
    this.stopTicker()
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(CHANGE_EVENT_NAME, this.onChange)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.removeEventListener(FAVORITE_CHANGE_EVENT_NAME, this.onFavoriteChange)
    window.removeEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
    window.removeEventListener(CHOSEN_CHANGE_EVENT_NAME, this.onChosenChange)
    window.removeEventListener(OPEN_EVENT_NAME, this.onItemOpen)
    this.events.release()
  }
}
