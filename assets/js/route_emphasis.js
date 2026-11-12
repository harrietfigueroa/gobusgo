// Which vehicle markers dim while a route's line is emphasized, and the
// event that carries the emphasized route between hooks. Everything here is
// pure and reads no map or document, so each decision is checked against
// values written out by hand.

import {assertCondition} from "./core/assert.js"

/**
 * The DOM event the window gets when the emphasized route changes, whose
 * detail holds `routeId`, the emphasized route's identifier, or null once no
 * route is emphasized.
 */
export const EMPHASIS_EVENT_NAME = "gobusgo:route-emphasis"

/**
 * The share of its own opacity a vehicle marker of another route keeps
 * while a route is emphasized. A marker's shape, glyph, and status badge are
 * drawn at it too, so the status stays readable by form and never by color
 * alone.
 */
export const VEHICLE_DIM_FACTOR = 0.4

const FULL_ALPHA = 1

/**
 * The emphasized route of an emphasis event's `detail`: a route identifier,
 * or null for none.
 */
export function emphasizedRouteOf(detail) {
  const {routeId} = detail
  const isCleared = routeId === null
  const isRoute = typeof routeId === "string" && routeId !== ""
  assertCondition(isCleared || isRoute, `an emphasized route is an identifier or null, got: ${routeId}`)
  return routeId
}

/**
 * The share of its opacity a marker of `routeId` is drawn at while
 * `emphasizedRouteId` is emphasized: whole for the emphasized route's
 * marker and with no route emphasized, `VEHICLE_DIM_FACTOR` for any other.
 */
export function markerAlpha({emphasizedRouteId, routeId}) {
  if (emphasizedRouteId === null) {
    return FULL_ALPHA
  }

  if (routeId === emphasizedRouteId) {
    return FULL_ALPHA
  }

  return VEHICLE_DIM_FACTOR
}

/**
 * The paint value of a marker layer's opacity: `opacity`, a number or an
 * expression, as it is with no route emphasized, and otherwise an
 * expression that keeps it for the emphasized route's markers and multiplies
 * it by `VEHICLE_DIM_FACTOR` for every other marker's.
 */
export function dimmedOpacity({emphasizedRouteId, opacity}) {
  if (emphasizedRouteId === null) {
    return opacity
  }

  return ["case", ["==", ["get", "routeId"], emphasizedRouteId], opacity, ["*", opacity, VEHICLE_DIM_FACTOR]]
}
