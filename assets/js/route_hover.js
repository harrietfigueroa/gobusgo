import {markerLayerName as stopMarkerLayerName} from "./stop_markers"
import {markerLayerNames as vehicleMarkerLayerNames} from "./vehicle_markers"

// Everything above `attachRouteHover` is pure: the list is a function of the
// features under the pointer, which lets it be run apart from a map.

const tolerancePixels = 4
const entryCountMax = 12
const popupOffsetPixels = 12
const popupWidthMax = "22rem"
const popupClassName = "route-hover"
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
// is written as text, never parsed as HTML.
function listContent({entries, hiddenCount}) {
  const list = document.createElement("ul")
  list.className = "flex flex-col gap-1 text-sm leading-tight"

  for (const entry of entries) {
    const item = document.createElement("li")
    item.className = "flex items-baseline gap-2"

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
      textElement({tagName: "li", className: "text-slate-500", text: `and ${hiddenCount} more`})
    )
  }

  return list
}

// The marker layers the style holds; the markers are added by another hook,
// before or after the lines.
function presentLayerNames(map, layerNames) {
  return layerNames.filter((layerName) => map.getLayer(layerName) !== undefined)
}

// The list of the routes at `point`, or null where there is nothing to
// list: off every line, or on the marker of a vehicle or a stop, which stands
// above the lines and has a popup of its own.
function listAt({map, point, layerName}) {
  const markerLayers = presentLayerNames(map, [...vehicleMarkerLayerNames, stopMarkerLayerName])

  if (markerLayers.length > 0 && map.queryRenderedFeatures(point, {layers: markerLayers}).length > 0) {
    return null
  }

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

// Shows the list of the routes under the pointer on `map`, whose lines are
// the layer `layerName`, for as long as the pointer rests on a line. A page
// whose primary pointer cannot hover gets no list.
export function attachRouteHover({map, maplibre, layerName}) {
  if (!window.matchMedia(hoverMediaQuery).matches) {
    return
  }

  const popup = new maplibre.Popup({
    closeButton: false,
    closeOnClick: false,
    className: popupClassName,
    maxWidth: popupWidthMax,
    offset: popupOffsetPixels
  })
  let point = null
  let shownKey = null
  let frame = null

  const update = () => {
    frame = null
    const list = point === null ? null : listAt({map, point, layerName})

    if (list === null) {
      popup.remove()
      shownKey = null
    } else {
      const key = JSON.stringify(list)

      if (key !== shownKey) {
        popup.setDOMContent(listContent(list))
        shownKey = key
      }

      popup.setLngLat(map.unproject(point))

      if (!popup.isOpen()) {
        popup.addTo(map)
      }
    }
  }

  // Pointer moves arrive far faster than the list changes: each one only
  // records the point, and one update a frame reads the last of them.
  const schedule = () => {
    if (frame === null) {
      frame = window.requestAnimationFrame(update)
    }
  }

  map.on("mousemove", (event) => {
    point = event.point
    schedule()
  })

  map.on("mouseout", () => {
    point = null
    schedule()
  })

  // The lines under a pointer at rest change when the map moves or when
  // the lines or the markers are drawn again.
  map.on("idle", schedule)
  map.on("remove", () => { window.cancelAnimationFrame(frame) })
}
