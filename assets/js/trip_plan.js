// What the Trip tab decides, as pure functions: whether two ends make a
// query, what the journeys of a query read as, which stops and routes the
// page is asked to name, which routes a selected journey's filter names,
// and what the map draws of it. Nothing here reads the document, the
// clock, storage, or the network: the time zone, the names, and the
// positions arrive as arguments.

import {assertCondition, unreachable} from "./assert.js"
import {LegKind} from "./routing_engine.js"
import {FailureReason, JourneysKind, WINDOW_SECONDS} from "./routing_journeys.js"

/** The two ends of a trip. */
export const TripEnd = Object.freeze({from: "from", to: "to"})

/** The kinds of an end: none chosen, the rider's location, or a stop. */
export const EndKind = Object.freeze({none: "none", location: "location", stop: "stop"})

/** The kinds of what two ends make. */
export const QueryKind = Object.freeze({ready: "ready", incomplete: "incomplete", sameStop: "sameStop"})

/** The outcomes the Trip tab states in place of journeys, beside the router's own. */
export const StateKind = Object.freeze({
  loading: "loading",
  noServiceDate: "noServiceDate",
  locationDenied: "locationDenied",
  locationUnavailable: "locationUnavailable",
  sameStop: "sameStop",
  notSaved: "notSaved",
})

/** The kinds of a feature the map draws of a journey. */
export const FeatureKind = Object.freeze({ride: "ride", walk: "walk", origin: "origin", destination: "destination"})

/** The kinds of the bounds of what the map draws: none, or a box. */
export const BoundsKind = Object.freeze({none: "none", bounds: "bounds"})

/** The end that names no place. */
export const NO_END = Object.freeze({kind: EndKind.none})

/** The end of the rider's location, which a From field alone offers. */
export const LOCATION_END = Object.freeze({kind: EndKind.location})

/** The color of a route the page has named no color for. */
export const ROUTE_COLOR_DEFAULT = "#6b7280"

const SECOND_MS = 1000
const MINUTE_S = 60
const ARROW = " → "
const LINE_POINT_COUNT_MIN = 2
const TOMORROW_PREFIX = "Tomorrow "

const stateMessages = Object.freeze({
  [StateKind.loading]: {headline: "Finding journeys…", caption: "Searching today's and tomorrow's schedules."},
  [StateKind.noServiceDate]: {headline: "No schedule for this time yet", caption: "Try again later."},
  [StateKind.locationDenied]: {headline: "Location is off", caption: "Start from a stop instead, or allow location in your browser's settings."},
  [StateKind.locationUnavailable]: {headline: "Can't find your location", caption: "Start from a stop instead, or try again."},
  [StateKind.sameStop]: {headline: "From and To are the same stop", caption: "Choose another stop for one of them."},
  [StateKind.notSaved]: {headline: "Not saved for offline", caption: "Connect to plan this trip."},
  [JourneysKind.none]: {headline: "No journeys found", caption: "Nothing runs between these two today or tomorrow."},
  [JourneysKind.unknownStop]: {headline: "Stop not in the schedules", caption: "Choose another stop nearby."},
  [JourneysKind.noStartStop]: {headline: "No stop within a walk", caption: "Start from a stop instead."},
  [JourneysKind.failed]: {headline: "Journeys didn't load", caption: "Check your connection and try again."},
})

/** The message the Trip tab shows while the rider picks the stop of `fieldLabel` on the map. */
export function pickingMessage(fieldLabel) {
  return {headline: `Pick a stop for ${fieldLabel}`, caption: "Tap a stop on the map. Stops show once the map is zoomed in."}
}

/** The end of the stop `stopId`, named `name` until the page names it. */
export function stopEnd({stopId, name}) {
  assertCondition(typeof stopId === "string", "trip plan: a stop end's identifier is not text: " + stopId)
  assertCondition(stopId !== "", "trip plan: a stop end has an empty identifier")
  return {kind: EndKind.stop, stopId, name}
}

/**
 * The ends with From and To swapped. The rider's location is a From end
 * alone, so a location that would become the To end leaves it empty.
 */
export function swappedEnds({from, to}) {
  if (from.kind === EndKind.location) {
    return {from: to, to: NO_END}
  }

  return {from: to, to: from}
}

/**
 * What the ends `from` and `to` make: a query from the From end to the To
 * end's stop, nothing while an end is missing, or a refusal for one stop
 * at both ends.
 */
export function queryOf({from, to}) {
  const isFromSet = from.kind !== EndKind.none
  const isToStop = to.kind === EndKind.stop
  const isComplete = isFromSet && isToStop

  if (!isComplete) {
    return {kind: QueryKind.incomplete}
  }

  const isFromStop = from.kind === EndKind.stop
  const isSameStop = isFromStop && from.stopId === to.stopId

  if (isSameStop) {
    return {kind: QueryKind.sameStop}
  }

  return {kind: QueryKind.ready, from, toStopId: to.stopId}
}

/** The message the Trip tab shows for `kind`, a state of its own or a router outcome. */
export function stateMessage(kind) {
  const isKnown = Object.hasOwn(stateMessages, kind)
  assertCondition(isKnown, "trip plan: no message for the state " + kind)
  return stateMessages[kind]
}

/** Whether a failure is worth trying again: every failure but a format the page cannot read. */
export function isRetryable(failure) {
  return failure.reason !== FailureReason.unsupportedVersion
}

/** The state the Trip tab shows for a failed query: that its schedules are not saved, or that it failed. */
export function failureState(failure) {
  if (failure.reason === FailureReason.notSaved) {
    return StateKind.notSaved
  }

  return JourneysKind.failed
}

/** `ms`, milliseconds since the Unix epoch, as a clock time in `timeZone`, such as "8:42 am". */
export function clockText({ms, timeZone}) {
  const format = new Intl.DateTimeFormat("en-US", {hour: "numeric", minute: "2-digit", hour12: true, timeZone})
  const parts = format.formatToParts(new Date(ms))
  let text = ""

  // ICU separates the day period with a narrow no-break space, which reads
  // as a plain space and is written as one.
  for (const part of parts) {
    const isSpace = part.type === "literal" && part.value.trim() === ""

    if (part.type === "dayPeriod") {
      text += part.value.toLowerCase()
    } else if (isSpace) {
      text += " "
    } else {
      text += part.value
    }
  }

  return text
}

function byChangesThenArrival(left, right) {
  if (left.journey.changes !== right.journey.changes) {
    return left.journey.changes - right.journey.changes
  }

  return left.arrivalMs - right.arrivalMs
}

// The milliseconds since the Unix epoch of `seconds` from the start of the
// service day `serviceDate`.
function absoluteMs({serviceDayStartsMs, serviceDate, seconds}) {
  const startMs = serviceDayStartsMs[serviceDate]
  assertCondition(Number.isInteger(startMs), "trip plan: no start for the service date " + serviceDate)
  return startMs + seconds * SECOND_MS
}

// The seconds a journey leaves at: its first ride's departure less the
// walks before it, or `departureS` for a journey with no ride.
function leaveS({journey, departureS}) {
  let walkS = 0

  for (const leg of journey.legs) {
    if (leg.kind === LegKind.ride) {
      return leg.departureS - walkS
    }

    walkS += leg.durationS
  }

  return departureS
}

/** Whole minutes of a walk, rounded up, so a short walk reads as one minute. */
export function walkMinutes(durationS) {
  return Math.ceil(durationS / MINUTE_S)
}

function changesText(changes) {
  if (changes === 0) {
    return "No change"
  } else if (changes === 1) {
    return "1 change"
  } else {
    return `${changes} changes`
  }
}

/** The name the page gave the stop `stopId` in `names`, or its identifier. */
export function stopName({names, stopId}) {
  const named = names.stops[stopId]
  const isText = named !== undefined && typeof named.name === "string"
  const isNamed = isText && named.name !== ""

  if (isNamed) {
    return named.name
  } else {
    return stopId
  }
}

/** The chip of the route `routeId`: the name and color the page gave it, or its identifier in gray. */
export function routeChip({names, routeId}) {
  const named = names.routes[routeId]

  if (named === undefined) {
    return {name: routeId, color: ROUTE_COLOR_DEFAULT}
  } else {
    return {name: named.name, color: named.color}
  }
}

// The stop a journey ends at.
function targetStopId(journey) {
  const last = journey.legs[journey.legs.length - 1]
  return last.toStopId
}

// The parts of the line that sums up a journey: a chip per ride and a text
// per walk.
function summaryParts({journey, names}) {
  const parts = []

  for (const leg of journey.legs) {
    switch (leg.kind) {
      case LegKind.ride:
        parts.push({kind: LegKind.ride, chip: routeChip({names, routeId: leg.routeId})})
        break
      case LegKind.walk:
      case LegKind.walkFromPosition:
        parts.push({kind: LegKind.walk, text: `walk ${walkMinutes(leg.durationS)} min`})
        break
      default:
        unreachable(leg.kind, "trip plan: a leg of unknown kind")
    }
  }

  return parts
}

// The steps of a journey, one sentence each, in the order the rider takes
// them. A ride that ends the journey has its stop in the arrival.
function steps({journey, names, clockOf}) {
  const result = []
  const lastIndex = journey.legs.length - 1

  for (const [index, leg] of journey.legs.entries()) {
    switch (leg.kind) {
      case LegKind.ride: {
        const route = routeChip({names, routeId: leg.routeId}).name
        result.push(`${clockOf(leg.departureS)} board ${route} at ${stopName({names, stopId: leg.fromStopId})}`)

        if (index < lastIndex) {
          result.push(`${clockOf(leg.arrivalS)} get off at ${stopName({names, stopId: leg.toStopId})}`)
        }

        break
      }
      case LegKind.walk:
      case LegKind.walkFromPosition:
        result.push(`walk ${walkMinutes(leg.durationS)} min to ${stopName({names, stopId: leg.toStopId})}`)
        break
      default:
        unreachable(leg.kind, "trip plan: a leg of unknown kind")
    }
  }

  result.push(`${clockOf(journey.arrivalS)} arrive at ${stopName({names, stopId: targetStopId(journey)})}`)
  return result
}

/**
 * The rows of the journey list for `journeys`, a found answer's, fewest
 * changes first and the earlier arrival first within that. `departure` is
 * the query's, its `serviceDate` and its `departureS`; a journey of another
 * service date reads "Tomorrow" before its time. `serviceDayStartsMs` holds
 * each service date's start, `names` the page's names of the stops and the
 * routes, and `timeZone` the zone the times read in. Each row keeps its
 * journey.
 */
export function journeyRows({journeys, departure, serviceDayStartsMs, names, timeZone}) {
  const timed = []

  for (const journey of journeys) {
    const arrivalMs = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds: journey.arrivalS})
    timed.push({journey, arrivalMs})
  }

  timed.sort(byChangesThenArrival)
  const rows = []

  for (const {journey, arrivalMs} of timed) {
    const isTomorrow = journey.serviceDate !== departure.serviceDate

    function clockOf(seconds) {
      const ms = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds})
      return clockText({ms, timeZone})
    }

    const startS = leaveS({journey, departureS: departure.departureS})
    let leaveText = clockOf(startS)

    if (isTomorrow) {
      leaveText = TOMORROW_PREFIX + leaveText
    }

    const durationMinutes = Math.round((journey.arrivalS - startS) / MINUTE_S)
    let badgeText = `${durationMinutes} min`

    if (journey.isEarliest) {
      badgeText = `Earliest · ${badgeText}`
    }

    const arrivalText = clockText({ms: arrivalMs, timeZone})

    rows.push({
      journey,
      isEarliest: journey.isEarliest,
      isTomorrow,
      arrivalText,
      timesText: leaveText + ARROW + arrivalText,
      badgeText,
      changesText: changesText(journey.changes),
      summary: summaryParts({journey, names}),
      steps: steps({journey, names, clockOf}),
    })
  }

  return rows
}

function arrivalPhrase(row) {
  if (row.isTomorrow) {
    return `tomorrow at ${row.arrivalText}`
  }

  return `at ${row.arrivalText}`
}

/**
 * The sentence the Trip tab's status line holds once `rows`, the rows of
 * a found answer, are written: how many journeys there are and when the
 * earliest arrives, which a screen reader announces in place of the list
 * a sighted rider sees appear.
 */
export function journeysAnnouncement(rows) {
  assertCondition(rows.length > 0, `trip plan: an announcement needs a journey, got ${rows.length}`)

  if (rows.length === 1) {
    return `1 journey. It arrives ${arrivalPhrase(rows[0])}.`
  }

  const earliest = rows.find(isEarliestRow)
  assertCondition(earliest !== undefined, "trip plan: a found answer marks its earliest journey")
  return `${rows.length} journeys. The earliest arrives ${arrivalPhrase(earliest)}.`
}

function isEarliestRow(row) {
  return row.isEarliest
}

/**
 * The line over the journey list: that the query leaves now, and the time
 * by which the journeys shown arrive, the earliest arrival plus the window.
 */
export function windowText({journeys, serviceDayStartsMs, timeZone}) {
  let earliestMs = Number.POSITIVE_INFINITY

  for (const journey of journeys) {
    const arrivalMs = absoluteMs({serviceDayStartsMs, serviceDate: journey.serviceDate, seconds: journey.arrivalS})
    earliestMs = Math.min(earliestMs, arrivalMs)
  }

  assertCondition(Number.isFinite(earliestMs), "trip plan: a window over no journey")
  const cutoffMs = earliestMs + WINDOW_SECONDS * SECOND_MS
  return `Leaving now · journeys arriving by ${clockText({ms: cutoffMs, timeZone})}`
}

function addBounded({values, value, countMax}) {
  if (values.size < countMax) {
    values.add(value)
  }
}

/**
 * The stops and the routes of `journeys` that the list names, each once,
 * at most `countMax` of each: the stops a leg boards, leaves, or walks
 * between, and the route of each ride.
 */
export function nameRequest({journeys, countMax}) {
  const stopIds = new Set()
  const routeIds = new Set()

  for (const journey of journeys) {
    for (const leg of journey.legs) {
      if (leg.kind === LegKind.ride) {
        addBounded({values: routeIds, value: leg.routeId, countMax})
        addBounded({values: stopIds, value: leg.fromStopId, countMax})
      } else if (leg.kind === LegKind.walk) {
        addBounded({values: stopIds, value: leg.fromStopId, countMax})
      }

      addBounded({values: stopIds, value: leg.toStopId, countMax})
    }
  }

  return {stopIds: Array.from(stopIds), routeIds: Array.from(routeIds)}
}

/**
 * The routes the filter of a trip whose selected journey is `journey`
 * names: the route of each ride, once, in the order the journey rides
 * them. A journey with no ride names none, and the page then keeps the
 * rider's own filter. `countMax` is the most a trip's filter names.
 */
export function tripRouteIds({journey, countMax}) {
  const routeIds = []

  for (const leg of journey.legs) {
    const isNewRide = leg.kind === LegKind.ride && routeIds.includes(leg.routeId) === false

    if (isNewRide) {
      routeIds.push(leg.routeId)
    }
  }

  assertCondition(routeIds.length <= countMax, "trip plan: a journey rides more routes than a trip's filter names: " + routeIds.length)
  return routeIds
}

// The position of `stopId` as a GeoJSON coordinate, or none.
function coordinatesOf({journey, stopId}) {
  const position = journey.stopPositions[stopId]

  if (position === undefined) {
    return []
  }

  return [[position.lon, position.lat]]
}

function lineFeature({coordinates, properties}) {
  return {type: "Feature", geometry: {type: "LineString", coordinates}, properties}
}

function pointFeature({coordinate, kind}) {
  return {type: "Feature", geometry: {type: "Point", coordinates: coordinate}, properties: {kind}}
}

function legCoordinates({journey, leg, origin}) {
  switch (leg.kind) {
    case LegKind.ride: {
      const coordinates = []

      for (const stopId of leg.stopIds) {
        for (const coordinate of coordinatesOf({journey, stopId})) {
          coordinates.push(coordinate)
        }
      }

      return coordinates
    }
    case LegKind.walk:
      return [...coordinatesOf({journey, stopId: leg.fromStopId}), ...coordinatesOf({journey, stopId: leg.toStopId})]
    case LegKind.walkFromPosition:
      return [...origin, ...coordinatesOf({journey, stopId: leg.toStopId})]
    default:
      return unreachable(leg.kind, "trip plan: a leg of unknown kind")
  }
}

/**
 * What the map draws of `journey`: a line per ride through the stops it
 * passes, in its route's color from `names`, a line per walk, and a point
 * at each end, as a GeoJSON feature collection, with the bounds of every
 * coordinate in it, a BoundsKind member. `origin` is the rider's position in degrees for a
 * journey from it, or null. A stop with no known position is left out of
 * its line, and a line with fewer than two points is not drawn.
 */
export function journeyFeatures({journey, names, origin}) {
  const originCoordinates = []

  if (origin !== null) {
    originCoordinates.push([origin.lon, origin.lat])
  }

  const lines = []
  const points = []

  for (const leg of journey.legs) {
    const coordinates = legCoordinates({journey, leg, origin: originCoordinates})
    let properties = {kind: FeatureKind.walk}

    if (leg.kind === LegKind.ride) {
      properties = {kind: FeatureKind.ride, color: routeChip({names, routeId: leg.routeId}).color}
    }

    if (coordinates.length >= LINE_POINT_COUNT_MIN) {
      lines.push(lineFeature({coordinates, properties}))
    }

    for (const coordinate of coordinates) {
      points.push(coordinate)
    }
  }

  const features = [...lines]
  const isPlaced = points.length > 0

  if (isPlaced) {
    features.push(pointFeature({coordinate: points[0], kind: FeatureKind.origin}))
    features.push(pointFeature({coordinate: points[points.length - 1], kind: FeatureKind.destination}))
  }

  return {collection: {type: "FeatureCollection", features}, bounds: boundsOf(points)}
}

// The bounds of `points`, [[west, south], [east, north]], or none.
function boundsOf(points) {
  if (points.length === 0) {
    return {kind: BoundsKind.none}
  }

  let [west, south] = points[0]
  let [east, north] = points[0]

  for (const [lon, lat] of points) {
    west = Math.min(west, lon)
    east = Math.max(east, lon)
    south = Math.min(south, lat)
    north = Math.max(north, lat)
  }

  return {kind: BoundsKind.bounds, bounds: [[west, south], [east, north]]}
}
