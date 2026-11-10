import {MARKER_LAYER_NAME as STOP_MARKER_LAYER_NAME} from "./stop_markers"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"
import {HitKind, overlayHitAt} from "./vehicle_overlay"

// `routeList` and everything above it are pure: the list is a function of
// the features under the pointer, which lets it be run apart from a map.

const TOLERANCE_PIXELS = 4
const ENTRY_COUNT_MAX = 12
const POPUP_OFFSET_PIXELS = 12
const POPUP_WIDTH_MAX = "22rem"
const POPUP_CLASS_NAME = "route-hover"
const HOLD_MS = 300
const HOVER_MEDIA_QUERY = "(hover: hover)"
const nameCollator = new Intl.Collator("en", {numeric: true, sensitivity: "base"})

// The kinds of a read of the list under the pointer.
const ListKind = Object.freeze({found: "found", none: "none"})

// A feature read back from the map has no property for a name the route
// lacks, so a name is a string or absent.
function isSuppliedName(value) {
  const isNonEmptyString = typeof value === "string" && value !== ""
  return isNonEmptyString
}

// What the list shows of one route: the name it goes by, its short name, or
// its long name where it has no short name, or its identifier where it has
// neither; the long name as a detail beside a short name; and its agency.
function routeEntry(properties) {
  const hasShortName = isSuppliedName(properties.shortName)
  const hasLongName = isSuppliedName(properties.longName)
  let name = properties.routeId
  let detail = null
  let agencyName = null

  if (hasShortName) {
    name = properties.shortName
  } else if (hasLongName) {
    name = properties.longName
  }

  const hasDetail = hasShortName && hasLongName

  if (hasDetail) {
    detail = properties.longName
  }

  if (isSuppliedName(properties.agencyName)) {
    agencyName = properties.agencyName
  }

  return {routeId: properties.routeId, color: properties.color, name, detail, agencyName}
}

function agencySortName(entry) {
  if (entry.agencyName === null) {
    return ""
  } else {
    return entry.agencyName
  }
}

// Names in natural order, so route 8 stands before route 40; routes of one
// name by agency, then by identifier, which makes the order total.
function compareEntries(left, right) {
  const byName = nameCollator.compare(left.name, right.name)

  if (byName !== 0) {
    return byName
  }

  const leftAgencyName = agencySortName(left)
  const rightAgencyName = agencySortName(right)
  const byAgency = nameCollator.compare(leftAgencyName, rightAgencyName)

  if (byAgency !== 0) {
    return byAgency
  }

  return nameCollator.compare(left.routeId, right.routeId)
}

// The list of the routes among `features`, the line features under the
// pointer: one entry per route, in name order, at most `ENTRY_COUNT_MAX` of
// them, with the count of the routes left out.
export function routeList(features) {
  const entriesByRoute = new Map()

  // A line that crosses a tile boundary comes back once per tile.
  for (const {properties} of features) {
    entriesByRoute.set(properties.routeId, routeEntry(properties))
  }

  const entries = [...entriesByRoute.values()].sort(compareEntries)
  const shown = entries.slice(0, ENTRY_COUNT_MAX)
  return {entries: shown, hiddenCount: entries.length - shown.length}
}

function textElement({tagName, className, text}) {
  const element = document.createElement(tagName)
  element.className = className
  element.textContent = text
  return element
}

// The list as elements. Every name comes from outside the application and
// is written as text, never parsed as HTML. The entries touch, so a pointer
// that crosses the list is on an entry all the way. `onEntry` is called
// with the route of the entry the pointer enters and with null as it leaves.
function listContent({entries, hiddenCount}, onEntry) {
  const list = document.createElement("ul")
  list.className = "flex flex-col text-sm leading-tight"

  for (const entry of entries) {
    const item = document.createElement("li")
    item.className = "flex items-baseline gap-2 rounded-sm px-1 py-0.5 hover:bg-slate-200"
    item.addEventListener("mouseenter", () => { onEntry(entry.routeId) })
    item.addEventListener("mouseleave", () => { onEntry(null) })

    const swatch = document.createElement("span")
    swatch.className = "inline-block h-1 w-4 shrink-0 self-center rounded-sm"
    swatch.style.backgroundColor = entry.color
    item.appendChild(swatch)
    item.appendChild(textElement({tagName: "span", className: "font-semibold", text: entry.name}))

    if (entry.detail !== null) {
      item.appendChild(textElement({tagName: "span", className: "", text: entry.detail}))
    }

    if (entry.agencyName !== null) {
      item.appendChild(
        textElement({tagName: "span", className: "text-slate-500", text: entry.agencyName})
      )
    }

    list.appendChild(item)
  }

  if (hiddenCount > 0) {
    list.appendChild(
      textElement({tagName: "li", className: "px-1 py-0.5 text-slate-500", text: `and ${hiddenCount} more`})
    )
  }

  return list
}

// The marker layers the style holds; the markers are added by another hook,
// before or after the lines.
function presentLayerNames(map, layerNames) {
  return layerNames.filter((layerName) => map.getLayer(layerName) !== undefined)
}

// Whether `point` is on the marker of a vehicle or a stop, which stands
// above the lines and has a popup of its own, a vehicle the canvas over the
// map draws included.
function onMarker({map, point}) {
  const hit = overlayHitAt({map, point})

  if (hit.kind === HitKind.found) {
    return true
  }

  const markerLayers = presentLayerNames(map, [...vehicleMarkerLayerNames, STOP_MARKER_LAYER_NAME])

  if (markerLayers.length > 0) {
    return map.queryRenderedFeatures(point, {layers: markerLayers}).length > 0
  } else {
    return false
  }
}

// The list of the routes whose lines are within the tolerance of `point`,
// or none off every line and on a style that does not hold the lines, as
// while a style set anew loads.
function listAt({map, point, layerName}) {
  if (map.getLayer(layerName) === undefined) {
    return {kind: ListKind.none}
  }

  const box = [
    [point.x - TOLERANCE_PIXELS, point.y - TOLERANCE_PIXELS],
    [point.x + TOLERANCE_PIXELS, point.y + TOLERANCE_PIXELS]
  ]
  const features = map.queryRenderedFeatures(box, {layers: [layerName]})
  const list = routeList(features)

  if (list.entries.length > 0) {
    return {kind: ListKind.found, list}
  } else {
    return {kind: ListKind.none}
  }
}

function listAtPointer({map, point, layerName}) {
  if (point === null) {
    return {kind: ListKind.none}
  } else if (onMarker({map, point})) {
    return {kind: ListKind.none}
  } else {
    return listAt({map, point, layerName})
  }
}

function entryRouteId({routeId}) {
  return routeId
}

// The state of one map's list: its popup, the pointer's last point on the
// map, whether the pointer is inside the list, and the list that is shown
// with the routes it names.
class RouteHover {
  constructor({map, maplibre, layerName, emphasize, routeDrawn}) {
    this.map = map
    this.maplibre = maplibre
    this.layerName = layerName
    this.emphasize = emphasize
    this.routeDrawn = routeDrawn
    this.popup = new maplibre.Popup({
      closeButton: false,
      closeOnClick: false,
      className: POPUP_CLASS_NAME,
      maxWidth: POPUP_WIDTH_MAX,
      offset: POPUP_OFFSET_PIXELS
    })
    this.point = null
    this.pointerInList = false
    this.shown = null
    this.holdTimer = null
    this.frame = null
  }

  // Pointer moves arrive far faster than the list changes: each one only
  // records the point, and one update a frame reads the last of them.
  pointAt(point) {
    this.point = point
    this.schedule()
  }

  schedule() {
    if (this.frame === null) {
      this.frame = window.requestAnimationFrame(() => { this.update() })
    }
  }

  cancelHold() {
    window.clearTimeout(this.holdTimer)
    this.holdTimer = null
  }

  close() {
    this.cancelHold()
    this.popup.remove()
    this.shown = null
    this.pointerInList = false
    this.emphasize(null)
  }

  // Closes a list that is shown once the pointer has been off the lines it
  // names and out of the list for `HOLD_MS`, then reads the pointer again,
  // so the list of the lines the pointer is on by then opens.
  hold() {
    const isHoldable = this.shown !== null && this.holdTimer === null

    if (isHoldable) {
      this.holdTimer = window.setTimeout(() => {
        this.close()
        this.schedule()
      }, HOLD_MS)
    }
  }

  onListEnter() {
    this.pointerInList = true
    this.cancelHold()
  }

  // The map reports no pointer move over the list, so the point the pointer
  // leaves the list at is read from the event.
  onListLeave(event) {
    const box = this.map.getContainer().getBoundingClientRect()
    this.pointerInList = false
    this.point = new this.maplibre.Point(event.clientX - box.left, event.clientY - box.top)
    this.emphasize(null)
    this.schedule()
  }

  // Opens `list`, the routes at the pointer, anchored at the pointer.
  open(list) {
    const {map, popup} = this
    const routeIds = Array.from(list.entries, entryRouteId)
    this.shown = {key: JSON.stringify(list), routeIds}

    const content = listContent(list, this.emphasize)
    const position = map.unproject(this.point)
    popup.setDOMContent(content)
    popup.setLngLat(position)
    popup.addTo(map)
    // The popup makes its element anew each time it is added.
    popup.getElement().addEventListener("mouseenter", () => { this.onListEnter() })
    popup.getElement().addEventListener("mouseleave", (event) => { this.onListLeave(event) })
  }

  update() {
    this.frame = null

    if (this.pointerInList) {
      // The pointer is off the map's canvas, so no line is read under it:
      // the list stays for as long as every route it names is drawn.
      const isEveryRouteDrawn = this.shown.routeIds.every(this.routeDrawn)

      if (!isEveryRouteDrawn) {
        this.close()
      }
    } else {
      const read = listAtPointer({map: this.map, point: this.point, layerName: this.layerName})

      if (read.kind === ListKind.none) {
        this.hold()
      } else if (this.shown === null) {
        this.open(read.list)
      } else if (JSON.stringify(read.list) === this.shown.key) {
        this.cancelHold()
      } else {
        // Other lines than the list names, as on the way to the list.
        this.hold()
      }
    }
  }

  detach() {
    window.cancelAnimationFrame(this.frame)
    this.cancelHold()
  }
}

// Shows the list of the routes under the pointer on `map`, whose lines are
// the layer `layerName`. The list opens where the pointer meets a set of
// routes and stays there while the pointer is on that set, inside the list,
// or off both for less than `HOLD_MS`, the time a pointer has to travel
// between the lines and the list, other lines on the way included.
// `emphasize` is called with the route of the entry the pointer is on, and
// with null when it is on none, and `routeDrawn` answers whether the layer
// draws the route it is given. A page whose primary pointer cannot hover
// gets no list.
export function attachRouteHover({map, maplibre, layerName, emphasize, routeDrawn}) {
  if (!window.matchMedia(HOVER_MEDIA_QUERY).matches) {
    return
  }

  const hover = new RouteHover({map, maplibre, layerName, emphasize, routeDrawn})

  map.on("mousemove", (event) => { hover.pointAt(event.point) })
  map.on("mouseout", () => { hover.pointAt(null) })

  // The lines under a pointer at rest change when the map moves or when
  // the lines or the markers are drawn again.
  map.on("idle", () => { hover.schedule() })
  map.on("remove", () => { hover.detach() })
}
