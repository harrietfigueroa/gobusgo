// The scheduled departures at a stop, as the arrivals board hands them to the
// model: a versioned object of the stop, the time the list starts at, the
// routes asked for, and the departures with their routes, headsigns, and
// times, the things a model says to a rider. Everything here is pure.
//
// Version 1 of the object:
//
//   schema        "gobusgo.departures"
//   version       1
//   status        "listed" for a date the schedules hold, or "noSchedule" for
//                 a time no date of the schedules holds, with no departure
//   timeZone      the IANA zone the rider's clock reads in
//   stop          {id, name}, the name null where the schedules give none
//   from          the instant the list starts at, an ISO 8601 UTC time
//   listedAt      the instant the list was read, an ISO 8601 UTC time
//   routeIds      the routes asked for, none meaning every route
//   isBounded     whether the list stops at the bound, so a later time lists more
//   departures    at most DEPARTURE_COUNT_MAX, the soonest first, each with
//                 departsAt, an ISO 8601 UTC time, route {id, name},
//                 headsign, a text or null, and, only for a departure
//                 within the live window of the arrivals tool, a `note`
//                 that the live answer comes from it
//
// A change to a field's meaning, or a field removed, is a new version; a
// field added keeps the version.

import {assertCondition} from "./assert.js"
import {DepartureLoadKind} from "./departure_files.js"
import {LIVE_NOTE, isInLiveWindow} from "./mcp_board_departures.js"
import {ProblemKind, VALID, firstFailure, invalid, isInstant, isRecord, isText} from "./mcp_trip_journey.js"
import {DEPARTURE_COUNT_MAX} from "./scheduled_service.js"

/** The name that tells the object from any other the model holds. */
export const DEPARTURES_SCHEMA_NAME = "gobusgo.departures"

/** The version of the object this module writes. */
export const DEPARTURES_SCHEMA_VERSION = 1

/** The kinds of what the object says: a list, or a time the schedules do not hold. */
export const DeparturesStatus = Object.freeze({listed: "listed", noSchedule: "noSchedule"})

/** Whether `loaded`, what a read of the departures ended in, is something the model is told. */
export function isOffered(loaded) {
  const isListed = loaded.kind === DepartureLoadKind.listed
  return isListed || loaded.kind === DepartureLoadKind.noSchedule
}

function departureOf({departure, nowMs}) {
  const written = {departsAt: new Date(departure.timeMs).toISOString(), route: {id: departure.routeId, name: departure.route}, headsign: departure.headsign}

  if (isInLiveWindow({timeMs: departure.timeMs, nowMs})) {
    written.note = LIVE_NOTE
  }

  return written
}

/**
 * The object of `loaded`, a read of the departures at the stop `stopId`
 * that `isOffered` holds: `fromMs` is the instant the list starts at,
 * `routeIds` the routes asked for, `nowMs` the instant it was read, and
 * `timeZone` the rider's.
 */
export function departuresContext({loaded, stopId, fromMs, routeIds, nowMs, timeZone}) {
  assertCondition(isOffered(loaded), "departures context: a read that ended in " + loaded.kind + " is not offered")
  const fields = {status: DeparturesStatus.noSchedule, name: null, isBounded: false, departures: []}

  if (loaded.kind === DepartureLoadKind.listed) {
    fields.status = DeparturesStatus.listed
    fields.name = loaded.stopName
    fields.isBounded = loaded.isBounded
    assertCondition(loaded.departures.length <= DEPARTURE_COUNT_MAX, "departures context: the list is longer than " + DEPARTURE_COUNT_MAX)

    for (const departure of loaded.departures) {
      fields.departures.push(departureOf({departure, nowMs}))
    }
  }

  const context = {
    schema: DEPARTURES_SCHEMA_NAME,
    version: DEPARTURES_SCHEMA_VERSION,
    status: fields.status,
    timeZone,
    stop: {id: stopId, name: fields.name},
    from: new Date(fromMs).toISOString(),
    listedAt: new Date(nowMs).toISOString(),
    routeIds,
    isBounded: fields.isBounded,
    departures: fields.departures,
  }

  const problem = departuresProblem(context)
  assertCondition(problem.kind === ProblemKind.valid, "departures context: the object is invalid at " + problem.path)
  return context
}

function isTextOrNull(value) {
  const isNull = value === null
  return isNull || isText(value)
}

function isStatus(value) {
  return Object.values(DeparturesStatus).includes(value)
}

function stopProblem(stop) {
  if (!isRecord(stop)) {
    return invalid("stop")
  }

  return firstFailure([{path: "stop.id", isValid: isText(stop.id)}, {path: "stop.name", isValid: isTextOrNull(stop.name)}])
}

function routeIdsProblem(routeIds) {
  if (!Array.isArray(routeIds)) {
    return invalid("routeIds")
  }

  for (const [index, routeId] of routeIds.entries()) {
    if (!isText(routeId)) {
      return invalid(`routeIds.${index}`)
    }
  }

  return VALID
}

function departureProblem({departure, path}) {
  if (!isRecord(departure)) {
    return invalid(path)
  }

  if (!isRecord(departure.route)) {
    return invalid(path + ".route")
  }

  const isNoteValid = departure.note === undefined || isText(departure.note)

  return firstFailure([
    {path: path + ".departsAt", isValid: isInstant(departure.departsAt)},
    {path: path + ".route.id", isValid: isText(departure.route.id)},
    {path: path + ".route.name", isValid: isText(departure.route.name)},
    {path: path + ".headsign", isValid: isTextOrNull(departure.headsign)},
    {path: path + ".note", isValid: isNoteValid},
  ])
}

/**
 * Whether `value` is an object of version 1: a ProblemKind member, valid, or
 * invalid with the `path` of the first field that is not what the version
 * says. Fields it does not name are left alone, so a later field added to
 * the version passes.
 */
export function departuresProblem(value) {
  if (!isRecord(value)) {
    return invalid("root")
  }

  const headFailure = firstFailure([
    {path: "schema", isValid: value.schema === DEPARTURES_SCHEMA_NAME},
    {path: "version", isValid: value.version === DEPARTURES_SCHEMA_VERSION},
    {path: "status", isValid: isStatus(value.status)},
    {path: "timeZone", isValid: isText(value.timeZone)},
  ])

  if (headFailure.kind === ProblemKind.invalid) {
    return headFailure
  }

  const stopFailure = stopProblem(value.stop)

  if (stopFailure.kind === ProblemKind.invalid) {
    return stopFailure
  }

  const instantFailure = firstFailure([{path: "from", isValid: isInstant(value.from)}, {path: "listedAt", isValid: isInstant(value.listedAt)}])

  if (instantFailure.kind === ProblemKind.invalid) {
    return instantFailure
  }

  const routeIdsFailure = routeIdsProblem(value.routeIds)

  if (routeIdsFailure.kind === ProblemKind.invalid) {
    return routeIdsFailure
  }

  const isDepartureList = Array.isArray(value.departures)
  const listFailure = firstFailure([{path: "isBounded", isValid: typeof value.isBounded === "boolean"}, {path: "departures", isValid: isDepartureList}])

  if (listFailure.kind === ProblemKind.invalid) {
    return listFailure
  }

  const countFailure = firstFailure([{path: "departures", isValid: value.departures.length <= DEPARTURE_COUNT_MAX}])

  if (countFailure.kind === ProblemKind.invalid) {
    return countFailure
  }

  for (const [index, departure] of value.departures.entries()) {
    const departureFailure = departureProblem({departure, path: `departures.${index}`})

    if (departureFailure.kind === ProblemKind.invalid) {
      return departureFailure
    }
  }

  return VALID
}
