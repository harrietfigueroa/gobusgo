// The list of the vehicles, stops, and shared vehicles in view of the
// vehicle map, which a
// keyboard reaches them by: which items it holds, in what order, the text
// of each option, and how the keys move the active option. Everything here
// is pure and reads no map or document, so each decision is checked against
// values written out by hand.

import {assertCondition, unreachable} from "./assert.js"

export const MapItemKind = Object.freeze({vehicle: "vehicle", stop: "stop", sharedVehicle: "sharedVehicle"})

export const ListKey = Object.freeze({down: "down", up: "up", home: "home", end: "end"})

/**
 * The DOM event the window gets when the list opens an item, whose detail
 * holds the item's kind and its rendered feature, as a click on the
 * item's marker hands its listener.
 */
export const OPEN_EVENT_NAME = "gobusgo:map-item-open"

// A vehicle comes before a stop, and a stop before a shared vehicle, as
// near the middle.
const kindRank = Object.freeze({[MapItemKind.vehicle]: 0, [MapItemKind.stop]: 1, [MapItemKind.sharedVehicle]: 2})

function isSupplied(value) {
  return typeof value === "string" && value !== ""
}

function vehicleText({route, headsign, vehicleId}) {
  const hasRoute = isSupplied(route)
  const hasHeadsign = isSupplied(headsign)
  const isNamed = hasRoute && hasHeadsign

  if (isNamed) {
    return `Vehicle, ${route} to ${headsign}`
  }

  if (hasRoute) {
    return `Vehicle, ${route}`
  }

  if (hasHeadsign) {
    return `Vehicle to ${headsign}`
  }

  if (isSupplied(vehicleId)) {
    return `Vehicle ${vehicleId}`
  }

  return "Vehicle"
}

function stopText({id, name, direction, routes}) {
  if (!isSupplied(name)) {
    return `Stop ${id}`
  }

  const parts = [`Stop, ${name}`]

  if (isSupplied(direction)) {
    parts.push(direction)
  }

  if (isSupplied(routes)) {
    parts.push(`routes ${routes}`)
  }

  return parts.join(", ")
}

function sharedVehicleText({formLabel, operatorName}) {
  if (isSupplied(operatorName)) {
    return `${formLabel}, ${operatorName}`
  }

  return formLabel
}

function placedItem({kind, id, text, x, y, center}) {
  const offsetX = x - center.x
  const offsetY = y - center.y
  return {kind, id, text, distanceSquared: offsetX * offsetX + offsetY * offsetY}
}

// Nearest first; then a vehicle before a stop, then by text, then by
// identifier, so the order is the same for the same view.
function compareItems(left, right) {
  const distanceOrder = left.distanceSquared - right.distanceSquared

  if (distanceOrder !== 0) {
    return distanceOrder
  }

  const kindOrder = kindRank[left.kind] - kindRank[right.kind]

  if (kindOrder !== 0) {
    return kindOrder
  }

  const textOrder = left.text.localeCompare(right.text)

  if (textOrder !== 0) {
    return textOrder
  }

  return left.id.localeCompare(right.id)
}

/**
 * The options of the list: of `vehicles`, each its marker's identifier,
 * route, headsign, and vehicle identifier, `stops`, each its identifier,
 * name, direction, and routes, and `sharedVehicles`, each its key, kind's
 * label, and operator, all at a point on the screen; the `countMax`
 * nearest `center` first, each with its kind, identifier, and text, and
 * the count of the items left out.
 */
export function itemsInView({vehicles, stops, sharedVehicles, center, countMax}) {
  assertCondition(Number.isSafeInteger(countMax), `countMax must be an integer, got: ${countMax}`)
  assertCondition(countMax > 0, `countMax must be positive, got: ${countMax}`)

  const placed = []

  for (const vehicle of vehicles) {
    const text = vehicleText(vehicle)
    placed.push(placedItem({kind: MapItemKind.vehicle, id: vehicle.id, text, x: vehicle.x, y: vehicle.y, center}))
  }

  for (const stop of stops) {
    const text = stopText(stop)
    placed.push(placedItem({kind: MapItemKind.stop, id: stop.id, text, x: stop.x, y: stop.y, center}))
  }

  for (const shared of sharedVehicles) {
    const text = sharedVehicleText(shared)
    placed.push(placedItem({kind: MapItemKind.sharedVehicle, id: shared.id, text, x: shared.x, y: shared.y, center}))
  }

  placed.sort(compareItems)

  const items = []

  for (const {kind, id, text} of placed) {
    if (items.length === countMax) {
      break
    }

    items.push({kind, id, text})
  }

  return {items, restCount: placed.length - items.length}
}

/** The key that tells an item from every other of the list, whatever its place. */
export function itemKey({kind, id}) {
  return `${kind}:${id}`
}

/**
 * The index of the active option after `key` in a list of `count` options
 * whose active option is at `activeIndex`. The arrows stop at the ends.
 */
export function nextActiveIndex({key, activeIndex, count}) {
  assertCondition(count > 0, `a list with no option has no active one, got count: ${count}`)
  assertCondition(activeIndex >= 0, `activeIndex must not be negative, got: ${activeIndex}`)
  assertCondition(activeIndex < count, `activeIndex must be under the count ${count}, got: ${activeIndex}`)

  const lastIndex = count - 1

  switch (key) {
    case ListKey.down:
      return Math.min(activeIndex + 1, lastIndex)
    case ListKey.up:
      return Math.max(activeIndex - 1, 0)
    case ListKey.home:
      return 0
    case ListKey.end:
      return lastIndex
    default:
      return unreachable(key, "an unknown list key")
  }
}
