// What the vehicle page answers for itself while it is offline, in place of
// the server. Everything here is pure: the saved snapshot tables, the
// manifest, and the time are given as values, and each answer is a function
// of them alone.
//
// A saved snapshot, as the page reads it from the offline bundle, holds at
// least `{serviceDate, stopIndexes, positions, names}`, the fields read
// here: `stopIndexes` maps each stop identifier of its
// stops file to the stop's index, and `positions` and `names` are each a
// table keyed by `kind`, found with the decoded positions file or names
// file, or missing where the bundle holds none.

import {assertCondition, unreachable} from "./assert.js"
import {ServiceDateKind, serviceDateAt} from "./routing_journeys.js"
import {ROUTE_COLOR_DEFAULT} from "./trip_plan.js"
import {POSITION_UNKNOWN_MICRODEGREES} from "./routing_snapshot.js"

/** The events the vehicle page's hooks push to the server. */
export const PageEventName = Object.freeze({
  stopPosition: "stop:position",
  tripNames: "trip:names",
  tripFilter: "trip:filter",
  tripClear: "trip:clear",
  filterRestore: "vehicle-filter:restore",
  arrivalsOpen: "stop-arrivals:open",
  arrivalsClose: "stop-arrivals:close",
  markersReady: "vehicle-markers:ready",
  sharedVehiclesShow: "shared-vehicles:show",
  sharedVehiclesHide: "shared-vehicles:hide"
})

/** What the page does for itself with an event while it is offline. */
export const LocalAnswerKind = Object.freeze({
  position: "position",
  names: "names",
  tripFilter: "tripFilter",
  tripClear: "tripClear",
  filterRestore: "filterRestore",
  deferClose: "deferClose",
  cancelClose: "cancelClose",
  scheduledMarkers: "scheduledMarkers",
  unanswered: "unanswered"
})

/** Whether a saved table is in the bundle. */
export const TableKind = Object.freeze({found: "found", missing: "missing"})

/** Whether a trip's filter is one the page shows. */
export const TripFilterKind = Object.freeze({accepted: "accepted", refused: "refused"})

/** The reply the server gives a request it refuses. */
export const REFUSED_REPLY = Object.freeze({refused: true})

/** The reply to the stored filter's restore: accepted, so the browser keeps the filter it stored. */
export const FILTER_RESTORE_REPLY = Object.freeze({accepted: true})

/** The most stops kept to close for the server once the page is live. */
export const DEFERRED_CLOSE_COUNT_MAX = 64

const MICRODEGREES_PER_DEGREE = 1000000
const TRIP_SUMMARY_PREFIX = "Showing the trip's routes: "
const ROUTE_NAME_SEPARATOR = ", "

/** What the page does for itself with the event `name` while offline. */
export function localAnswerOf(name) {
  switch (name) {
    case PageEventName.stopPosition:
      return LocalAnswerKind.position
    case PageEventName.tripNames:
      return LocalAnswerKind.names
    case PageEventName.tripFilter:
      return LocalAnswerKind.tripFilter
    case PageEventName.tripClear:
      return LocalAnswerKind.tripClear
    case PageEventName.filterRestore:
      return LocalAnswerKind.filterRestore
    case PageEventName.arrivalsOpen:
      return LocalAnswerKind.cancelClose
    case PageEventName.arrivalsClose:
      return LocalAnswerKind.deferClose
    case PageEventName.markersReady:
      return LocalAnswerKind.scheduledMarkers
    case PageEventName.sharedVehiclesShow:
    case PageEventName.sharedVehiclesHide:
      return LocalAnswerKind.unanswered
    default:
      return unreachable(name, "an event no hook of the page pushes")
  }
}

function isText(value) {
  return typeof value === "string"
}

// The identifiers of `values`, once each, or none for a value that is not a
// list of texts within `countMax`.
function identifiersOf({values, countMax}) {
  const isList = Array.isArray(values)

  if (!isList) {
    return {kind: TripFilterKind.refused}
  }

  const isWithinBound = values.length <= countMax

  if (!isWithinBound) {
    return {kind: TripFilterKind.refused}
  }

  for (const value of values) {
    if (!isText(value)) {
      return {kind: TripFilterKind.refused}
    }
  }

  return {kind: TripFilterKind.accepted, identifiers: Array.from(new Set(values))}
}

function degreesOf(microdegrees) {
  return microdegrees / MICRODEGREES_PER_DEGREE
}

// The position of the stop `stopId` in `snapshot`, or none.
function positionIn({snapshot, stopId}) {
  const index = snapshot.stopIndexes.get(stopId)
  const isHeld = index !== undefined
  const hasPositions = snapshot.positions.kind === TableKind.found
  const isPositionable = isHeld && hasPositions

  if (!isPositionable) {
    return REFUSED_REPLY
  }

  const latMicrodegrees = snapshot.positions.table.latMicrodegrees[index]
  const lonMicrodegrees = snapshot.positions.table.lonMicrodegrees[index]

  if (latMicrodegrees === POSITION_UNKNOWN_MICRODEGREES) {
    return REFUSED_REPLY
  }

  return {lat: degreesOf(latMicrodegrees), lon: degreesOf(lonMicrodegrees)}
}

/**
 * The reply to a `stop:position` request `payload`, as the server gives it:
 * the stop's latitude and longitude from the first of `snapshots` that
 * knows it, or refused.
 */
export function positionReply({snapshots, payload}) {
  const stopId = payload.stop_id

  if (!isText(stopId)) {
    return REFUSED_REPLY
  }

  for (const snapshot of snapshots) {
    const position = positionIn({snapshot, stopId})

    if (position !== REFUSED_REPLY) {
      return position
    }
  }

  return REFUSED_REPLY
}

/**
 * The name the saved route `route` of `routeId` is shown under, as the
 * server names it: its short name, its long name, or its identifier.
 */
export function savedRouteName({route, routeId}) {
  if (isText(route.shortName)) {
    return route.shortName
  } else if (isText(route.longName)) {
    return route.longName
  } else {
    return routeId
  }
}

function routeColorOf(route) {
  if (isText(route.color)) {
    return `#${route.color}`
  } else {
    return ROUTE_COLOR_DEFAULT
  }
}

// The route `routeId` of the first names file of `snapshots` that holds
// it, or none.
function savedRoute({snapshots, routeId}) {
  for (const snapshot of snapshots) {
    const hasNames = snapshot.names.kind === TableKind.found
    const isNamed = hasNames && Object.hasOwn(snapshot.names.table.routes, routeId)

    if (isNamed) {
      return {kind: TableKind.found, route: snapshot.names.table.routes[routeId]}
    }
  }

  return {kind: TableKind.missing}
}

// The name and code of the stop `stopId` from the first names file of
// `snapshots` whose stops hold it, or none.
function savedStop({snapshots, stopId}) {
  for (const snapshot of snapshots) {
    const index = snapshot.stopIndexes.get(stopId)
    const isHeld = index !== undefined
    const isNamed = isHeld && snapshot.names.kind === TableKind.found

    if (isNamed) {
      const {stopNames, stopCodes} = snapshot.names.table
      return {kind: TableKind.found, stop: {name: stopNames[index], code: stopCodes[index]}}
    }
  }

  return {kind: TableKind.missing}
}

/**
 * The reply to a `trip:names` request `payload`, in the server's shape:
 * each named stop's name and code and each named route's name and CSS
 * color, from the saved names files of `snapshots`. A stop or route no
 * names file holds is left out, so the page shows its identifier; a
 * request of more than `countMax` stops or routes is refused.
 */
export function namesReply({snapshots, payload, countMax}) {
  const stopIds = identifiersOf({values: payload.stop_ids, countMax})
  const routeIds = identifiersOf({values: payload.route_ids, countMax})
  const isStopsAccepted = stopIds.kind === TripFilterKind.accepted
  const isAccepted = isStopsAccepted && routeIds.kind === TripFilterKind.accepted

  if (!isAccepted) {
    return REFUSED_REPLY
  }

  const stops = {}
  const routes = {}

  for (const stopId of stopIds.identifiers) {
    const saved = savedStop({snapshots, stopId})

    if (saved.kind === TableKind.found) {
      stops[stopId] = saved.stop
    }
  }

  for (const routeId of routeIds.identifiers) {
    const saved = savedRoute({snapshots, routeId})

    if (saved.kind === TableKind.found) {
      routes[routeId] = {name: savedRouteName({route: saved.route, routeId}), color: routeColorOf(saved.route)}
    }
  }

  return {stops, routes}
}

/**
 * The routes of a `trip:filter` request `payload`, once each, as the server
 * judges them: refused for none, more than `countMax`, or a value that is
 * not text.
 */
export function tripFilterOf({payload, countMax}) {
  const accepted = identifiersOf({values: payload.route_ids, countMax})

  if (accepted.kind === TripFilterKind.refused) {
    return accepted
  }

  if (accepted.identifiers.length === 0) {
    return {kind: TripFilterKind.refused}
  }

  return {kind: TripFilterKind.accepted, routeIds: accepted.identifiers}
}

/** The summary line of a trip's filter of `routeIds`, each route by its saved name or its identifier. */
export function tripSummaryText({snapshots, routeIds}) {
  const names = []

  for (const routeId of routeIds) {
    const saved = savedRoute({snapshots, routeId})

    if (saved.kind === TableKind.found) {
      names.push(savedRouteName({route: saved.route, routeId}))
    } else {
      names.push(routeId)
    }
  }

  return TRIP_SUMMARY_PREFIX + names.join(ROUTE_NAME_SEPARATOR)
}

/**
 * The entries of `manifest` in the order the page reads them at `nowMs`:
 * the service date running then first, then the rest in the manifest's
 * order.
 */
export function snapshotOrder({manifest, nowMs}) {
  assertCondition(Number.isFinite(nowMs), `the time is a number: ${nowMs}`)
  const running = serviceDateAt({manifest, departureMs: nowMs})

  if (running.kind === ServiceDateKind.none) {
    return Array.from(manifest.snapshots)
  }

  const first = []
  const rest = []

  for (const entry of manifest.snapshots) {
    if (entry.serviceDate === running.serviceDate) {
      first.push(entry)
    } else {
      rest.push(entry)
    }
  }

  return first.concat(rest)
}

/**
 * `closes`, the stops to close for the server once the page is live, with
 * `stopId` last, at most DEFERRED_CLOSE_COUNT_MAX of them: past the bound
 * the oldest is dropped.
 */
export function withClose({closes, stopId}) {
  const kept = withoutClose({closes, stopId})
  kept.push(stopId)

  if (kept.length > DEFERRED_CLOSE_COUNT_MAX) {
    return kept.slice(kept.length - DEFERRED_CLOSE_COUNT_MAX)
  }

  return kept
}

/** `closes` without `stopId`, a stop opened again. */
export function withoutClose({closes, stopId}) {
  const kept = []

  for (const closed of closes) {
    if (closed !== stopId) {
      kept.push(closed)
    }
  }

  return kept
}
