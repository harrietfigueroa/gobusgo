// The hook of the list of the vehicles, stops, and shared vehicles in view
// of the vehicle map, a WAI-ARIA listbox that keeps focus on itself and marks its active
// option with `aria-activedescendant`. On each map the basemap announces,
// it writes the list each time the map is idle, by the imported rules, and
// keeps the active option where the item stays in view. Down, Up, Home,
// and End move the active option, and Enter or a click opens its item as a
// click on the item's marker does, through the window's open event.
// https://www.w3.org/WAI/ARIA/apg/patterns/listbox/ — checked 2026-11-09

import {READY_EVENT_NAME} from "./basemap"
import {itemKey, itemsInView, ListKey, MapItemKind, nextActiveIndex, OPEN_EVENT_NAME} from "./map_items"
import {readView, screenPoint} from "./map_view_reading"

const ITEM_COUNT_MAX = 20
const LIST_ID = "map-items-list"
const REST_ID = "map-items-rest"
const OPTION_ID_PREFIX = "map-item-"
const NO_ACTIVE_KEY = ""

const listKeysByKey = Object.freeze({
  ArrowDown: ListKey.down,
  ArrowUp: ListKey.up,
  Home: ListKey.home,
  End: ListKey.end
})

function vehicleEntry({map, feature}) {
  const {markerId, route, headsign, vehicleId} = feature.properties
  const {x, y} = screenPoint({map, feature})
  return {id: markerId, route, headsign, vehicleId, x, y}
}

function stopEntry({map, feature}) {
  const {stopId, name, direction, routes} = feature.properties
  const {x, y} = screenPoint({map, feature})
  return {id: stopId, name, direction, routes, x, y}
}

function sharedVehicleEntry({map, feature}) {
  const {vehicleKey, formLabel, operatorName, rangeMeters} = feature.properties
  const {x, y} = screenPoint({map, feature})
  return {id: vehicleKey, formLabel, operatorName, rangeMeters, x, y}
}

// The line under the list: how many items the list leaves out, and that
// zooming in lists the stops where the zoom draws none.
function restText({restCount, stopsDrawn, itemCount}) {
  const parts = []

  if (itemCount === 0) {
    parts.push("Nothing in view.")
  }

  if (restCount > 0) {
    parts.push(`${restCount} more in view; zoom in to list them.`)
  }

  if (!stopsDrawn) {
    parts.push("Zoom in to list the stops.")
  }

  return parts.join(" ")
}

// The plain copy of a rendered feature the open event carries, which holds
// what a click's feature hands a marker's listener.
function featureCopy(feature) {
  return {properties: feature.properties, geometry: {coordinates: feature.geometry.coordinates}}
}

export const MapItemList = {
  mounted() {
    this.map = null
    this.list = document.getElementById(LIST_ID)
    this.rest = document.getElementById(REST_ID)
    this.items = []
    this.features = new Map()
    this.activeKey = NO_ACTIVE_KEY
    this.signature = ""

    this.onBasemapReady = (event) => { this.attach(event.detail.map) }
    window.addEventListener(READY_EVENT_NAME, this.onBasemapReady)

    this.list.addEventListener("keydown", (event) => { this.onKeydown(event) })
    this.list.addEventListener("focus", () => { this.ensureActive() })
    this.list.addEventListener("click", (event) => { this.onClick(event) })
  },

  attach(map) {
    this.map = map
    map.on("idle", () => {
      if (this.map === map) {
        this.write()
      }
    })
  },

  // Writes the items in view in place of the list's, unless they are the
  // same items with the same texts in the same order.
  write() {
    const map = this.map
    const {center, vehicles, stops, sharedVehicles, stopsDrawn} = readView(map)
    const features = new Map()
    const vehicleEntries = []
    const stopEntries = []
    const sharedVehicleEntries = []

    for (const feature of vehicles.values()) {
      const entry = vehicleEntry({map, feature})
      vehicleEntries.push(entry)
      features.set(itemKey({kind: MapItemKind.vehicle, id: entry.id}), feature)
    }

    for (const feature of stops.values()) {
      const entry = stopEntry({map, feature})
      stopEntries.push(entry)
      features.set(itemKey({kind: MapItemKind.stop, id: entry.id}), feature)
    }

    for (const feature of sharedVehicles.values()) {
      const entry = sharedVehicleEntry({map, feature})
      sharedVehicleEntries.push(entry)
      features.set(itemKey({kind: MapItemKind.sharedVehicle, id: entry.id}), feature)
    }

    const {items, restCount} = itemsInView({
      vehicles: vehicleEntries,
      stops: stopEntries,
      sharedVehicles: sharedVehicleEntries,
      center,
      countMax: ITEM_COUNT_MAX
    })
    this.features = features
    this.rest.textContent = restText({restCount, stopsDrawn, itemCount: items.length})

    const signature = JSON.stringify(items)

    if (signature === this.signature) {
      return
    }

    this.signature = signature
    this.items = items
    this.renderOptions()
  },

  renderOptions() {
    const options = document.createDocumentFragment()

    for (const [index, item] of this.items.entries()) {
      const option = document.createElement("li")
      option.id = `${OPTION_ID_PREFIX}${index}`
      option.setAttribute("role", "option")
      option.dataset.key = itemKey(item)
      option.textContent = item.text
      options.append(option)
    }

    this.list.replaceChildren(options)
    const isActiveKept = this.activeIndex() >= 0

    if (!isActiveKept) {
      this.activeKey = NO_ACTIVE_KEY
    }

    if (document.activeElement === this.list) {
      this.ensureActive()
    }

    this.markActive()
  },

  activeIndex() {
    return this.items.findIndex((item) => itemKey(item) === this.activeKey)
  },

  // A list that takes focus with no active option makes its first active.
  ensureActive() {
    const hasItems = this.items.length > 0
    const isUnset = this.activeIndex() < 0

    const isActivated = hasItems && isUnset

    if (isActivated) {
      this.activeKey = itemKey(this.items[0])
      this.markActive()
    }
  },

  markActive() {
    const activeIndex = this.activeIndex()

    for (const [index, option] of Array.from(this.list.children).entries()) {
      option.setAttribute("aria-selected", String(index === activeIndex))
    }

    if (activeIndex < 0) {
      this.list.removeAttribute("aria-activedescendant")
      return
    }

    const option = this.list.children[activeIndex]
    this.list.setAttribute("aria-activedescendant", option.id)
    option.scrollIntoView({block: "nearest"})
  },

  onKeydown(event) {
    const listKey = listKeysByKey[event.key]
    const hasItems = this.items.length > 0

    if (event.key === "Enter") {
      event.preventDefault()
      this.open(this.activeIndex())
      return
    }

    const isMove = listKey !== undefined && hasItems

    if (isMove) {
      event.preventDefault()
      this.ensureActive()
      const activeIndex = nextActiveIndex({key: listKey, activeIndex: this.activeIndex(), count: this.items.length})
      this.activeKey = itemKey(this.items[activeIndex])
      this.markActive()
    }
  },

  onClick(event) {
    const option = event.target.closest("[role=option]")

    if (option === null) {
      return
    }

    const index = this.items.findIndex((item) => itemKey(item) === option.dataset.key)
    this.activeKey = option.dataset.key
    this.markActive()
    this.open(index)
  },

  // Opens the item at `index`, as a click on its marker does; an index
  // outside the list opens nothing.
  open(index) {
    const isInList = index >= 0 && index < this.items.length

    if (!isInList) {
      return
    }

    const item = this.items[index]
    const feature = this.features.get(itemKey(item))

    if (feature === undefined) {
      return
    }

    window.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {detail: {kind: item.kind, feature: featureCopy(feature)}}))
  },

  destroyed() {
    window.removeEventListener(READY_EVENT_NAME, this.onBasemapReady)
  }
}
