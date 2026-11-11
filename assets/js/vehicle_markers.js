import {READY_EVENT_NAME, RESTYLED_EVENT_NAME} from "./basemap"
import {assertCondition, unreachable} from "./assert"
import {currentTheme} from "./color_theme"
import {glidePosition, glides} from "./marker_glide"
import {vehicleViewText} from "./vehicle_view_text"
import {selectionHaloPaint, selectionRingPaint} from "./selection_mark"
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
import {
  BADGE_FONT,
  BADGE_HEIGHT_PIXELS,
  BADGE_SHOULDER_PIXELS,
  CHEVRON_DISTANCE_PIXELS,
  CHEVRON_SIZE_PIXELS,
  GLYPH_IMAGE_PREFIX,
  GLYPH_IMAGE_SIZE_PIXELS,
  GlyphImageKind,
  GLYPH_RADIUS_PIXELS,
  MARKER_RADIUS_PIXELS,
  MARKER_STROKE_WIDTH_PIXELS,
  badgeWidth,
  drawBusGlyph,
  drawChevron,
  drawRouteBadge,
  dotStrokeOpacity,
  glyphStyle,
  parseGlyphImageName,
  routeBadgeStyle
} from "./vehicle_marker_shapes"
import {MotionTierKind, STILL_TIER, isPositionInBounds, markerIdsInBounds, motionSettingsOf, motionTier} from "./motion_tier"
import {
  HeadingKind,
  MarkerPositionKind,
  PathTripKind,
  drawnHeading,
  drawnVehicle,
  headingTurns,
  isAnimated,
  markerPositionKind,
  pathTrip,
  placedAtFetch,
  resumedOnCanvas,
  trackedVehicle,
  turnedHeading
} from "./vehicle_motion"
import {TieKind, reportTie, tiedMarkerIds} from "./report_tie"
import {TIE_REDRAW_INTERVAL_MS} from "./report_tie_layout"
import {PathRequestKind, emptyPathRequests, nextPathRequest, pathRequestReplied, pathsReceived} from "./trip_path_requests"
import {tripPathKey, withTripPaths} from "./trip_path"
import {
  FILE_FETCH_TIMEOUT_MS,
  FileFailure,
  FileKind,
  FileOutcomeKind,
  INDEX_EXPANDED_BYTES_MAX,
  ManifestOutcomeKind,
  SHARD_EXPANDED_BYTES_MAX,
  emptyTripPathFiles,
  fileFetched,
  hasExpectedSize,
  manifestFetched,
  planTripPathFiles
} from "./trip_path_files"
import {PackedOutcome, expandStream} from "./packed_container"
import {preparePath} from "./vehicle_prediction"
import {registerImageResolver} from "./style_images"

const SOURCE_NAME = "vehicle-markers"
const IMAGE_RESOLVER_KEY = "vehicle-markers"
const DOT_LAYER_NAME = "vehicle-markers-dot"
const GLYPH_LAYER_NAME = "vehicle-markers-glyph"

// The layers a vehicle's marker is drawn in: a dot at regional zoom, and a
// bus glyph closer in.
export const markerLayerNames = [DOT_LAYER_NAME, GLYPH_LAYER_NAME]
// The selected vehicle's mark, a halo and a ring under its marker, drawn
// from the markers' source so it moves with the marker.
const SELECTED_HALO_LAYER_NAME = "vehicle-selected-halo"
const SELECTED_RING_LAYER_NAME = "vehicle-selected-ring"
// The vehicles' layers from the lowest up, which another hook's layers go
// under.
export const stackedLayerNames = [SELECTED_HALO_LAYER_NAME, SELECTED_RING_LAYER_NAME, ...markerLayerNames]
const CHEVRON_LAYER_NAME = "vehicle-markers-chevron"
const ROUTE_BADGE_LAYER_NAME = "vehicle-markers-route-badge"
const BADGE_LAYER_NAME = "vehicle-markers-badge"
const IMAGE_PIXEL_RATIO = 2
// The chevron's center stands toward the heading before it turns, and the
// route badge's lower left corner on the glyph's shoulder.
const chevronOffsetPixels = [0, -CHEVRON_DISTANCE_PIXELS]
const routeBadgeOffsetPixels = [BADGE_SHOULDER_PIXELS, -BADGE_SHOULDER_PIXELS]
const HALVING_DIVISOR = 2
// The badge's lower left corner stands this far inside the marker's edge,
// right of and above its center, so the badge sits on its upper right edge.
const BADGE_INSET_PIXELS = 2
const BADGE_OFFSET_PIXELS = [MARKER_RADIUS_PIXELS - BADGE_INSET_PIXELS, BADGE_INSET_PIXELS - MARKER_RADIUS_PIXELS]
const STATUS_OPACITY_FALLBACK = 1
// The key the scheduled markers are held under in place of every agency's.
const SCHEDULED_KEY = "scheduled"
const CAPTION_CLASS_NAME = "panel-detail-caption"
const ROWS_CLASS_NAME = "panel-detail-rows"
const ALERTS_CLASS_NAME = "panel-detail-alerts"
const hasHeading = ["==", ["typeof", ["get", "heading"]], "number"]
const hasRoute = ["==", ["typeof", ["get", "route"]], "string"]
// A badge carries the route's number, or the mark of a status a recent
// report lacks for a vehicle with no route.
const hasRouteBadge = ["any", hasRoute, ["match", ["get", "status"], ["stale", "unknown"], true, false]]
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"

function failureOfError(error) {
  const isDomException = error instanceof DOMException
  const isTimeout = isDomException && error.name === "TimeoutError"

  if (isTimeout) {
    return {kind: FileOutcomeKind.failed, reason: FileFailure.timeout}
  }

  return {kind: FileOutcomeKind.failed, reason: FileFailure.fetch}
}

// The manifest, revalidated with the browser's own conditional request: a
// body whose etag is the held one is unchanged, so the rules keep what they
// hold.
async function fetchManifestOutcome({url, etag}) {
  const signal = AbortSignal.timeout(FILE_FETCH_TIMEOUT_MS)

  try {
    const response = await fetch(url, {signal, cache: "no-cache", credentials: "same-origin", headers: {accept: "application/json"}})

    if (!response.ok) {
      return {kind: ManifestOutcomeKind.failed}
    }

    const manifest = await response.json()
    const received = response.headers.get("etag")

    const isHeldEtag = received !== null && received === etag

    if (isHeldEtag) {
      return {kind: ManifestOutcomeKind.unchanged}
    }

    return {kind: ManifestOutcomeKind.changed, manifest, etag: received}
  } catch {
    // A refused or timed-out fetch and a body that is not JSON are the same
    // outcome to the rules: the manifest is not held.
    return {kind: ManifestOutcomeKind.failed}
  }
}

// One index or shard the manifest or the index names, fetched as the browser
// caches it, of the size named, and expanded within its bound.
async function fetchTripPathFile(file) {
  const signal = AbortSignal.timeout(FILE_FETCH_TIMEOUT_MS)

  try {
    const response = await fetch(file.path, {signal, cache: "default", credentials: "same-origin"})

    if (!response.ok) {
      return {kind: FileOutcomeKind.failed, reason: FileFailure.fetch}
    }

    const buffer = await response.arrayBuffer()

    if (!hasExpectedSize({fetch: file, byteLength: buffer.byteLength})) {
      return {kind: FileOutcomeKind.failed, reason: FileFailure.sizeMismatch}
    }

    let expandedByteSizeMax = SHARD_EXPANDED_BYTES_MAX

    if (file.kind === FileKind.index) {
      expandedByteSizeMax = INDEX_EXPANDED_BYTES_MAX
    }

    const expanded = await expandStream(new Uint8Array(buffer), {expandedByteSizeMax})

    if (expanded.kind === PackedOutcome.refused) {
      return {kind: FileOutcomeKind.failed, reason: FileFailure.decode}
    }

    return {kind: FileOutcomeKind.expanded, bytes: expanded.bytes}
  } catch (error) {
    return failureOfError(error)
  }
}

function point(coordinates) {
  return {type: "Point", coordinates}
}

// Every agency's markers but those of `onCanvas`, which the canvas over the
// map draws, as one GeoJSON collection, a point per marker at `targetOf`
// its marker, with the texts its label and its view show, and the glides
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

// The texts a marker's label and view show, as its feature holds
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

// The image `draw` draws onto a canvas of `width` by `height` CSS pixels,
// scaled to the image's pixel ratio.
function drawnImage({width, height, draw}) {
  const canvas = document.createElement("canvas")
  canvas.width = Math.ceil(width * IMAGE_PIXEL_RATIO)
  canvas.height = Math.ceil(height * IMAGE_PIXEL_RATIO)
  const context = canvas.getContext("2d")
  context.scale(IMAGE_PIXEL_RATIO, IMAGE_PIXEL_RATIO)
  draw(canvas)
  return context.getImageData(0, 0, canvas.width, canvas.height)
}

// The image of the status badge `badge` in the colors of `theme`.
function badgeImage({badge, theme}) {
  const colors = mapColors(theme)
  const draw = (canvas) => { drawStatusBadge(canvas, {badge, ink: colors.badgeInk, paper: colors.badgePaper, x: 0, y: 0}) }
  return drawnImage({width: MARK_SIZE_PIXELS, height: MARK_SIZE_PIXELS, draw})
}

// The image of a glyph's part that `named`, a read glyph image name, names:
// the bus, its chevron, or its route badge.
function glyphPartImage(named) {
  const colors = mapColors(named.theme)

  switch (named.part) {
    case "glyph": {
      const style = glyphStyle({status: named.status, color: named.color, colors})
      const center = GLYPH_IMAGE_SIZE_PIXELS / HALVING_DIVISOR
      const draw = (canvas) => { drawBusGlyph(canvas, {x: center, y: center, style}) }
      return drawnImage({width: GLYPH_IMAGE_SIZE_PIXELS, height: GLYPH_IMAGE_SIZE_PIXELS, draw})
    }
    case "chevron": {
      const draw = (canvas) => { drawChevron(canvas, {color: named.color, halo: colors.glyphLiveOutline}) }
      return drawnImage({width: CHEVRON_SIZE_PIXELS, height: CHEVRON_SIZE_PIXELS, draw})
    }
    case "badge": {
      const badge = routeBadgeStyle({status: named.status, route: named.route, color: named.color, colors})
      const measuring = document.createElement("canvas").getContext("2d")
      measuring.font = BADGE_FONT
      const width = badgeWidth({badge, measure: (text) => measuring.measureText(text).width})
      const draw = (canvas) => { drawRouteBadge(canvas, {badge, width}) }
      return drawnImage({width, height: BADGE_HEIGHT_PIXELS, draw})
    }
    default:
      return unreachable(named.part, "a glyph's part")
  }
}

// The image name of a glyph's `part` for each feature, in `theme`.
function glyphImageExpression({part, theme}) {
  return ["concat", GLYPH_IMAGE_PREFIX, "|", part, "|", ["get", "status"], "|", ["get", "color"], "|", theme, "|", ["coalesce", ["get", "route"], ""]]
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

// A marker the saved schedule places stands for a trip and no vehicle.
function isScheduledTrip(properties) {
  return typeof properties.vehicleId !== "string"
}

// The texts of the view of the vehicle of `properties`, whose status's
// label `statusLabels` holds and whose marker stands at `position`, a
// `MarkerPositionKind`.
function viewTextOf({properties, statusLabels, position}) {
  return vehicleViewText({
    route: properties.route,
    headsign: properties.headsign,
    vehicleId: properties.vehicleId,
    statusLabel: statusLabels.get(properties.status),
    locationAge: properties.locationAge,
    schedule: properties.schedule,
    nextStop: properties.nextStop,
    isScheduledTrip: isScheduledTrip(properties),
    position
  })
}

function textParagraph({className, text}) {
  const paragraph = document.createElement("p")
  paragraph.className = className
  paragraph.textContent = text
  return paragraph
}

// A vehicle's view is built as text nodes: the vehicle identifier comes
// from outside the application and is never parsed as HTML. A muted line
// of where it goes stands under the title, the current alerts of its route
// under that, then its rows and the note on its position.
function vehicleViewContent(text, properties) {
  const routeIds = []

  if (typeof properties.routeId === "string") {
    routeIds.push(properties.routeId)
  }

  const content = document.createElement("div")
  const parts = []

  if (text.meta !== "") {
    parts.push(textParagraph({className: CAPTION_CLASS_NAME, text: text.meta}))
  }

  const alerts = document.createElement("div")
  alerts.className = ALERTS_CLASS_NAME

  for (const alertLine of alertLines({routeIds, stopId: null})) {
    alerts.append(alertLine)
  }

  const rows = document.createElement("dl")
  rows.className = ROWS_CLASS_NAME

  for (const {key, value} of text.rows) {
    const row = document.createElement("div")
    const term = document.createElement("dt")
    term.textContent = key
    const definition = document.createElement("dd")
    definition.textContent = value
    row.append(term, definition)
    rows.append(row)
  }

  parts.push(alerts, rows, textParagraph({className: CAPTION_CLASS_NAME, text: text.note}))

  for (const part of parts) {
    content.append(part)
  }

  return content
}

// The filter of the selected vehicle's mark: the marker of `markerId`, or
// none while no vehicle is selected.
function selectedMarkFilter(markerId) {
  let selectedId = ""

  if (markerId !== null) {
    selectedId = markerId
  }

  return ["==", ["get", "markerId"], selectedId]
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
    this.markersByAgency = new Map()
    this.map = null
    this.drawn = new Map()
    this.gliding = new Map()
    // The chevrons that turn back to their reported headings in the
    // source, after the canvas pointed them along their paths, and the
    // heading the canvas last drew each marker it draws at.
    this.turning = new Map()
    this.canvasHeadings = new Map()
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
    // When the markers move between fetches, the tier decided last, and
    // each vehicle's state between fetches, by marker. Each agency's clock
    // is its fetch time and the page's monotonic time the fetch arrived at,
    // so a skewed device clock moves no marker.
    this.motionSettings = motionSettingsOf(JSON.parse(this.el.dataset.motion))
    // The zoom from which a vehicle is a bus glyph, and below which a dot.
    this.glyphZoomMin = Number(this.el.dataset.glyphZoomMin)
    this.tier = STILL_TIER
    // The vehicles that show their ties, still or moving, and how often a
    // moving tie is drawn again.
    this.tiedIds = []
    this.tieIntervalMs = TIE_REDRAW_INTERVAL_MS
    this.tracked = new Map()
    this.agencyOfMarker = new Map()
    this.clocks = new Map()
    // The trip paths the page holds, each prepared once, and its requests.
    this.pathCache = new Map()
    this.preparedPaths = new WeakMap()
    this.pathRequests = emptyPathRequests()
    // The snapshot's manifest, indexes, and route shards the paths are read
    // from, and the address of the manifest.
    this.tripPathFiles = emptyTripPathFiles()
    this.manifestUrl = this.el.dataset.manifestUrl
    this.isDestroyed = false
    this.reducedMotion = window.matchMedia(REDUCED_MOTION_QUERY)

    this.onVisibilityChange = () => { this.visibilityChanged() }
    this.onReducedMotionChange = () => { this.decideMotion() }
    document.addEventListener("visibilitychange", this.onVisibilityChange)
    this.reducedMotion.addEventListener("change", this.onReducedMotionChange)

    // The view moving to another item, or closing, unmarks the vehicle.
    this.onDetailChange = () => {
      const isViewLeft = this.viewMarkerId !== null && showsDetail({kind: DetailKind.vehicle, id: this.viewMarkerId}) === false

      if (isViewLeft) {
        this.viewMarkerId = null
        this.markSelected()
        this.decideMotion()
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
      const {map} = event.detail
      this.map = null
      this.overlay = null
      this.onCanvas = new Set()
      this.canvasPositionAt = fetchedPosition
      this.tier = STILL_TIER
      this.stopGliding()
      // The map takes sources and layers once its style has loaded.
      map.once("load", () => { this.attach(map) })
    }

    // A style set anew holds none of the layers, nor the source, nor the
    // images of the glyphs, which are made again as they are drawn.
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

  attach(map) {
    // A glyph's images are made the first time a vehicle of their status,
    // color, and route is drawn, since the colors and the routes are the
    // agencies' and not known in advance.
    // MapLibre awaits this resolver before it hands a tile its images, and
    // gives it to every style the map is set to; its "styleimagemissing"
    // event comes after the tile has taken its images without the new one
    // (maplibre-gl 6.12.0, ImageManager._getImagesForIds).
    // A badge's image names its theme, so a style set anew in the other
    // theme asks for images of its own.
    registerImageResolver({map, key: IMAGE_RESOLVER_KEY, resolve: (id) => {
      const named = parseImageName(id)
      const glyph = parseGlyphImageName(id)

      if (glyph.kind === GlyphImageKind.glyph) {
        map.addImage(id, glyphPartImage(glyph), {pixelRatio: IMAGE_PIXEL_RATIO})
      } else if (named.kind === ImageNameKind.badge) {
        const image = badgeImage({badge: named.badge, theme: named.theme})
        map.addImage(id, image, {pixelRatio: IMAGE_PIXEL_RATIO})
      }
    }})

    this.addLayers(map)
    const canvas = map.getCanvas()

    // A map keeps the listeners of a layer while the layer is added again.
    for (const layerName of markerLayerNames) {
      // A tap on a vehicle selects it and shows it in the details view. A
      // vehicle the canvas draws stands above the layers,
      // so a tap it takes opens that vehicle alone.
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
    this.overlay = attachVehicleOverlay({map, statuses: this.statuses, glyphZoomMin: this.glyphZoomMin})
    this.overlay.markSelected(this.viewMarkerId)

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
        this.turning.delete(markerId)
        this.drawn.delete(markerId)
      }
    }

    this.onCanvas = entering
    this.canvasPositionAt = positionAt
    this.updateSource({add: returned, remove: removed})
    this.requestGlideFrame()
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
    this.requestGlideFrame()
  },

  // The features of the markers of `markerIds` the fetches still hold, at
  // the positions the canvas draws them at now, which become their drawn
  // positions in the source, each with its chevron where the canvas drew it,
  // turning back to its reported heading.
  returnedFeatures(markerIds) {
    const byId = markersById(this.markersByAgency)
    const nowMs = performance.now()
    const features = []

    for (const markerId of markerIds) {
      const marker = byId.get(markerId)

      if (marker !== undefined) {
        const position = this.canvasPositionAt({marker, nowMs})
        this.drawn.set(markerId, position)
        const feature = markerFeature({marker, position})
        this.turnBack({feature, nowMs})
        features.push(feature)
      }

      this.canvasHeadings.delete(markerId)
    }

    return features
  },

  // Has the chevron of `feature`, a marker leaving the canvas, start where
  // the canvas drew it and turn to its reported heading, or stand at that
  // heading at once under reduced motion.
  turnBack({feature, nowMs}) {
    const {properties} = feature
    const source = this.canvasHeadings.get(properties.markerId)
    const isHeaded = typeof properties.heading === "number" && source !== undefined
    const isTurn = isHeaded && headingTurns({source, target: properties.heading, reducedMotion: this.reducedMotion.matches})

    if (isTurn) {
      this.turning.set(properties.markerId, {source, target: properties.heading, startMs: nowMs})
      properties.heading = source
    }
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
        const feature = markerFeature({marker, position})
        this.pointAlongPath(feature)
        features.push(feature)
      }
    }

    return features
  },

  // Points the chevron of `feature`, a marker the canvas draws, along its
  // path where it is drawn along it; a marker with no reported heading
  // keeps no chevron.
  pointAlongPath(feature) {
    const {properties} = feature
    const tracked = this.tracked.get(properties.markerId)
    const isHeaded = typeof properties.heading === "number" && tracked !== undefined

    if (!isHeaded) {
      return
    }

    const heading = drawnHeading(tracked)

    if (heading.kind === HeadingKind.alongPath) {
      properties.heading = heading.degrees
    }

    this.canvasHeadings.set(properties.markerId, properties.heading)
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

  // Selects the vehicle of `feature`, a feature of a marker layer, and
  // shows it in the details view.
  openVehicle(feature) {
    this.selectVehicle({properties: feature.properties, lngLat: feature.geometry.coordinates})
  },

  // Marks the vehicle the view shows, in the layers and on the canvas,
  // and unmarks every other.
  markSelected() {
    if (this.map === null) {
      return
    }

    // A map whose style is being set anew has no layer, and adds the mark
    // with the vehicle the view shows then.
    for (const layerName of [SELECTED_HALO_LAYER_NAME, SELECTED_RING_LAYER_NAME]) {
      if (this.map.getLayer(layerName) !== undefined) {
        this.map.setFilter(layerName, selectedMarkFilter(this.viewMarkerId))
      }
    }

    if (this.overlay !== null) {
      this.overlay.markSelected(this.viewMarkerId)
    }
  },

  // Where the marker of `markerId` stands, as its view names it.
  positionOf(markerId) {
    const tracked = this.tracked.get(markerId)

    if (tracked === undefined) {
      return MarkerPositionKind.fetched
    }

    return markerPositionKind(tracked)
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
    const theme = currentTheme()

    // The selected vehicle's halo and ring stand under every marker, round
    // a dot at regional zoom and round a glyph closer in.
    const markerRadius = ["step", ["zoom"], MARKER_RADIUS_PIXELS, this.glyphZoomMin, GLYPH_RADIUS_PIXELS]

    map.addLayer({
      id: SELECTED_HALO_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      filter: selectedMarkFilter(this.viewMarkerId),
      paint: selectionHaloPaint(markerRadius)
    })

    map.addLayer({
      id: SELECTED_RING_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      filter: selectedMarkFilter(this.viewMarkerId),
      paint: selectionRingPaint(markerRadius)
    })

    // At regional zoom every vehicle is a dot in its route's color.
    map.addLayer({
      id: DOT_LAYER_NAME,
      type: "circle",
      source: SOURCE_NAME,
      maxzoom: this.glyphZoomMin,
      paint: {
        "circle-radius": MARKER_RADIUS_PIXELS,
        "circle-color": ["get", "color"],
        "circle-opacity": opacity,
        "circle-stroke-color": colors.vehicleStroke,
        "circle-stroke-width": MARKER_STROKE_WIDTH_PIXELS,
        "circle-stroke-opacity": dotStrokeOpacity({opacity, colors})
      }
    })

    this.addBadgeLayer(map)

    // Closer in every vehicle is a bus glyph, however crowded the street.
    map.addLayer({
      id: GLYPH_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      minzoom: this.glyphZoomMin,
      layout: {
        "icon-image": glyphImageExpression({part: "glyph", theme}),
        "icon-allow-overlap": true,
        "icon-ignore-placement": true
      }
    })

    // The chevron turns with the map, so a heading stays a compass direction
    // on a map that is turned. It is left out where it would cover another
    // chevron or badge, and the glyph stays.
    map.addLayer({
      id: CHEVRON_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      minzoom: this.glyphZoomMin,
      filter: hasHeading,
      layout: {
        "icon-image": glyphImageExpression({part: "chevron", theme}),
        "icon-rotate": ["get", "heading"],
        "icon-rotation-alignment": "map",
        "icon-offset": chevronOffsetPixels,
        "icon-allow-overlap": false
      }
    })

    // The route badge stands on the glyph's shoulder, and is left out where
    // it would cover another badge or chevron; the glyph's fill and outline
    // still tell its status.
    map.addLayer({
      id: ROUTE_BADGE_LAYER_NAME,
      type: "symbol",
      source: SOURCE_NAME,
      minzoom: this.glyphZoomMin,
      filter: hasRouteBadge,
      layout: {
        "icon-image": glyphImageExpression({part: "badge", theme}),
        "icon-anchor": "bottom-left",
        "icon-offset": routeBadgeOffsetPixels,
        "icon-allow-overlap": false
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
      maxzoom: this.glyphZoomMin,
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
      // The collection holds each marker's reported heading.
      this.turning = new Map()
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
  // to the source, asks for the paths the vehicles that show their ties
  // lack, and draws their ties. The vehicles in view show their ties from
  // `TIE_ZOOM_MIN` whatever the tier, and the selected one at any zoom.
  decideMotion() {
    if (this.map === null) {
      return
    }

    const inView = markerIdsInBounds({
      positions: this.drawnPositions(),
      bounds: boundsOf(this.map)
    })

    const zoom = this.map.getZoom()

    this.tier = motionTier({
      settings: this.motionSettings,
      zoom,
      vehicleCountInView: inView.length,
      isReducedMotion: this.reducedMotion.matches,
      isVisible: document.visibilityState === "visible",
      previous: this.tier
    })

    this.tiedIds = tiedMarkerIds({inView, zoom, selectedId: this.viewMarkerId})

    if (this.tier.kind === MotionTierKind.still) {
      this.drawInSource()
    } else {
      this.moveOntoCanvas(inView)
    }

    this.requestPaths(this.tiedIds)
    this.showTies()
  },

  // Moves the vehicles of `inView` that move along their paths onto the
  // canvas, at the tier's rate, and every other back to the source.
  moveOntoCanvas(inView) {
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
  },

  // Draws the ties of the vehicles that show them on the canvas under the
  // vehicles.
  showTies() {
    if (this.overlay === null) {
      return
    }

    this.overlay.showTies({tiesAt: () => this.tiesAt(), intervalMs: this.tieIntervalMs})
  },

  // The ties of the vehicles that show them, as they are drawn: a vehicle
  // on the canvas where the canvas last drew it, and any other at its
  // prediction for its fetch.
  tiesAt() {
    const byId = markersById(this.markersByAgency)
    const ties = []

    for (const markerId of this.tiedIds) {
      const marker = byId.get(markerId)
      const tracked = this.tracked.get(markerId)
      const isHeld = marker !== undefined && tracked !== undefined

      if (isHeld) {
        const tie = reportTie(tracked)

        if (tie.kind === TieKind.tie) {
          ties.push({color: marker.color, ring: tie.ring, line: tie.line})
        }
      }
    }

    return ties
  },

  // Reads the paths of the trips the vehicles of `markerIds` serve that the
  // page lacks from the snapshot's route shards, fetching the files that
  // takes, and asks the server for those the shards cannot serve.
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

    const planned = planTripPathFiles({files: this.tripPathFiles, cache: this.pathCache, trips, nowMs: performance.now()})
    this.tripPathFiles = planned.files

    if (planned.manifest.ask) {
      this.fetchManifest(planned.manifest.etag)
    }

    for (const file of planned.fetches) {
      this.fetchFile(file)
    }

    this.requestFromServer(planned.fallback)
    this.keepPaths(planned.paths)
  },

  // Fetches the manifest and hands the outcome to the files' rules, then
  // decides again which paths the page can read.
  async fetchManifest(etag) {
    const outcome = await fetchManifestOutcome({url: this.manifestUrl, etag})

    if (this.isDestroyed) {
      return
    }

    this.tripPathFiles = manifestFetched({files: this.tripPathFiles, outcome, nowMs: performance.now()})
    this.requestPaths(this.tiedIds)
  },

  // Fetches an index or a shard the same way.
  async fetchFile(file) {
    const outcome = await fetchTripPathFile(file)

    if (this.isDestroyed) {
      return
    }

    this.tripPathFiles = fileFetched({files: this.tripPathFiles, fetch: file, outcome, nowMs: performance.now()})
    this.requestPaths(this.tiedIds)
  },

  // Asks the server for the paths of `trips`, which the snapshot's files
  // cannot serve, as the requests' state allows.
  requestFromServer(trips) {
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

  // Takes the paths of a `trip-paths:paths` event.
  pathsArrived(event) {
    const received = pathsReceived({requests: this.pathRequests, event, nowMs: performance.now()})
    this.pathRequests = received.requests
    this.keepPaths(received.paths)
  },

  // Keeps decoded `paths`, from a shard or an event, anchors again each
  // vehicle of their trips, places a vehicle the source draws at its new
  // prediction, and decides the tier again so they move.
  keepPaths(paths) {
    if (paths.length === 0) {
      return
    }

    this.pathCache = withTripPaths(this.pathCache, paths)
    const byId = markersById(this.markersByAgency)
    const nowMs = performance.now()
    let isPlacedInSource = false

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
        let anchored = trackedVehicle({tracked, marker, path: lookup.path, atMs})

        if (!this.onCanvas.has(markerId)) {
          anchored = placedAtFetch({tracked: anchored, atMs})
          isPlacedInSource = true
        }

        this.tracked.set(markerId, anchored)
      }
    }

    if (isPlacedInSource) {
      this.draw({isSnapped: false})
    }

    this.decideMotion()
    const held = Array.from(byId.values())
    this.updateView(held)
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

  // Shows the vehicle of `properties` in the details view, and moves the
  // map so the vehicle, at `lngLat`, stands beside the sheet.
  selectVehicle({properties, lngLat}) {
    this.viewMarkerId = properties.markerId
    const position = this.positionOf(properties.markerId)
    this.viewText = JSON.stringify({properties, position})
    const text = viewTextOf({properties, statusLabels: this.statusLabels, position})
    showDetail({
      kind: DetailKind.vehicle,
      id: properties.markerId,
      title: text.title,
      content: vehicleViewContent(text, properties)
    })

    this.markSelected()

    if (this.map !== null) {
      revealOnMap({map: this.map, lngLat})
    }

    this.decideMotion()
  },

  // Writes the view of the vehicle it shows from `markers`, one agency's
  // latest fetch or every marker held, where they hold that vehicle. A
  // vehicle no fetch holds any more keeps the view it has.
  updateView(markers) {
    if (this.viewMarkerId === null) {
      return
    }

    const lookup = findMarker({markers, markerId: this.viewMarkerId})

    if (lookup.kind === MarkerLookupKind.missing) {
      return
    }

    // A fetch that leaves the vehicle's texts and where its marker stands as
    // they were leaves the view, and the focus in it, as it is.
    const properties = markerProperties(lookup.marker)
    const position = this.positionOf(properties.markerId)
    const viewText = JSON.stringify({properties, position})

    if (viewText !== this.viewText) {
      this.viewText = viewText
      const text = viewTextOf({properties, statusLabels: this.statusLabels, position})

      updateDetail({
        kind: DetailKind.vehicle,
        id: properties.markerId,
        title: text.title,
        content: vehicleViewContent(text, properties)
      })
    }
  },

  requestGlideFrame() {
    const isMoving = this.gliding.size > 0 || this.turning.size > 0
    const isFrameDue = isMoving && this.frame === null

    if (isFrameDue) {
      this.frame = requestAnimationFrame((frameMs) => { this.glideFrame(frameMs) })
    }
  },

  // One frame moves each gliding marker and turns each turning chevron, and
  // nothing else, in the source. A glide and a turn end after their
  // durations, so the frames stop once every marker has arrived.
  glideFrame(frameMs) {
    this.frame = null
    const source = this.map.getSource(SOURCE_NAME)

    if (source === undefined) {
      this.gliding = new Map()
      this.turning = new Map()
      return
    }

    const updates = new Map()

    for (const [markerId, glide] of this.gliding) {
      const elapsedMs = frameMs - glide.startMs
      const {position, ended} = glidePosition({...glide, elapsedMs})

      updates.set(markerId, {id: markerId, newGeometry: point(position)})
      this.drawn.set(markerId, position)

      if (ended) {
        this.gliding.delete(markerId)
      }
    }

    for (const [markerId, turn] of this.turning) {
      const {degrees, ended} = turnedHeading({...turn, elapsedMs: frameMs - turn.startMs})
      let update = {id: markerId}

      if (updates.has(markerId)) {
        update = updates.get(markerId)
      }

      update.addOrUpdateProperties = [{key: "heading", value: degrees}]
      updates.set(markerId, update)

      if (ended) {
        this.turning.delete(markerId)
      }
    }

    const update = Array.from(updates.values())
    source.updateData({update})
    this.requestGlideFrame()
  },

  stopGliding() {
    if (this.frame !== null) {
      cancelAnimationFrame(this.frame)
      this.frame = null
    }

    this.gliding = new Map()
    this.turning = new Map()
  },

  destroyed() {
    this.isDestroyed = true
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
