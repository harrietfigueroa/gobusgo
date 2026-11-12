// What the arrivals board reads of the arguments of an `arrivals_board`
// call, as pure functions of the params of the host's `tool-input`
// notification: the stop, a time that turns the board into a list of
// scheduled departures, and the routes that list keeps. The time is read as
// the trip planner app reads the `when` of `plan_trip`, through the same
// `whenOf`. Nothing here reads the document, the network, or a clock.
//
// The arguments come from a model, so each field is checked, and a refusal
// is a value that names the field, never a throw.

import {InputKind, whenOf} from "./mcp_trip_input.js"

/** The most routes a list of departures keeps; the tool's schema bounds it the same. */
export const ROUTE_COUNT_MAX = 10

/** The most characters a route identifier holds; the tool's schema bounds it the same. */
export const ROUTE_ID_LENGTH_MAX = 100

/** The kinds of a read of the arguments. */
export const BoardInputKind = Object.freeze({live: "live", scheduled: "scheduled", missing: "missing", refused: "refused"})

const NO_ARGUMENTS = Object.freeze({})
const NO_ROUTE_IDS = Object.freeze([])

function isRecord(value) {
  const isObject = typeof value === "object" && value !== null
  return isObject && !Array.isArray(value)
}

function isRouteId(value) {
  const isText = typeof value === "string"
  const isLongEnough = isText && value.length >= 1
  return isLongEnough && value.length <= ROUTE_ID_LENGTH_MAX
}

// The routes the list keeps, none meaning every route, or refused.
function routeIdsOf(value) {
  if (value === undefined) {
    return {kind: InputKind.found, routeIds: NO_ROUTE_IDS}
  }

  const isBoundedList = Array.isArray(value) && value.length <= ROUTE_COUNT_MAX

  if (isBoundedList === false) {
    return {kind: InputKind.refused}
  }

  for (const routeId of value) {
    if (isRouteId(routeId) === false) {
      return {kind: InputKind.refused}
    }
  }

  return {kind: InputKind.found, routeIds: value}
}

function stopIdOf(toolArguments) {
  const isText = typeof toolArguments.stopId === "string"

  const isNonEmpty = isText && toolArguments.stopId !== ""

  if (isNonEmpty) {
    return {kind: InputKind.found, stopId: toolArguments.stopId}
  }

  return {kind: InputKind.refused}
}

/**
 * What `params`, the params of the host's `tool-input` notification, ask of
 * the board: a BoardInputKind member. `missing` is a call that names no
 * stop. `live` is the stop alone, or the stop with routes and no time, which
 * leave the board as it is. `scheduled` is the stop with a `when`, the page's
 * `{mode, day, clockText}`, and `routeIds`, the routes asked for, none
 * meaning every route. `refused` names the `field`, `when` or `route`, that
 * is not what the tool's schema says.
 */
export function boardInput(params) {
  let toolArguments = NO_ARGUMENTS

  const hasArguments = isRecord(params) && isRecord(params.arguments)

  if (hasArguments) {
    toolArguments = params.arguments
  }

  const stop = stopIdOf(toolArguments)

  if (stop.kind === InputKind.refused) {
    return {kind: BoardInputKind.missing}
  }

  if (toolArguments.when === undefined) {
    return {kind: BoardInputKind.live, stopId: stop.stopId}
  }

  const timed = whenOf(toolArguments.when)

  if (timed.kind === InputKind.refused) {
    return {kind: BoardInputKind.refused, field: timed.field}
  }

  const routes = routeIdsOf(toolArguments.route)

  if (routes.kind === InputKind.refused) {
    return {kind: BoardInputKind.refused, field: "route"}
  }

  return {kind: BoardInputKind.scheduled, stopId: stop.stopId, when: timed.when, routeIds: routes.routeIds}
}
