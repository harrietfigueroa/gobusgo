// Which vehicle markers dim while routes' lines are emphasized, the event
// that carries the emphasized routes between hooks, and how the lists of the
// routes under a pointer, a tap, or a key move the emphasis. Everything here
// is pure and reads no map or document, so each decision is checked against
// values written out by hand.

import {assertCondition, unreachable} from "./core/assert.js"

/**
 * The DOM event the window gets when the emphasized routes change, whose
 * detail holds `routeIds`, the emphasized routes' identifiers, an empty array
 * once no route is emphasized.
 */
export const EMPHASIS_EVENT_NAME = "gobusgo:route-emphasis"

/**
 * The share of its own opacity a vehicle marker of another route keeps
 * while routes are emphasized. A marker's shape, glyph, and status badge are
 * drawn at it too, so the status stays readable by form and never by color
 * alone.
 */
export const VEHICLE_DIM_FACTOR = 0.4

const FULL_ALPHA = 1

/** The sources of emphasis, each of which owns the claim it makes. */
export const EmphasisOwner = Object.freeze({hover: "hover", keys: "keys", tap: "tap"})

/** What happens to a list of routes, which `listEmphasisStep` answers. */
export const ListEvent = Object.freeze({
  close: "close",
  entryEnter: "entryEnter",
  entryLeave: "entryLeave",
  holdExpire: "holdExpire",
  open: "open"
})

/** The state of a list that is not shown: it names no route and emphasizes none. */
export const LIST_EMPHASIS_CLOSED = Object.freeze({listed: Object.freeze([]), emphasized: Object.freeze([])})

/**
 * The emphasized routes of an emphasis event's `detail`: an array of route
 * identifiers, empty for none.
 */
export function emphasizedRoutesOf(detail) {
  const {routeIds} = detail
  assertCondition(Array.isArray(routeIds), `emphasized routes are an array, got: ${routeIds}`)

  for (const routeId of routeIds) {
    assertCondition(typeof routeId === "string", `an emphasized route is a string, got: ${routeId}`)
    assertCondition(routeId !== "", "an emphasized route is not empty")
  }

  return routeIds
}

/**
 * The state of a list after `event`: `listed` is the routes it names,
 * `emphasized` the routes drawn emphasized. Opening emphasizes every listed
 * route, an entry the pointer or focus is on narrows it to that route,
 * leaving the entry returns to every listed route, and closing, or a hold
 * that expires, empties both.
 */
export function listEmphasisStep({state, event}) {
  switch (event.kind) {
    case ListEvent.open:
      return {listed: event.routeIds, emphasized: event.routeIds}
    case ListEvent.entryEnter:
      return {listed: state.listed, emphasized: [event.routeId]}
    case ListEvent.entryLeave:
      return {listed: state.listed, emphasized: state.listed}
    case ListEvent.close:
    case ListEvent.holdExpire:
      return LIST_EMPHASIS_CLOSED
    default:
      return unreachable(event.kind, "an unknown list event")
  }
}

/**
 * The claims on the emphasis after `owner` claims `routeIds`, the latest
 * claim last: an owner holds at most one claim, and an empty `routeIds`
 * withdraws it, so one source closing leaves the claim of another intact.
 */
export function claimEmphasis({claims, owner, routeIds}) {
  const others = claims.filter((claim) => claim.owner !== owner)

  if (routeIds.length === 0) {
    return others
  }

  return [...others, {owner, routeIds}]
}

/** The routes the latest claim emphasizes, an empty array with no claim. */
export function emphasizedBy(claims) {
  if (claims.length === 0) {
    return []
  }

  return claims[claims.length - 1].routeIds
}

/**
 * The share of its opacity a marker of `routeId` is drawn at while
 * `emphasizedRouteIds` are emphasized: whole for an emphasized route's
 * marker and with no route emphasized, `VEHICLE_DIM_FACTOR` for any other.
 */
export function markerAlpha({emphasizedRouteIds, routeId}) {
  if (emphasizedRouteIds.length === 0) {
    return FULL_ALPHA
  }

  if (emphasizedRouteIds.includes(routeId)) {
    return FULL_ALPHA
  }

  return VEHICLE_DIM_FACTOR
}

/**
 * The expression that is true for a feature whose `routeId` is one of
 * `routeIds`; a feature with no route is false.
 */
export function routeIn(routeIds) {
  return ["in", ["to-string", ["get", "routeId"]], ["literal", routeIds]]
}

/**
 * The paint value of a marker layer's opacity: `opacity`, a number or an
 * expression, as it is with no route emphasized, and otherwise an
 * expression that keeps it for the emphasized routes' markers and multiplies
 * it by `VEHICLE_DIM_FACTOR` for every other marker's.
 */
export function dimmedOpacity({emphasizedRouteIds, opacity}) {
  if (emphasizedRouteIds.length === 0) {
    return opacity
  }

  return ["case", routeIn(emphasizedRouteIds), opacity, ["*", opacity, VEHICLE_DIM_FACTOR]]
}
