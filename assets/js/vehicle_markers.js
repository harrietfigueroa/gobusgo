import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {assertCondition} from "./assert"
import {currentTheme} from "./color_theme"
import {glidePosition, glides} from "./marker_glide"
import {announceRiderPopupChange, RIDER_POPUP_CLASS_NAME} from "./rider_popups"
import {compactPopupContent, nameCloseButton} from "./route_chips"
import {alertLines} from "./service_alerts"
import {ImageNameKind, MARK_SIZE_PIXELS, badgeImageName, drawStatusBadge, parseImageName} from "./status_badges"
import {mapColors} from "./theme"
import {
  CHANGE_EVENT_NAME as DETAIL_CHANGE_EVENT_NAME,
  DetailKind,
  showDetail,
  showsDetail,
  updateDetail
} from "./panel_detail"
import {revealOnMap} from "./panel_sheet"
import {pageEvents} from "./page_events"
import {SCHEDULED_MARKERS_EVENT_NAME} from "./offline_service"
import {MapItemKind, OPEN_EVENT_NAME} from "./map_items"
import {attachVehicleOverlay, HitKind, overlayHitAt} from "./vehicle_overlay"
import {drawPointedMarker, MARKER_RADIUS_PIXELS, MARKER_STROKE_WIDTH_PIXELS, POINTED_IMAGE_SIZE_PIXELS} from "./vehicle_marker_shapes"
import {MotionTierKind, STILL_TIER, isPositionInBounds, markerIdsInBounds, motionSettingsOf, motionTier} from "./motion_tier"
import {PathTripKind, drawnVehicle, isAnimated, pathTrip, placedAtFetch, resumedOnCanvas, trackedVehicle} from "./vehicle_motion"
import {PathRequestKind, emptyPathRequests, nextPathRequest, pathRequestReplied, pathsReceived} from "./trip_path_requests"
import {tripPathKey, withTripPaths} from "./trip_path"
import {preparePath} from "./vehicle_prediction"

const SOURCE_NAME = "vehicle-markers"
const ROUND_LAYER_NAME = "vehicle-markers-round"
const POINTED_LAYER_NAME = "vehicle-markers-pointed"

// The layers a vehicle's marker is drawn in, round or pointed.
export const markerLayerNames = [ROUND_LAYER_NAME, POINTED_LAYER_NAME]
const ROUTE_LAYER_NAME = "vehicle-markers-route"
const routeFont = ["Noto Sans Medium"]
const ROUTE_TEXT_SIZE_PIXELS = 11
const routeTextOffsetEms = [0, 1]
const ROUTE_HALO_WIDTH_PIXELS = 1.5
const POINTED_IMAGE_PREFIX = "vehicle-marker-pointed-"
const POINTED_IMAGE_PIXEL_RATIO = 2
const BADGE_LAYER_NAME = "vehicle-markers-badge"
const BADGE_IMAGE_PIXEL_RATIO = 2
const HALVING_DIVISOR = 2
// The badge's lower left corner stands this far inside the marker's edge,
// right of and above its center, so the badge sits on its upper right edge.
const BADGE_INSET_PIXELS = 2
const BADGE_OFFSET_PIXELS = [MARKER_RADIUS_PIXELS - BADGE_INSET_PIXELS, BADGE_INSET_PIXELS - MARKER_RADIUS_PIXELS]
const STATUS_OPACITY_FALLBACK = 1
const POSITION_NOTE = "Marker position: the source's estimate"
const SCHEDULED_POSITION_NOTE = "Marker position: the saved schedule's, with delays, cancellations, and detours unknown"
const SCHEDULED_TRIP_NAME = "Scheduled trip"
// The key the scheduled markers are held under in place of every agency's.
const SCHEDULED_KEY = "scheduled"
const NOT_SUPPLIED = "Not supplied"
const FACTS_CLASS_NAME = "panel-detail-facts"
const ALERTS_CLASS_NAME = "panel-detail-alerts"
// The class of the popup of the vehicle the details view shows.
const SELECTED_POPUP_CLASS_NAME = "popup-selected"
const hasHeading = ["==", ["typeof", ["get", "heading"]], "number"]
const hasRoute = ["==", ["typeof", ["get", "route"]], "string"]
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"

function point(coordinates) {
  return {type: "Point", coordinates}
}

// Every agency's markers but those of `onCanvas`, which the canvas over the
// map draws, as one GeoJSON collection, a point per marker at `targetOf`
// its marker, with the texts its label and its popup show, and the glides
// that bring markers already drawn to their new positions. A marker in
// `drawn`, the positions drawn now, that glides is placed where it is drawn
// and glides from there; any other stands at its new position. A glide
// with both ends outside `bounds`, the map's, is seen by nobody and snaps,
// since each frame of a glide updates the whole source. A marker of
// `glidingNow` whose target is unchanged keeps its glide, so a glide ends
// one duration after its target last changed however often the fetches
// come. `drawn` comes back as the positions the collection draws, so a
// vehicle that leaves the fetch leaves it too.
function placeMarkers({markersByAgency, onCanvas, drawn, glidingNow, startMs, reducedMotion, targetOf, bounds}) {
  const features = []
  const placed = new Map()
  const gliding = new Map()

  for (const markers of markersByAgency.values()) {
    for (const marker of markers) {
      if (onCanvas.has(marker.id)) {
        continue
      }

      const target = targetOf(marker)
      let position = target
      const current = glidingNow.get(marker.id)
      const isGlidingNow = current !== undefined && !reducedMotion
      const isCarried = isGlidingNow && isSamePosition(current.target, target)

      if (isCarried) {
        position = drawn.get(marker.id)
        gliding.set(marker.id, current)
      } else if (drawn.has(marker.id)) {
        const source = drawn.get(marker.id)

        const isSeen = isPositionInBounds({position: source, bounds}) || isPositionInBounds({position: target, bounds})
        const isGlide = isSeen && glides({source, target, reducedMotion})

        if (isGlide) {
          position = source
          gliding.set(marker.id, {source, target, startMs})
        }
      }

      placed.set(marker.id, position)
      features.push(markerFeature({marker, position}))
    }
  }

  return {collection: {type: "FeatureCollection", features}, drawn: placed, gliding}
}

function isSamePosition(source, target) {
  const isSameLon = source[0] === target[0]
  const isSameLat = source[1] === target[1]
  const isSame = isSameLon && isSameLat
  return isSame
}

function markerFeature({marker, position}) {
  return {type: "Feature", geometry: point(position), properties: markerProperties(marker)}
}

// Whether the page holds a trip's prepared path.
const PathLookupKind = Object.freeze({found: "found", missing: "missing"})
const PATH_MISSING = Object.freeze({kind: PathLookupKind.missing})

// A path lookup as the prediction takes it: the prepared path, or none.
function preparedPathOf(lookup) {
  let path = null

  if (lookup.kind === PathLookupKind.found) {
    path = lookup.path
  }

  return path
}

// The bounds of what `map` shows, as plain degrees.
function boundsOf(map) {
  const bounds = map.getBounds()
  return {west: bounds.getWest(), south: bounds.getSouth(), east: bounds.getEast(), north: bounds.getNorth()}
}

// The markers of `markersByAgency` by their identifiers.
function markersById(markersByAgency) {
  const byId = new Map()

  for (const markers of markersByAgency.values()) {
    for (const marker of markers) {
      byId.set(marker.id, marker)
    }
  }

  return byId
}

// The position a marker on the canvas is drawn at when its caller gives
// none: its fetch's.
function fetchedPosition({marker}) {
  return [marker.lon, marker.lat]
}

// The texts a marker's label, popup, and view show, as its feature holds
// them.
function markerProperties(marker) {
  return {
    markerId: marker.id,
    vehicleId: marker.vehicle_id,
    heading: marker.heading,
    color: marker.color,
    routeId: marker.route_id,
    route: marker.route,
    headsign: marker.headsign,
    schedule: marker.schedule,
    nextStop: marker.next_stop,
    status: marker.status,
    locationAge: marker.location_age,
    realTime: marker.real_time
  }
}

const MarkerLookupKind = Object.freeze({found: "found", missing: "missing"})

// The marker of `markerId` among `markers`, or missing where they do not
// hold it.
function findMarker({markers, markerId}) {
  const marker = markers.find((candidate) => candidate.id === markerId)

  if (marker === undefined) {
    return {kind: MarkerLookupKind.missing}
  } else {
    return {kind: MarkerLookupKind.found, marker}
  }
}

function statusCase({status, opacity}) {
  return [status, opacity]
}

// The paint expression that gives each marker the opacity of its status.
function statusOpacity(statuses) {
  const cases = statuses.flatMap(statusCase)
  return ["match", ["get", "status"], ...cases, STATUS_OPACITY_FALLBACK]
}

// The image of a pointed marker in one color, outlined in `strokeColor`:
// the round marker's circle, centered in the image, drawn out to a tip that
// points up, which is north for a heading of zero.
function pointedImage({color, strokeColor}) {
  const size = POINTED_IMAGE_SIZE_PIXELS * POINTED_IMAGE_PIXEL_RATIO
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size

  const context = canvas.getContext("2d")
  const center = POINTED_IMAGE_SIZE_PIXELS / HALVING_DIVISOR
  context.scale(POINTED_IMAGE_PIXEL_RATIO, POINTED_IMAGE_PIXEL_RATIO)
  drawPointedMarker(canvas, {x: center, y: center, angleRadians: 0, color, strokeColor})
  return context.getImageData(0, 0, size, size)
}

// The image of the status badge `badge` in the colors of `theme`.
function badgeImage({badge, theme}) {
  const size = MARK_SIZE_PIXELS * BADGE_IMAGE_PIXEL_RATIO
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size
  const context = canvas.getContext("2d")
  context.scale(BADGE_IMAGE_PIXEL_RATIO, BADGE_IMAGE_PIXEL_RATIO)
  const colors = mapColors(theme)
  drawStatusBadge(canvas, {badge, ink: colors.badgeInk, paper: colors.badgePaper, x: 0, y: 0})
  return context.getImageData(0, 0, size, size)
}

function badgeCase({status, badge}) {
  return [status, badgeImageName({badge, theme: currentTheme()})]
}

function hasBadge(definition) {
  return typeof definition.badge === "string"
}

function statusOf(definition) {
  return definition.status
}

function headingText(heading) {
  if (typeof heading === "number") {
    return `${heading}° clockwise from north`
  } else {
    return NOT_SUPPLIED
  }
}

function suppliedText(value) {
  if (typeof value === "string") {
    return value
  } else {
    return NOT_SUPPLIED
  }
}

// The lines for a vehicle's lateness and its next stop, each only for a
// marker that has the text.
function tripTimeLines(properties) {
  const lines = []

  if (typeof properties.schedule === "string") {
    lines.push(`Schedule: ${properties.schedule}`)
  }

  if (typeof properties.nextStop === "string") {
    lines.push(`Next stop: ${properties.nextStop}`)
  }

  return lines
}

function appendParagraphs(content, lines) {
  for (const line of lines) {
    const paragraph = document.createElement("p")
    paragraph.textContent = line
    content.appendChild(paragraph)
  }
}

// A marker the saved schedule places stands for a trip and no vehicle.
function isScheduledTrip(properties) {
  return typeof properties.vehicleId !== "string"
}

function vehicleName(properties) {
  if (isScheduledTrip(properties)) {
    return SCHEDULED_TRIP_NAME
  }

  return `Vehicle ${properties.vehicleId}`
}

function positionNote(properties) {
  if (isScheduledTrip(properties)) {
    return SCHEDULED_POSITION_NOTE
  }

  return POSITION_NOTE
}

// The view's title: the route and where it goes, or the vehicle for one
// with neither.
function vehicleViewTitle(properties) {
  const names = []

  if (typeof properties.route === "string") {
    names.push(properties.route)
  }

  if (typeof properties.headsign === "string") {
    names.push(`to ${properties.headsign}`)
  }

  if (names.length === 0) {
    return vehicleName(properties)
  } else {
    return names.join(" ")
  }
}

// A vehicle's view is built as text nodes: the vehicle identifier comes
// from outside the application and is never parsed as HTML. The current
// alerts of the vehicle's route stand under its route and headsign.
function vehicleViewContent(properties, statusLabels) {
  const tripLines = [
    vehicleName(properties),
    `Route: ${suppliedText(properties.route)}`,
    `Headsign: ${suppliedText(properties.headsign)}`
  ]
  const detailLines = [
    ...tripTimeLines(properties),
    statusLabels.get(properties.status),
    `Location reported: ${properties.locationAge}`,
    `Real-time data: ${properties.realTime}`,
    `Heading: ${headingText(properties.heading)}`,
    positionNote(properties)
  ]
  const routeIds = []

  if (typeof properties.routeId === "string") {
    routeIds.push(properties.routeId)
  }

  const content = document.createElement("div")
  const trip = document.createElement("div")
  trip.className = FACTS_CLASS_NAME
  appendParagraphs(trip, tripLines)

  const alerts = document.createElement("div")
  alerts.className = ALERTS_CLASS_NAME

  for (const alertLine of alertLines({routeIds, stopId: null})) {
    alerts.append(alertLine)
  }

  const details = document.createElement("div")
  details.className = FACTS_CLASS_NAME
  appendParagraphs(details, detailLines)

  content.append(trip, alerts, details)
  return content
}

// The item a vehicle's popup names: the vehicle, and the status of a vehicle
// whose marker carries a badge, so the status the badge shows is also text.
function vehiclePopupItemName({properties, badgedLabels}) {
  const statusLabel = badgedLabels.get(properties.status)

  if (statusLabel === undefined) {
    return vehicleViewTitle(properties)
  }

  return `${vehicleViewTitle(properties)}, ${statusLabel}`
}

// A vehicle's popup is its route's number in its marker's color, with its
// lateness beside it where the marker has one. A click on it hands the
// vehicle to `onSelect`.
function compactVehicleContent({properties, badgedLabels, onSelect}) {
  const chips = []
  let noteText = ""

  if (typeof properties.route === "string") {
    chips.push({name: properties.route, color: properties.color})
  }

  if (typeof properties.schedule === "string") {
    noteText = properties.schedule
  }

  const {content} = compactPopupContent({
    chips,
    countMax: 1,
    emptyText: vehicleName(properties),
    noteText,
    itemName: vehiclePopupItemName({properties, badgedLabels}),
    action: "show the vehicle",
    onSelect
  })

  return content
}

function statusLabelEntry({status, label}) {
  return [status, label]
}

// The hook of the element beside the map. It holds every agency's markers
// as the server last sent them, and draws them on each map the basemap
// announces, so a map drawn anew for another archive shows them too, and
// again in the theme of a map whose style is set anew.
export const VehicleMarkers = {
  mounted() {
    const statuses = JSON.parse(this.el.dataset.statuses)
    this.statuses = statuses
    const labelEntries = Array.from(statuses, statusLabelEntry)
    this.statusLabels = new Map(labelEntries)
    const badged = statuses.filter(hasBadge)
    const badgedEntries = Array.from(badged, statusLabelEntry)
    this.badgedLabels = new Map(badgedEntries)
    this.markersByAgency = new Map()
    this.map = null
    this.maplibre = null
    this.drawn = new Map()
    this.gliding = new Map()
    this.frame = null
    // The canvas over the map, the markers it draws in place of the
    // source, and where it draws each of them.
    this.overlay = null
    this.onCanvas = new Set()
    this.canvasPositionAt = fetchedPosition
    // The marker the details view shows, or null while it shows none, and
    // the texts it was last written from.
    this.viewMarkerId = null
    this.viewText = ""
    // The rider's popup of a vehicle, with its marker, or null while none
    // is open.
    this.riderPopup = null
    // When the markers move between fetches, the tier decided last, and
    // each vehicle's state between fetches, by marker. Each agency's clock
    // is its fetch time and the page's monotonic time the fetch arrived at,
    // so a skewed device clock moves no marker.
    this.motionSettings = motionSettingsOf(JSON.parse(this.el.dataset.motion))
    this.tier = STILL_TIER
    this.tracked = new Map()
    this.agencyOfMarker = new Map()
    this.clocks = new Map()
    // The trip paths the page holds, each prepared once, and its requests.
    this.pathCache = new Map()
    this.preparedPaths = new WeakMap()
    this.pathRequests = emptyPathRequests()
    this.reducedMotion = window.matchMedia(REDUCED_MOTION_QUERY)

    this.onVisibilityChange = () => { this.visibilityChanged() }
    this.onReducedMotionChange = () => { this.decideMotion() }
    document.addEventListener("visibilitychange", this.onVisibilityChange)
    this.reducedMotion.addEventListener("change", this.onReducedMotionChange)

    // The view moving to a stop, or closing, unmarks the vehicle's popup.
    this.onDetailChange = () => {
      const isViewLeft = this.viewMarkerId !== null && showsDetail({kind: DetailKind.vehicle, id: this.viewMarkerId}) === false

      if (isViewLeft) {
        this.viewMarkerId = null
        this.markSelected()
      }
    }

    window.addEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)

    // The list of what is in view opens a vehicle as a click on its marker does.
    this.onItemOpen = (event) => {
      const {kind, feature} = event.detail
      const isVehicle = kind === MapItemKind.vehicle && this.map !== null

      if (isVehicle) {
        this.openVehicle(feature)
      }
    }

    window.addEventListener(OPEN_EVENT_NAME, this.onItemOpen)

    this.onBasemapReady = (event) => {
      const {map, maplibre} = event.detail
      this.map = null
      this.overlay = null
      this.onCanvas = new Set()
      this.canvasPositionAt = fetchedPosition
      this.tier = STILL_TIER
      this.stopGliding()
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => { this.attach(map, maplibre) })
    }

    // A style set anew holds none of the layers, nor the source, nor the
    // images of the pointed markers, which are made again as they are drawn.
    this.onRestyled = (event) => {
      const {map} = event.detail

      if (map === this.map) {
        this.addLayers(map)
      }
    }

    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.addEventListener(RESTYLED_EVENT_NAME, this.onRestyled)

    this.events = pageEvents(this)

    // Whether the markers held are the saved schedule's, which an offline
    // page sends itself in place of every agency's.
    this.isScheduled = false

    this.events.handle("vehicle-markers:agency", ({agency_id: agencyId, fetched_at_ms: fetchedAtMs, markers}) => {
      assertCondition(Number.isSafeInteger(fetchedAtMs), `an agency's fetch time ${fetchedAtMs} is a whole number of milliseconds`)
      this.clocks.set(agencyId, {fetchedAtMs, receivedAtMs: performance.now()})
      this.markersByAgency.set(agencyId, markers)
      this.trackFetch({agencyId, markers})
      this.decideMotion()
      this.draw({isSnapped: false})
      this.updateView(markers)
    })

    this.events.handle("trip-paths:paths", (event) => { this.pathsArrived(event) })

    // The saved schedule's markers stand where the schedule puts them, on a
    // clock of their own that no prediction reads.
    this.events.handle(SCHEDULED_MARKERS_EVENT_NAME, ({markers}) => {
      this.isScheduled = true
      this.markersByAgency = new Map([[SCHEDULED_KEY, markers]])
      this.resetTracking()
      this.clocks.set(SCHEDULED_KEY, {fetchedAtMs: Date.now(), receivedAtMs: performance.now()})
      this.trackFetch({agencyId: SCHEDULED_KEY, markers})
      this.drawInSource()
      this.tier = STILL_TIER
      this.draw({isSnapped: false})
      this.updateView(markers)
    })

    // A page live again draws the server's markers in place of the
    // schedule's, and asks for every agency's since it holds none.
    this.events.whenLive(() => {
      if (this.isScheduled) {
        this.isScheduled = false
        this.markersByAgency = new Map()
        this.resetTracking()
        this.drawInSource()
        this.tier = STILL_TIER
        this.draw({isSnapped: false})
        this.events.push({name: "vehicle-markers:ready", payload: {}})
      }
    })

    this.events.push({name: "vehicle-markers:ready", payload: {}})
  },

  attach(map, maplibre) {
    this.maplibre = maplibre
    // A pointed marker's image is made the first time a marker of its color
    // is drawn, since the colors are the routes' and not known in advance.
    // MapLibre awaits this resolver before it hands a tile its images, and
    // gives it to every style the map is set to; its "styleimagemissing"
    // event comes after the tile has taken its images without the new one
    // (maplibre-gl 6.12.0, ImageManager._getImagesForIds).
    // A badge's image names its theme, so a style set anew in the other
    // theme asks for images of its own.
    map.setMissingStyleImageResolver((id) => {
      const named = parseImageName(id)

      if (id.startsWith(POINTED_IMAGE_PREFIX)) {
        const color = id.slice(POINTED_IMAGE_PREFIX.length)
        const strokeColor = mapColors(currentTheme()).vehicleStroke
        const image = pointedImage({color, strokeColor})
        map.addImage(id, image, {pixelRatio: POINTED_IMAGE_PIXEL_RATIO})
      } else if (named.kind === ImageNameKind.badge) {
        const image = badgeImage({badge: named.badge, theme: named.theme})
        map.addImage(id, image, {pixelRatio: BADGE_IMAGE_PIXEL_RATIO})
      }
    })

    this.addLayers(map)
    const canvas = map.getCanvas()

    // A map keeps the listeners of a layer while the layer is added again.
    for (const layerName of markerLayerNames) {
      // A click on a vehicle opens its compact popup and shows the vehicle
      // in the details view. A vehicle the canvas draws stands above the
      // layers, so a click it takes opens that vehicle alone.
      map.on("click", layerName, (event) => {
        const hit = overlayHitAt({map, point: event.point})

        if (hit.kind === HitKind.missing) {
          const [feature] = event.features
          this.openVehicle(feature)
        }
      })

      map.on("mouseenter", layerName, () => { canvas.style.cursor = "pointer" })
      map.on("mouseleave", layerName, () => { canvas.style.cursor = "" })
    }

    this.attachOverlay(map)
    this.map = map
    // The tier is decided once a camera move ends, never during one.
    map.on("moveend", () => { this.decideMotion() })
    this.decideMotion()
  },

  // Adds the canvas over `map`. The canvas takes no pointer events, so the
  // map's own click and pointer moves find the vehicles it draws.
  attachOverlay(map) {
    const canvas = map.getCanvas()
    this.overlay = attachVehicleOverlay({map, statuses: this.statuses})

    map.on("click", (event) => {
      const hit = overlayHitAt({map, point: event.point})

      if (hit.kind === HitKind.found) {
        this.openVehicle(hit.feature)
      }
    })

    this.isPointerOnCanvasVehicle = false
    map.on("mousemove", (event) => {
      const hit = overlayHitAt({map, point: event.point})
      const isOnVehicle = hit.kind === HitKind.found

      if (isOnVehicle) {
        canvas.style.cursor = "pointer"
      } else if (this.isPointerOnCanvasVehicle) {
        canvas.style.cursor = ""
      }

      this.isPointerOnCanvasVehicle = isOnVehicle
    })
  },

  // Moves the markers of `markerIds` off the source and onto the canvas over
  // the map, in one update of the source, and draws them there at
  // `positionAt({marker, nowMs})`, a marker as the server sent it and the
  // page's monotonic time in milliseconds, at `rateHz` while the camera is still
  // and at each frame of a camera move. A call replaces the set of the one
  // before it: a marker it leaves out goes back to the source at the
  // position it was drawn at. A page that asks for reduced motion keeps
  // every marker in the source.
  drawOnCanvas({markerIds, rateHz, positionAt}) {
    const isReducedMotion = this.reducedMotion.matches
    const isDrawable = this.overlay !== null && !isReducedMotion

    if (!isDrawable) {
      return
    }

    const entering = new Set(markerIds)
    const leaving = []

    for (const markerId of this.onCanvas) {
      if (!entering.has(markerId)) {
        leaving.push(markerId)
      }
    }

    const returned = this.returnedFeatures(leaving)
    const removed = []

    for (const markerId of entering) {
      if (!this.onCanvas.has(markerId)) {
        removed.push(markerId)
        this.gliding.delete(markerId)
        this.drawn.delete(markerId)
      }
    }

    this.onCanvas = entering
    this.canvasPositionAt = positionAt
    this.updateSource({add: returned, remove: removed})
    this.overlay.start({rateHz, vehiclesAt: (nowMs) => this.canvasVehicles(nowMs)})
  },

  // Moves every marker on the canvas back to the source, in one update, at
  // the position it was drawn at, and stops the canvas.
  drawInSource() {
    if (this.onCanvas.size === 0) {
      return
    }

    const returned = this.returnedFeatures(this.onCanvas)
    this.onCanvas = new Set()
    this.canvasPositionAt = fetchedPosition
    this.overlay.stop()
    this.updateSource({add: returned, remove: []})
  },

  // The features of the markers of `markerIds` the fetches still hold, at
  // the positions the canvas draws them at now, which become their drawn
  // positions in the source.
  returnedFeatures(markerIds) {
    const byId = markersById(this.markersByAgency)
    const nowMs = performance.now()
    const features = []

    for (const markerId of markerIds) {
      const marker = byId.get(markerId)

      if (marker !== undefined) {
        const position = this.canvasPositionAt({marker, nowMs})
        this.drawn.set(markerId, position)
        features.push(markerFeature({marker, position}))
      }
    }

    return features
  },

  // The vehicles the canvas draws at `nowMs`: the markers on the canvas the
  // fetches still hold, with their texts as the latest fetch has them.
  canvasVehicles(nowMs) {
    const byId = markersById(this.markersByAgency)
    const features = []

    for (const markerId of this.onCanvas) {
      const marker = byId.get(markerId)

      if (marker !== undefined) {
        const position = this.canvasPositionAt({marker, nowMs})
        features.push(markerFeature({marker, position}))
      }
    }

    return features
  },

  // A map whose style is being set anew has no source, and the markers
  // held here are drawn when it is added.
  updateSource({add, remove}) {
    const source = this.map.getSource(SOURCE_NAME)
    const isChanged = add.length > 0 || remove.length > 0
    const isDue = source !== undefined && isChanged

    if (isDue) {
      source.updateData({add, remove})
    }
  },

  // Opens the compact popup of the vehicle of `feature`, a feature of a
  // marker layer, and shows the vehicle in the details view.
  openVehicle(feature) {
    const map = this.map
    const {properties} = feature
    const lngLat = feature.geometry.coordinates
    const onSelect = () => { this.selectVehicle({properties, lngLat}) }

    const content = compactVehicleContent({properties, badgedLabels: this.badgedLabels, onSelect})
    const popup = new this.maplibre.Popup({className: RIDER_POPUP_CLASS_NAME})
      .setLngLat(lngLat)
      .setDOMContent(content)

    const riderPopup = {popup, markerId: properties.markerId}

    popup.on("close", () => {
      if (this.riderPopup === riderPopup) {
        this.riderPopup = null
      }

      announceRiderPopupChange()
    })

    popup.addTo(map)
    nameCloseButton({content, itemName: vehicleViewTitle(properties)})
    this.riderPopup = riderPopup
    this.selectVehicle({properties, lngLat})
    announceRiderPopupChange()
  },

  // Adds the source with every marker and the layers in the page's theme.
  addLayers(map) {
    this.stopGliding()

    // A new map draws every marker at its position, with nothing to glide from.
    const {collection, drawn} = placeMarkers({
      markersByAgency: this.markersByAgency,
      onCanvas: this.onCanvas,
      drawn: new Map(),
      glidingNow: new Map(),
      startMs: performance.now(),
      reducedMotion: this.reducedMotion.matches,
      targetOf: (marker) => this.targetOf(marker),
      bounds: boundsOf(map)
    })

    this.drawn = drawn
    map.addSource(SOURCE_NAME, {type: "geojson", data: collection, promoteId: "markerId"})

    const colors = mapColors(currentTheme())
    const opacity = statusOpacity(this.statuses)

    map.addLayer({
      id: ROUND_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      filter: ["!", hasHeading],
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": ["get", "color"],
        "circle-opacity": opacity,
        "circle-stroke-color": colors.vehicleStroke,
        "circle-stroke-width": MARKER_STROKE_WIDTH_PIXELS,
        "circle-stroke-opacity": opacity
      }
    })

    // The image turns with the map, so a heading stays a compass direction
    // on a map that is turned.
    map.addLayer({
      id: POINTED_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      filter: hasHeading,
      layout: {
        "icon-image": ["concat", POINTED_IMAGE_PREFIX, ["get", "color"]],
        "icon-rotate": ["get", "heading"],
        "icon-rotation-alignment": "map",
        "icon-allow-overlap": true
      },
      paint: {"icon-opacity": opacity}
    })

    this.addBadgeLayer(map)

    // A label is left out where it would cover another label, so a crowded
    // street shows the routes of some of its vehicles.
    map.addLayer({
      id: ROUTE_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      filter: hasRoute,
      layout: {
        "text-field": ["get", "route"],
        "text-font": routeFont,
        "text-size": ROUTE_TEXT_SIZE_PIXELS,
        "text-anchor": "top",
        "text-offset": routeTextOffsetEms,
        "text-allow-overlap": false
      },
      paint: {
        "text-color": colors.vehicleLabel,
        "text-halo-color": colors.vehicleHalo,
        "text-halo-width": ROUTE_HALO_WIDTH_PIXELS
      }
    })
  },

  // A marker of a status a recent report lacks carries that status's badge
  // on its upper right edge, at full opacity whatever the marker's.
  addBadgeLayer(map) {
    const badged = this.statuses.filter(hasBadge)
    const badgeCases = badged.flatMap(badgeCase)
    const badgedStatuses = Array.from(badged, statusOf)

    map.addLayer({
      id: BADGE_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      filter: ["in", ["get", "status"], ["literal", badgedStatuses]],
      layout: {
        "icon-image": ["match", ["get", "status"], ...badgeCases, ""],
        "icon-anchor": "bottom-left",
        "icon-offset": BADGE_OFFSET_PIXELS,
        "icon-allow-overlap": true,
        "icon-ignore-placement": true
      }
    })
  },

  // Places every marker the source draws at its target, gliding there from
  // where it stands, or at once for `isSnapped`. A hidden page places
  // nothing until it is shown.
  draw({isSnapped}) {
    if (document.visibilityState !== "visible") {
      return
    }

    // A map whose style is being set anew has no source until the style has
    // loaded, and the markers held here are drawn when the source is added.
    const hasSource = this.map !== null && this.map.getSource(SOURCE_NAME) !== undefined

    if (hasSource) {
      const isGlideRefused = this.reducedMotion.matches || isSnapped
      const {collection, drawn, gliding} = placeMarkers({
        markersByAgency: this.markersByAgency,
        onCanvas: this.onCanvas,
        drawn: this.drawn,
        glidingNow: this.gliding,
        startMs: performance.now(),
        reducedMotion: isGlideRefused,
        targetOf: (marker) => this.targetOf(marker),
        bounds: boundsOf(this.map)
      })

      this.drawn = drawn
      this.gliding = gliding
      this.map.getSource(SOURCE_NAME).setData(collection)
      this.requestGlideFrame()
    }

    // The canvas draws the texts and statuses of the latest fetch.
    if (this.overlay !== null) {
      this.overlay.drawIfRunning()
    }
  },

  // The time on the source's clock that `nowMs`, the page's monotonic time,
  // stands for: the agency's fetch time plus the time since it arrived.
  sourceNowMs({agencyId, nowMs}) {
    const clock = this.clocks.get(agencyId)
    assertCondition(clock !== undefined, `agency ${agencyId} has a clock`)
    return clock.fetchedAtMs + (nowMs - clock.receivedAtMs)
  },

  // The prepared path of the trip `marker` serves, or missing where the
  // page holds none.
  pathOf(marker) {
    const hasTrip = typeof marker.trip_id === "string"
    const hasDate = Number.isSafeInteger(marker.service_date_ms)
    const isOnTrip = hasTrip && hasDate

    if (!isOnTrip) {
      return PATH_MISSING
    }

    const key = tripPathKey({tripId: marker.trip_id, serviceDateMs: marker.service_date_ms})
    const decoded = this.pathCache.get(key)

    if (decoded === undefined) {
      return PATH_MISSING
    }

    if (!this.preparedPaths.has(decoded)) {
      this.preparedPaths.set(decoded, preparePath(decoded))
    }

    return {kind: PathLookupKind.found, path: this.preparedPaths.get(decoded)}
  },

  // Follows each vehicle of `markers`, one agency's fetch: a vehicle the
  // canvas draws meets its new prediction with a correction, and any other
  // stands at its prediction for the moment the fetch arrived, which the
  // source glides it to. A vehicle that leaves the fetch is forgotten.
  trackFetch({agencyId, markers}) {
    const atMs = this.sourceNowMs({agencyId, nowMs: performance.now()})
    const fetchedIds = new Set()

    for (const marker of markers) {
      fetchedIds.add(marker.id)
      this.agencyOfMarker.set(marker.id, agencyId)
      let previous = null

      if (this.tracked.has(marker.id)) {
        previous = this.tracked.get(marker.id)
      }

      let tracked = trackedVehicle({tracked: previous, marker, path: preparedPathOf(this.pathOf(marker)), atMs})

      if (!this.onCanvas.has(marker.id)) {
        tracked = placedAtFetch({tracked, atMs})
      }

      this.tracked.set(marker.id, tracked)
    }

    for (const [markerId, markerAgencyId] of this.agencyOfMarker) {
      const isLeft = markerAgencyId === agencyId && !fetchedIds.has(markerId)

      if (isLeft) {
        this.agencyOfMarker.delete(markerId)
        this.tracked.delete(markerId)
      }
    }
  },

  resetTracking() {
    this.tracked = new Map()
    this.agencyOfMarker = new Map()
    this.clocks = new Map()
  },

  // Where the source draws `marker`: where its state between fetches puts
  // it, or where the fetch does before it has one.
  targetOf(marker) {
    const tracked = this.tracked.get(marker.id)

    if (tracked === undefined) {
      return [marker.lon, marker.lat]
    }

    return tracked.drawn.position
  },

  // Where the canvas draws `marker` at `nowMs`, the page's monotonic time.
  canvasPosition({marker, nowMs}) {
    const tracked = this.tracked.get(marker.id)

    if (tracked === undefined) {
      return [marker.lon, marker.lat]
    }

    const agencyId = this.agencyOfMarker.get(marker.id)
    const atMs = this.sourceNowMs({agencyId, nowMs})
    const drawn = drawnVehicle({tracked, atMs})
    this.tracked.set(marker.id, drawn)
    return drawn.drawn.position
  },

  // Every marker's position as drawn now, on the canvas or in the source.
  drawnPositions() {
    const positions = new Map(this.drawn)

    for (const markerId of this.onCanvas) {
      const tracked = this.tracked.get(markerId)

      if (tracked !== undefined) {
        positions.set(markerId, tracked.drawn.position)
      }
    }

    return positions
  },

  // Decides whether the markers in view move between fetches, and at what
  // rate, from the zoom, the count of markers inside the map's bounds, the
  // reduced-motion preference, and whether the page is shown; then moves
  // the animated vehicles in view onto the canvas, or every vehicle back
  // to the source, and asks for the paths the vehicles in view lack.
  decideMotion() {
    if (this.map === null) {
      return
    }

    const inView = markerIdsInBounds({
      positions: this.drawnPositions(),
      bounds: boundsOf(this.map)
    })

    this.tier = motionTier({
      settings: this.motionSettings,
      zoom: this.map.getZoom(),
      vehicleCountInView: inView.length,
      isReducedMotion: this.reducedMotion.matches,
      isVisible: document.visibilityState === "visible",
      previous: this.tier
    })

    if (this.tier.kind === MotionTierKind.still) {
      this.drawInSource()
      return
    }

    const animated = []
    const nowMs = performance.now()
    const positions = this.drawnPositions()

    for (const markerId of inView) {
      const tracked = this.tracked.get(markerId)
      const isMoving = tracked !== undefined && isAnimated(tracked)

      if (isMoving) {
        animated.push(markerId)
      }

      const isEntering = isMoving && !this.onCanvas.has(markerId)

      if (isEntering) {
        const atMs = this.sourceNowMs({agencyId: this.agencyOfMarker.get(markerId), nowMs})
        const sourcePosition = positions.get(markerId)
        this.tracked.set(markerId, resumedOnCanvas({tracked, sourcePosition, atMs}))
      }
    }

    this.drawOnCanvas({
      markerIds: animated,
      rateHz: this.tier.rateHz,
      positionAt: (canvasMarker) => this.canvasPosition(canvasMarker)
    })
    this.requestPaths(inView)
  },

  // Asks the server for the paths of the trips the vehicles of `markerIds`
  // serve that the page lacks, as the requests' state allows.
  requestPaths(markerIds) {
    const trips = []

    for (const markerId of markerIds) {
      const tracked = this.tracked.get(markerId)

      if (tracked !== undefined) {
        const named = pathTrip(tracked)

        if (named.kind === PathTripKind.trip) {
          trips.push(named.trip)
        }
      }
    }

    const next = nextPathRequest({requests: this.pathRequests, cache: this.pathCache, trips, nowMs: performance.now()})

    if (next.kind === PathRequestKind.none) {
      return
    }

    this.pathRequests = next.requests
    this.events.push({
      name: "trip-paths:request",
      payload: {trips: next.trips},
      onReply: (reply) => {
        this.pathRequests = pathRequestReplied({requests: this.pathRequests, reply, nowMs: performance.now()})
      }
    })
  },

  // Keeps the paths of a `trip-paths:paths` event, anchors again each
  // vehicle of their trips, and decides the tier again so they move.
  pathsArrived(event) {
    const received = pathsReceived({requests: this.pathRequests, event, nowMs: performance.now()})
    this.pathRequests = received.requests

    if (received.paths.length === 0) {
      return
    }

    this.pathCache = withTripPaths(this.pathCache, received.paths)
    const byId = markersById(this.markersByAgency)
    const nowMs = performance.now()

    for (const [markerId, tracked] of this.tracked) {
      const marker = byId.get(markerId)

      if (marker === undefined) {
        continue
      }

      const lookup = this.pathOf(marker)
      const isFound = lookup.kind === PathLookupKind.found
      const isNewPath = isFound && tracked.path !== lookup.path

      if (isNewPath) {
        const atMs = this.sourceNowMs({agencyId: this.agencyOfMarker.get(markerId), nowMs})
        this.tracked.set(markerId, trackedVehicle({tracked, marker, path: lookup.path, atMs}))
      }
    }

    this.decideMotion()
  },

  // A page hidden moves every marker back to the source and updates
  // nothing; shown again, it places every marker at its prediction for now
  // at once, then decides the tier.
  visibilityChanged() {
    if (document.visibilityState !== "visible") {
      this.decideMotion()
      return
    }

    const nowMs = performance.now()

    for (const [markerId, tracked] of this.tracked) {
      const atMs = this.sourceNowMs({agencyId: this.agencyOfMarker.get(markerId), nowMs})
      this.tracked.set(markerId, placedAtFetch({tracked, atMs}))
    }

    this.draw({isSnapped: true})
    this.decideMotion()
  },

  // Shows the vehicle of `properties` in the details view, marks its popup,
  // and moves the map so the vehicle, at `lngLat`, stands beside the sheet.
  selectVehicle({properties, lngLat}) {
    this.viewMarkerId = properties.markerId
    this.viewText = JSON.stringify(properties)
    showDetail({
      kind: DetailKind.vehicle,
      id: properties.markerId,
      title: vehicleViewTitle(properties),
      content: vehicleViewContent(properties, this.statusLabels)
    })
    this.markSelected()

    if (this.map !== null) {
      revealOnMap({map: this.map, lngLat})
    }
  },

  // Writes the view of the vehicle it shows from `markers`, one agency's
  // latest fetch, where they hold that vehicle. A vehicle no fetch holds
  // any more keeps the view it has.
  updateView(markers) {
    if (this.viewMarkerId === null) {
      return
    }

    const lookup = findMarker({markers, markerId: this.viewMarkerId})

    if (lookup.kind === MarkerLookupKind.missing) {
      return
    }

    // A fetch that leaves the vehicle's texts as they were leaves the view,
    // and the focus in it, as it is.
    const properties = markerProperties(lookup.marker)
    const viewText = JSON.stringify(properties)

    if (viewText !== this.viewText) {
      this.viewText = viewText

      updateDetail({
        kind: DetailKind.vehicle,
        id: properties.markerId,
        title: vehicleViewTitle(properties),
        content: vehicleViewContent(properties, this.statusLabels)
      })
    }
  },

  markSelected() {
    if (this.riderPopup !== null) {
      const isSelected = this.riderPopup.markerId === this.viewMarkerId
      this.riderPopup.popup.getElement().classList.toggle(SELECTED_POPUP_CLASS_NAME, isSelected)
    }
  },

  requestGlideFrame() {
    const isFrameDue = this.gliding.size > 0 && this.frame === null

    if (isFrameDue) {
      this.frame = requestAnimationFrame((frameMs) => { this.glideFrame(frameMs) })
    }
  },

  // One frame moves each gliding marker, and nothing else, in the source.
  // A glide ends after its duration, so the frames stop once every marker
  // has arrived.
  glideFrame(frameMs) {
    this.frame = null
    const source = this.map.getSource(SOURCE_NAME)

    if (source === undefined) {
      this.gliding = new Map()
      return
    }

    const update = []

    for (const [markerId, glide] of this.gliding) {
      const elapsedMs = frameMs - glide.startMs
      const {position, ended} = glidePosition({...glide, elapsedMs})

      update.push({id: markerId, newGeometry: point(position)})
      this.drawn.set(markerId, position)

      if (ended) {
        this.gliding.delete(markerId)
      }
    }

    source.updateData({update})
    this.requestGlideFrame()
  },

  stopGliding() {
    if (this.frame !== null) {
      cancelAnimationFrame(this.frame)
      this.frame = null
    }

    this.gliding = new Map()
  },

  destroyed() {
    this.stopGliding()
    document.removeEventListener("visibilitychange", this.onVisibilityChange)
    this.reducedMotion.removeEventListener("change", this.onReducedMotionChange)
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
    window.removeEventListener(RESTYLED_EVENT_NAME, this.onRestyled)
    window.removeEventListener(OPEN_EVENT_NAME, this.onItemOpen)
    window.removeEventListener(DETAIL_CHANGE_EVENT_NAME, this.onDetailChange)
    this.events.release()
  }
}
