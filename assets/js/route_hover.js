import {unreachable} from "./assert.js"
import {MARKER_LAYER_NAME as STOP_MARKER_LAYER_NAME} from "./stop_markers"
import {isItemAt} from "./map_view_reading"
import {announce} from "./map_live_region"
import {viewBox} from "./map_view_text"
import {sheetInsets} from "./panel_sheet"
import {
  CanvasKeyAction,
  FocusLeaveAction,
  ListKeyAction,
  canvasKeyAction,
  focusLeaveAction,
  isOpenKeyPress,
  listKeyAction,
  noRoutesText,
  openedText
} from "./route_keys"
import {DeviceKind, TapAction, deviceKind, tapAction} from "./route_tap"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"
import {HitKind, overlayHitAt} from "./vehicle_overlay"

// `routeList` and everything above it are pure: the list is a function of
// the features under the pointer, which lets it be run apart from a map.

const TOLERANCE_PIXELS = 4
// Half of the 44 CSS pixel target a finger is given, so a tap within the
// target's reach of a line reads as on it.
// https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html — checked 2026-11-11
const TAP_TOLERANCE_PIXELS = 22
const ENTRY_COUNT_MAX = 12
const POPUP_OFFSET_PIXELS = 12
const POPUP_WIDTH_MAX = "22rem"
const POPUP_CLASS_NAME = "route-hover"
const HOLD_MS = 300
const HOVER_MEDIA_QUERY = "(hover: hover)"
const HOVER_NONE_MEDIA_QUERY = "(hover: none)"
const KEYBOARD_LIST_LABEL = "Routes at the middle of the map"
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
// that crosses the list is on an entry all the way. `onEntry`, a function
// or null, is called with the route of the entry the pointer enters and
// with null as it leaves; `onEntryTap`, a function or null, is called with
// the route of the entry that is tapped.
function listContent({list: {entries, hiddenCount}, onEntry, onEntryTap}) {
  const list = document.createElement("ul")
  list.className = "flex flex-col text-sm leading-tight"

  for (const entry of entries) {
    const item = document.createElement("li")
    item.className = "flex items-baseline gap-2 rounded-sm px-1 py-0.5 hover:bg-slate-200"

    if (onEntry !== null) {
      item.addEventListener("mouseenter", () => { onEntry(entry.routeId) })
      item.addEventListener("mouseleave", () => { onEntry(null) })
    }

    // A tap is a click on a button, which a keyboard and a screen reader
    // reach as they reach no list item; the button is a finger's height.
    let row = item

    if (onEntryTap !== null) {
      row = document.createElement("button")
      row.type = "button"
      row.className = "flex min-h-11 w-full items-center gap-2 text-left"
      row.addEventListener("click", () => { onEntryTap(entry.routeId) })
      item.appendChild(row)
    }

    const swatch = document.createElement("span")
    swatch.className = "inline-block h-1 w-4 shrink-0 self-center rounded-sm"
    swatch.style.backgroundColor = entry.color
    row.appendChild(swatch)
    row.appendChild(textElement({tagName: "span", className: "font-semibold", text: entry.name}))

    if (entry.detail !== null) {
      row.appendChild(textElement({tagName: "span", className: "", text: entry.detail}))
    }

    if (entry.agencyName !== null) {
      row.appendChild(
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

// The list of the routes whose lines are within `toleranceInPixels` of
// `point`, or none off every line and on a style that does not hold the
// lines, as while a style set anew loads.
function listAt({map, point, layerName, toleranceInPixels}) {
  if (map.getLayer(layerName) === undefined) {
    return {kind: ListKind.none}
  }

  const box = [
    [point.x - toleranceInPixels, point.y - toleranceInPixels],
    [point.x + toleranceInPixels, point.y + toleranceInPixels]
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
    return listAt({map, point, layerName, toleranceInPixels: TOLERANCE_PIXELS})
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

    const content = listContent({list, onEntry: this.emphasize, onEntryTap: null})
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

// The state of one map's list on a device that cannot hover: its popup and
// the routes the list shown names, or null while none is shown.
class RouteTap {
  constructor({map, maplibre, layerName, emphasize, routeDrawn}) {
    this.map = map
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
    this.routeIds = null
  }

  // The map fires `click` only for a press and release within its click
  // tolerance of each other, so the end of a pan or a zoom is no tap.
  // https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/MapOptions/#clicktolerance — checked 2026-11-10
  onTap(event) {
    const {map, layerName} = this
    const isItemHit = isItemAt({map, point: event.point})
    const read = listAt({map, point: event.point, layerName, toleranceInPixels: TAP_TOLERANCE_PIXELS})
    const action = tapAction({
      kind: DeviceKind.touch,
      isItemHit,
      hasLines: read.kind === ListKind.found,
      isShown: this.routeIds !== null
    })

    if (action === TapAction.open) {
      this.open({list: read.list, point: event.point})
    } else if (action === TapAction.close) {
      this.close()
    }
  }

  // Opens `list`, anchored at `point`, in place of the list that is shown.
  open({list, point}) {
    this.close()
    this.routeIds = Array.from(list.entries, entryRouteId)

    const content = listContent({list, onEntry: null, onEntryTap: this.emphasize})
    this.popup.setDOMContent(content)
    this.popup.setLngLat(this.map.unproject(point))
    this.popup.addTo(this.map)
  }

  close() {
    if (this.routeIds !== null) {
      this.popup.remove()
      this.routeIds = null
      this.emphasize(null)
    }
  }

  // A filter can stop the layer drawing a route the list names.
  onIdle() {
    const isShown = this.routeIds !== null
    const isStale = isShown && !this.routeIds.every(this.routeDrawn)

    if (isStale) {
      this.close()
    }
  }
}

// The state of one map's list for a keyboard, which a device of either kind
// can have: its popup and the routes the list shown names, or null while
// none is shown. Its entries are the buttons of the tap list, so a key
// press on one emphasizes its route as a tap does, and focus on one
// emphasizes the route as the pointer on one does.
class RouteKeys {
  constructor({map, maplibre, layerName, emphasize, routeDrawn}) {
    this.map = map
    this.layerName = layerName
    this.emphasize = emphasize
    this.routeDrawn = routeDrawn
    this.popup = new maplibre.Popup({
      closeButton: false,
      closeOnClick: false,
      className: POPUP_CLASS_NAME,
      maxWidth: POPUP_WIDTH_MAX,
      offset: POPUP_OFFSET_PIXELS,
      focusAfterOpen: false
    })
    this.routeIds = null
    this.buttons = []
  }

  // The middle of the part of the map the panel sheet leaves in sight, the
  // place the list of what is in view counts from.
  middle() {
    const container = this.map.getContainer()
    const {center} = viewBox({
      width: container.clientWidth,
      height: container.clientHeight,
      insets: sheetInsets()
    })
    return center
  }

  onCanvasKeydown(event) {
    const modifiers = {
      key: event.key,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey
    }

    // Every key reaches the canvas, the arrows a held key repeats among
    // them, and only the letter reads the map.
    if (!isOpenKeyPress(modifiers)) {
      return
    }

    event.preventDefault()
    const point = this.middle()
    const read = listAt({map: this.map, point, layerName: this.layerName, toleranceInPixels: TAP_TOLERANCE_PIXELS})
    const action = canvasKeyAction({...modifiers, hasLines: read.kind === ListKind.found})

    if (action === CanvasKeyAction.open) {
      this.open({list: read.list, point})
    } else if (action === CanvasKeyAction.announceNone) {
      this.close()
      announce(noRoutesText())
    } else if (action === CanvasKeyAction.pass) {
      return
    } else {
      unreachable(action, "an unknown canvas key action")
    }
  }

  // Opens `list`, anchored at `point`, in place of the list that is shown,
  // moves focus to its first entry, and has the list read.
  open({list, point}) {
    this.close()
    this.routeIds = Array.from(list.entries, entryRouteId)

    const content = listContent({list, onEntry: null, onEntryTap: this.emphasize})
    content.setAttribute("aria-label", KEYBOARD_LIST_LABEL)
    content.addEventListener("keydown", (event) => { this.onListKeydown(event) })
    content.addEventListener("focusin", (event) => { this.onFocusIn(event) })
    content.addEventListener("focusout", (event) => { this.onFocusOut({event, content}) })
    this.buttons = Array.from(content.querySelectorAll("button"))
    this.popup.setDOMContent(content)
    this.popup.setLngLat(this.map.unproject(point))
    this.popup.addTo(this.map)
    this.buttons[0].focus()
    announce(openedText({count: list.entries.length, hiddenCount: list.hiddenCount}))
  }

  onListKeydown(event) {
    const index = this.buttons.indexOf(event.target)
    const isEntry = index >= 0

    if (!isEntry) {
      return
    }

    const action = listKeyAction({key: event.key, index, count: this.buttons.length})

    if (action.kind === ListKeyAction.close) {
      event.preventDefault()
      this.close()
    } else if (action.kind === ListKeyAction.focus) {
      event.preventDefault()
      this.buttons[action.index].focus()
    } else if (action.kind === ListKeyAction.pass) {
      return
    } else {
      unreachable(action.kind, "an unknown list key action")
    }
  }

  onFocusIn(event) {
    const index = this.buttons.indexOf(event.target)

    if (index >= 0) {
      this.emphasize(this.routeIds[index])
    }
  }

  onFocusOut({event, content}) {
    const isStillInList = event.relatedTarget !== null && content.contains(event.relatedTarget)
    const action = focusLeaveAction({isStillInList})

    if (action === FocusLeaveAction.close) {
      this.close()
    } else if (action === FocusLeaveAction.keep) {
      return
    } else {
      unreachable(action, "an unknown focus leave action")
    }
  }

  close() {
    if (this.routeIds !== null) {
      const isFocusInList = this.popup.getElement().contains(document.activeElement)

      // The state clears first: removing the popup from under the focused
      // entry fires `focusout` at once, which closes the list again.
      this.routeIds = null
      this.buttons = []

      // Focus on an entry goes back to the map, where the list was opened
      // from, as the entry goes; it would fall to the page's body.
      if (isFocusInList) {
        this.map.getCanvas().focus()
      }

      this.popup.remove()
      this.emphasize(null)
    }
  }

  // A filter can stop the layer drawing a route the list names.
  onIdle() {
    const isShown = this.routeIds !== null
    const isStale = isShown && !this.routeIds.every(this.routeDrawn)

    if (isStale) {
      this.close()
    }
  }
}

function attachKeys({map, maplibre, layerName, emphasize, routeDrawn}) {
  const keys = new RouteKeys({map, maplibre, layerName, emphasize, routeDrawn})

  map.getCanvas().addEventListener("keydown", (event) => { keys.onCanvasKeydown(event) })
  map.on("movestart", () => { keys.close() })
  map.on("zoomstart", () => { keys.close() })
  map.on("idle", () => { keys.onIdle() })
  map.on("remove", () => { keys.close() })
}

function attachHover({map, maplibre, layerName, emphasize, routeDrawn}) {
  const hover = new RouteHover({map, maplibre, layerName, emphasize, routeDrawn})

  map.on("mousemove", (event) => { hover.pointAt(event.point) })
  map.on("mouseout", () => { hover.pointAt(null) })

  // The lines under a pointer at rest change when the map moves or when
  // the lines or the markers are drawn again.
  map.on("idle", () => { hover.schedule() })
  map.on("remove", () => { hover.detach() })
}

function attachTap({map, maplibre, layerName, emphasize, routeDrawn}) {
  const tap = new RouteTap({map, maplibre, layerName, emphasize, routeDrawn})

  map.on("click", (event) => { tap.onTap(event) })
  map.on("movestart", () => { tap.close() })
  map.on("zoomstart", () => { tap.close() })
  map.on("idle", () => { tap.onIdle() })
  map.on("remove", () => { tap.close() })
}

// Shows the list of the routes under the pointer on `map`, whose lines are
// the layer `layerName`. `emphasize` is called with the route of the entry
// the pointer is on or that is tapped, and with null when the list closes
// or the pointer is on none, and `routeDrawn` answers whether the layer
// draws the route it is given. The device kind is read once, here. A device
// whose primary pointer can hover opens the list where the pointer meets a
// set of routes and keeps it there while the pointer is on that set, inside
// the list, or off both for less than `HOLD_MS`, the time a pointer has to
// travel between the lines and the list, other lines on the way included;
// a tap does nothing. A device whose primary pointer cannot hover opens it
// at a tap within `TAP_TOLERANCE_PIXELS` of a line that hits no marker, and
// closes it at a tap elsewhere or a move or zoom of the map. A device of
// either kind opens it for a keyboard: the letter `r` on the focused map
// lists the routes within `TAP_TOLERANCE_PIXELS` of the middle of the map,
// and announces that there are none where there are none; focus moves to
// the first entry, and focus on an entry emphasizes its route, until focus
// leaves the list, Escape returns it to the map, or the map moves.
export function attachRouteList({map, maplibre, layerName, emphasize, routeDrawn}) {
  const isHoverNone = window.matchMedia(HOVER_NONE_MEDIA_QUERY).matches
  const kind = deviceKind({isHoverNone})

  attachKeys({map, maplibre, layerName, emphasize, routeDrawn})

  if (kind === DeviceKind.touch) {
    attachTap({map, maplibre, layerName, emphasize, routeDrawn})
  } else if (window.matchMedia(HOVER_MEDIA_QUERY).matches) {
    attachHover({map, maplibre, layerName, emphasize, routeDrawn})
  }
}
