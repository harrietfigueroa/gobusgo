import {markerLayerName as stopMarkerLayerName} from "./stop_markers"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"

// Everything above `attachRouteHover` is pure: the list is a function of the
// features under the pointer, which lets it be run apart from a map.

const tolerancePixels = 4
const entryCountMax = 12
const popupOffsetPixels = 12
const popupWidthMax = "22rem"
const popupClassName = "route-hover"
const holdMs = 300
const hoverMediaQuery = "(hover: hover)"
const nameCollator = new Intl.Collator("en", {numeric: true, sensitivity: "base"})

// A feature read back from the map has no property for a name the route
// lacks, so a name is a string or absent.
function suppliedName(value) {
  if (typeof value === "string" && value !== "") {
    return value
  } else {
    return null
  }
}

// What the list shows of one route: the name it goes by, its short name, or
// its long name where it has no short name, or its identifier where it has
// neither; the long name as a detail beside a short name; and its agency.
function routeEntry(properties) {
  const shortName = suppliedName(properties.shortName)
  const longName = suppliedName(properties.longName)
  const name = shortName ?? longName ?? properties.routeId

  return {
    routeId: properties.routeId,
    color: properties.color,
    name,
    detail: shortName === null ? null : longName,
    agencyName: suppliedName(properties.agencyName)
  }
}

// Names in natural order, so route 8 stands before route 40; routes of one
// name by agency, then by identifier, which makes the order total.
function compareEntries(left, right) {
  return nameCollator.compare(left.name, right.name) ||
    nameCollator.compare(left.agencyName ?? "", right.agencyName ?? "") ||
    nameCollator.compare(left.routeId, right.routeId)
}

// The list of the routes among `features`, the line features under the
// pointer: one entry per route, in name order, at most `entryCountMax` of
// them, with the count of the routes left out.
export function routeList(features) {
  const entriesByRoute = new Map()

  // A line that crosses a tile boundary comes back once per tile.
  for (const {properties} of features) {
    entriesByRoute.set(properties.routeId, routeEntry(properties))
  }

  const entries = [...entriesByRoute.values()].sort(compareEntries)
  const shown = entries.slice(0, entryCountMax)
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
// above the lines and has a popup of its own.
function onMarker({map, point}) {
  const markerLayers = presentLayerNames(map, [...vehicleMarkerLayerNames, stopMarkerLayerName])

  if (markerLayers.length > 0) {
    return map.queryRenderedFeatures(point, {layers: markerLayers}).length > 0
  } else {
    return false
  }
}

// The list of the routes whose lines are within the tolerance of `point`,
// or null off every line.
function listAt({map, point, layerName}) {
  const box = [
    [point.x - tolerancePixels, point.y - tolerancePixels],
    [point.x + tolerancePixels, point.y + tolerancePixels]
  ]
  const list = routeList(map.queryRenderedFeatures(box, {layers: [layerName]}))

  if (list.entries.length > 0) {
    return list
  } else {
    return null
  }
}

// Everything below takes `hover`, the state of one map's list: its popup,
// the pointer's last point on the map, whether the pointer is inside the
// list, and the list that is shown with the routes it names.

// Pointer moves arrive far faster than the list changes: each one only
// records the point, and one update a frame reads the last of them.
function schedule(hover) {
  if (hover.frame === null) {
    hover.frame = window.requestAnimationFrame(() => { update(hover) })
  }
}

function cancelHold(hover) {
  window.clearTimeout(hover.holdTimer)
  hover.holdTimer = null
}

function close(hover) {
  cancelHold(hover)
  hover.popup.remove()
  hover.shown = null
  hover.pointerInList = false
  hover.emphasize(null)
}

// Closes a list that is shown once the pointer has been off the lines it
// names and out of the list for `holdMs`, then reads the pointer again, so
// the list of the lines the pointer is on by then opens.
function hold(hover) {
  if (hover.shown !== null && hover.holdTimer === null) {
    hover.holdTimer = window.setTimeout(() => {
      close(hover)
      schedule(hover)
    }, holdMs)
  }
}

function onListEnter(hover) {
  hover.pointerInList = true
  cancelHold(hover)
}

// The map reports no pointer move over the list, so the point the pointer
// leaves the list at is read from the event.
function onListLeave(hover, event) {
  const box = hover.map.getContainer().getBoundingClientRect()
  hover.pointerInList = false
  hover.point = new hover.maplibre.Point(event.clientX - box.left, event.clientY - box.top)
  hover.emphasize(null)
  schedule(hover)
}

// Opens `list`, the routes at the pointer, anchored at the pointer.
function open(hover, list) {
  const {map, popup} = hover
  hover.shown = {key: JSON.stringify(list), routeIds: list.entries.map(({routeId}) => routeId)}
  popup.setDOMContent(listContent(list, hover.emphasize))
  popup.setLngLat(map.unproject(hover.point))
  popup.addTo(map)
  // The popup makes its element anew each time it is added.
  popup.getElement().addEventListener("mouseenter", () => { onListEnter(hover) })
  popup.getElement().addEventListener("mouseleave", (event) => { onListLeave(hover, event) })
}

function listAtPointer({map, point, layerName}) {
  if (point === null) {
    return null
  } else if (onMarker({map, point})) {
    return null
  } else {
    return listAt({map, point, layerName})
  }
}

function update(hover) {
  hover.frame = null

  if (hover.pointerInList) {
    // The pointer is off the map's canvas, so no line is read under it: the
    // list stays for as long as every route it names is drawn.
    if (!hover.shown.routeIds.every(hover.routeDrawn)) {
      close(hover)
    }
  } else {
    const list = listAtPointer(hover)

    if (list === null) {
      hold(hover)
    } else if (hover.shown === null) {
      open(hover, list)
    } else if (JSON.stringify(list) === hover.shown.key) {
      cancelHold(hover)
    } else {
      // Other lines than the list names, as on the way to the list.
      hold(hover)
    }
  }
}

// Shows the list of the routes under the pointer on `map`, whose lines are
// the layer `layerName`. The list opens where the pointer meets a set of
// routes and stays there while the pointer is on that set, inside the list,
// or off both for less than `holdMs`, the time a pointer has to travel
// between the lines and the list, other lines on the way included.
// `emphasize` is called with the route of the entry the pointer is on, and
// with null when it is on none, and `routeDrawn` answers whether the layer
// draws the route it is given. A page whose primary pointer cannot hover
// gets no list.
export function attachRouteHover({map, maplibre, layerName, emphasize, routeDrawn}) {
  if (!window.matchMedia(hoverMediaQuery).matches) {
    return
  }

  const hover = {
    map,
    maplibre,
    layerName,
    emphasize,
    routeDrawn,
    popup: new maplibre.Popup({
      closeButton: false,
      closeOnClick: false,
      className: popupClassName,
      maxWidth: popupWidthMax,
      offset: popupOffsetPixels
    }),
    point: null,
    pointerInList: false,
    shown: null,
    holdTimer: null,
    frame: null
  }

  map.on("mousemove", (event) => {
    hover.point = event.point
    schedule(hover)
  })

  map.on("mouseout", () => {
    hover.point = null
    schedule(hover)
  })

  // The lines under a pointer at rest change when the map moves or when
  // the lines or the markers are drawn again.
  map.on("idle", () => { schedule(hover) })

  map.on("remove", () => {
    window.cancelAnimationFrame(hover.frame)
    cancelHold(hover)
  })
}
