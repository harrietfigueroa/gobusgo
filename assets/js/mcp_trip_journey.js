// The journey the rider chose, as the trip planner app hands it to the model:
// a versioned object of the service date, the two ends, and the legs with
// their stops, routes, and times, and the short message that follows it. The
// schema is the one a native app implements, so it holds names and times, the
// things a model says to a rider, and nothing the router keeps for itself.
// Everything here is pure.
//
// Version 1 of the object:
//
//   schema        "gobusgo.journey"
//   version       1
//   serviceDate   the service date of the snapshot the journey is routed in
//   timeZone      the IANA zone the rider's clock reads in
//   from, to      the names of the two ends, as the rider saw them
//   departsAt     the instant the journey leaves, an ISO 8601 UTC time
//   arrivesAt     the instant it arrives
//   changes       the rides after the first
//   legs          in the order taken, each of one kind:
//     ride        route {id, name}, from {id, name}, to {id, name} stops, departsAt, arrivesAt
//     walk        minutes, from and to places, a stop as {id, name} or a place as {name}
//
// A change to a field's meaning, or a field removed, is a new version; a
// field added keeps the version.
//
// The journeys the app finds itself are offered as a second object, version
// 1 of "gobusgo.journeys", with no choice behind it:
//
//   schema        "gobusgo.journeys"
//   version       1
//   timeZone      the IANA zone the rider's clock reads in
//   from, to      the names of the two ends
//   plannedAt     the instant the plan was made, an ISO 8601 UTC time
//   journeys      at most JOURNEYS_OFFERED_MAX, in the order given, each with the
//                 serviceDate, departsAt, arrivesAt, changes, and legs of the
//                 object above

import {assertCondition, unreachable} from "./assert.js"
import {LEG_KIND_TO_POINT} from "./point_journeys.js"
import {LegKind} from "./routing_engine.js"
import {journeyLeaveS, routeChip, stopName, walkMinutes} from "./trip_plan.js"

/** The name that tells the object from any other the model holds. */
export const JOURNEY_SCHEMA_NAME = "gobusgo.journey"

/** The version of the object this module writes. */
export const JOURNEY_SCHEMA_VERSION = 1

/** The name that tells the offered journeys from the journey the rider chose. */
export const JOURNEYS_SCHEMA_NAME = "gobusgo.journeys"

/** The version of the offered journeys this module writes. */
export const JOURNEYS_SCHEMA_VERSION = 1

/** The most journeys the offered object holds. */
export const JOURNEYS_OFFERED_MAX = 3

/** The most legs a journey holds; the router's rounds bound it far below this. */
export const JOURNEY_LEG_COUNT_MAX = 32

/** The kinds of a leg of the object. */
export const ContextLegKind = Object.freeze({ride: "ride", walk: "walk"})

/** The kinds of a check of the object. */
export const ProblemKind = Object.freeze({valid: "valid", invalid: "invalid"})

const SECOND_MS = 1000

function instantOf({serviceDayStartsMs, serviceDate, seconds}) {
  const startMs = serviceDayStartsMs[serviceDate]
  assertCondition(Number.isInteger(startMs), "journey context: no start for the service date " + serviceDate)
  return new Date(startMs + seconds * SECOND_MS).toISOString()
}

function stopPlace({names, stopId}) {
  return {id: stopId, name: stopName({names, stopId})}
}

function walkLeg({leg, from, to}) {
  return {kind: ContextLegKind.walk, minutes: walkMinutes(leg.durationS), from, to}
}

function contextLeg({leg, journey, names, fromName, instants}) {
  switch (leg.kind) {
    case LegKind.ride:
      return {
        kind: ContextLegKind.ride,
        route: {id: leg.routeId, name: routeChip({names, routeId: leg.routeId}).name},
        from: stopPlace({names, stopId: leg.fromStopId}),
        to: stopPlace({names, stopId: leg.toStopId}),
        departsAt: instants(leg.departureS),
        arrivesAt: instants(leg.arrivalS),
      }
    case LegKind.walk:
      return walkLeg({leg, from: stopPlace({names, stopId: leg.fromStopId}), to: stopPlace({names, stopId: leg.toStopId})})
    case LegKind.walkFromPosition:
      return walkLeg({leg, from: {name: fromName}, to: stopPlace({names, stopId: leg.toStopId})})
    case LEG_KIND_TO_POINT:
      return walkLeg({leg, from: stopPlace({names, stopId: leg.fromStopId}), to: {name: journey.destination.name}})
    default:
      return unreachable(leg.kind, "journey context: a leg of unknown kind")
  }
}

// The fields of `journey` the two objects share: its service date, instants,
// changes, and legs.
function journeyFields({journey, names, serviceDayStartsMs, from}) {
  assertCondition(journey.legs.length > 0, "journey context: a journey has no leg")
  assertCondition(journey.legs.length <= JOURNEY_LEG_COUNT_MAX, "journey context: a journey has more legs than " + JOURNEY_LEG_COUNT_MAX)
  const {serviceDate} = journey

  function instants(seconds) {
    return instantOf({serviceDayStartsMs, serviceDate, seconds})
  }

  const legs = []

  for (const leg of journey.legs) {
    legs.push(contextLeg({leg, journey, names, fromName: from, instants}))
  }

  return {
    serviceDate,
    departsAt: instants(journeyLeaveS(journey)),
    arrivesAt: instants(journey.arrivalS),
    changes: journey.changes,
    legs,
  }
}

/**
 * The object of `journey`, one of a found answer's journeys: `names` is the
 * page's `{stops, routes}`, `serviceDayStartsMs` the start of each service
 * date's day, `timeZone` the rider's, and `from` and `to` the names of the
 * two ends. The journey's own times are seconds from its service date's
 * start, written here as instants.
 */
export function journeyContext({journey, names, serviceDayStartsMs, timeZone, from, to}) {
  const fields = journeyFields({journey, names, serviceDayStartsMs, from})

  const context = {
    schema: JOURNEY_SCHEMA_NAME,
    version: JOURNEY_SCHEMA_VERSION,
    timeZone,
    from,
    to,
    ...fields,
  }

  const problem = journeyProblem(context)
  assertCondition(problem.kind === ProblemKind.valid, "journey context: the object is invalid at " + problem.path)
  return context
}

/**
 * The offered object of `journeys`, a found answer's journeys in the order
 * the cards show them, of which the first JOURNEYS_OFFERED_MAX are written;
 * `plannedAtMs` is the instant of the plan, and the other arguments are
 * those of `journeyContext`.
 */
export function journeysContext({journeys, names, serviceDayStartsMs, timeZone, from, to, plannedAtMs}) {
  assertCondition(journeys.length > 0, "journeys context: no journey is offered")
  const kept = journeys.slice(0, JOURNEYS_OFFERED_MAX)
  const written = []

  for (const journey of kept) {
    written.push(journeyFields({journey, names, serviceDayStartsMs, from}))
  }

  const context = {
    schema: JOURNEYS_SCHEMA_NAME,
    version: JOURNEYS_SCHEMA_VERSION,
    timeZone,
    from,
    to,
    plannedAt: new Date(plannedAtMs).toISOString(),
    journeys: written,
  }

  const problem = journeysProblem(context)
  assertCondition(problem.kind === ProblemKind.valid, "journeys context: the object is invalid at " + problem.path)
  return context
}

/** The sentence that follows the object, from `row`, a row of `journeyRows`, and the names of the two ends. */
export function chosenMessage({row, from, to}) {
  return `I chose the journey from ${from} to ${to}: ${row.timesText}, ${row.changesText}.`
}

const VALID = Object.freeze({kind: ProblemKind.valid})

function isText(value) {
  return typeof value === "string" && value !== ""
}

function isRecord(value) {
  return typeof value === "object" && value !== null
}

function isInstant(value) {
  if (!isText(value)) {
    return false
  }

  const isParsed = Number.isFinite(Date.parse(value))
  return isParsed && value.endsWith("Z")
}

function isCount(value) {
  return Number.isInteger(value) && value >= 0
}

function invalid(path) {
  return {kind: ProblemKind.invalid, path}
}

// The first of `checks`, each `{path, isValid}`, that fails, or valid.
function firstFailure(checks) {
  for (const check of checks) {
    if (!check.isValid) {
      return invalid(check.path)
    }
  }

  return VALID
}

function placeProblem({place, path, isStop}) {
  if (!isRecord(place)) {
    return invalid(path)
  }

  const isStopComplete = !isStop || isText(place.id)
  return firstFailure([{path: path + ".name", isValid: isText(place.name)}, {path: path + ".id", isValid: isStopComplete}])
}

function rideProblem({leg, path}) {
  if (!isRecord(leg.route)) {
    return invalid(path + ".route")
  }

  const routeFailure = firstFailure([{path: path + ".route.id", isValid: isText(leg.route.id)}, {path: path + ".route.name", isValid: isText(leg.route.name)}])

  if (routeFailure.kind === ProblemKind.invalid) {
    return routeFailure
  }

  const fromFailure = placeProblem({place: leg.from, path: path + ".from", isStop: true})

  if (fromFailure.kind === ProblemKind.invalid) {
    return fromFailure
  }

  const toFailure = placeProblem({place: leg.to, path: path + ".to", isStop: true})

  if (toFailure.kind === ProblemKind.invalid) {
    return toFailure
  }

  return firstFailure([{path: path + ".departsAt", isValid: isInstant(leg.departsAt)}, {path: path + ".arrivesAt", isValid: isInstant(leg.arrivesAt)}])
}

function walkProblem({leg, path}) {
  const minutesFailure = firstFailure([{path: path + ".minutes", isValid: isCount(leg.minutes)}])

  if (minutesFailure.kind === ProblemKind.invalid) {
    return minutesFailure
  }

  const fromFailure = placeProblem({place: leg.from, path: path + ".from", isStop: false})

  if (fromFailure.kind === ProblemKind.invalid) {
    return fromFailure
  }

  return placeProblem({place: leg.to, path: path + ".to", isStop: false})
}

function legProblem({leg, path}) {
  if (!isRecord(leg)) {
    return invalid(path)
  }

  switch (leg.kind) {
    case ContextLegKind.ride:
      return rideProblem({leg, path})
    case ContextLegKind.walk:
      return walkProblem({leg, path})
    default:
      return invalid(path + ".kind")
  }
}

/**
 * Whether `value` is an object of version 1: a ProblemKind member, valid, or
 * invalid with the `path` of the first field that is not what the version
 * says. Fields it does not name are left alone, so a later field added to
 * the version passes.
 */
export function journeyProblem(value) {
  if (!isRecord(value)) {
    return invalid("root")
  }

  const isLegList = Array.isArray(value.legs)
  const headFailure = firstFailure([
    {path: "schema", isValid: value.schema === JOURNEY_SCHEMA_NAME},
    {path: "version", isValid: value.version === JOURNEY_SCHEMA_VERSION},
    {path: "serviceDate", isValid: isText(value.serviceDate)},
    {path: "timeZone", isValid: isText(value.timeZone)},
    {path: "from", isValid: isText(value.from)},
    {path: "to", isValid: isText(value.to)},
    {path: "departsAt", isValid: isInstant(value.departsAt)},
    {path: "arrivesAt", isValid: isInstant(value.arrivesAt)},
    {path: "changes", isValid: isCount(value.changes)},
    {path: "legs", isValid: isLegList},
  ])

  if (headFailure.kind === ProblemKind.invalid) {
    return headFailure
  }

  return legListProblem({legs: value.legs, path: "legs"})
}

// The checks of a list of legs: its length, then each leg, at `path`.
function legListProblem({legs, path}) {
  const legCountFailure = firstFailure([{path, isValid: legs.length > 0}, {path, isValid: legs.length <= JOURNEY_LEG_COUNT_MAX}])

  if (legCountFailure.kind === ProblemKind.invalid) {
    return legCountFailure
  }

  for (const [index, leg] of legs.entries()) {
    const legFailure = legProblem({leg, path: `${path}.${index}`})

    if (legFailure.kind === ProblemKind.invalid) {
      return legFailure
    }
  }

  return VALID
}

// The checks of one journey of the offered object, at `path`.
function offeredJourneyProblem({value, path}) {
  if (!isRecord(value)) {
    return invalid(path)
  }

  const isLegList = Array.isArray(value.legs)
  const headFailure = firstFailure([
    {path: path + ".serviceDate", isValid: isText(value.serviceDate)},
    {path: path + ".departsAt", isValid: isInstant(value.departsAt)},
    {path: path + ".arrivesAt", isValid: isInstant(value.arrivesAt)},
    {path: path + ".changes", isValid: isCount(value.changes)},
    {path: path + ".legs", isValid: isLegList},
  ])

  if (headFailure.kind === ProblemKind.invalid) {
    return headFailure
  }

  return legListProblem({legs: value.legs, path: path + ".legs"})
}

/**
 * Whether `value` is an offered object of version 1: a ProblemKind member,
 * valid, or invalid with the `path` of the first field that is not what the
 * version says. Fields it does not name are left alone.
 */
export function journeysProblem(value) {
  if (!isRecord(value)) {
    return invalid("root")
  }

  const isJourneyList = Array.isArray(value.journeys)
  const headFailure = firstFailure([
    {path: "schema", isValid: value.schema === JOURNEYS_SCHEMA_NAME},
    {path: "version", isValid: value.version === JOURNEYS_SCHEMA_VERSION},
    {path: "timeZone", isValid: isText(value.timeZone)},
    {path: "from", isValid: isText(value.from)},
    {path: "to", isValid: isText(value.to)},
    {path: "plannedAt", isValid: isInstant(value.plannedAt)},
    {path: "journeys", isValid: isJourneyList},
  ])

  if (headFailure.kind === ProblemKind.invalid) {
    return headFailure
  }

  const countFailure = firstFailure([{path: "journeys", isValid: value.journeys.length > 0}, {path: "journeys", isValid: value.journeys.length <= JOURNEYS_OFFERED_MAX}])

  if (countFailure.kind === ProblemKind.invalid) {
    return countFailure
  }

  for (const [index, journey] of value.journeys.entries()) {
    const journeyFailure = offeredJourneyProblem({value: journey, path: `journeys.${index}`})

    if (journeyFailure.kind === ProblemKind.invalid) {
      return journeyFailure
    }
  }

  return VALID
}
