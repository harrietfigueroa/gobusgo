// Where the schedule places the trips running now, and when it brings them
// to a stop, from the saved routing snapshots. Everything here is pure: the
// decoded snapshot tables, the time, and the routes the filter keeps are
// given as values, so the markers and the arrivals an offline page shows are
// functions of them alone.
//
// A trip is placed on the straight line between the two stops of the hop it
// is on, by the share of the hop's time that has passed, and at a stop while
// it waits there. Delays, cancellations, and detours are not known, so every
// marker carries the `scheduled` status. A saved snapshot, as the page reads
// it, is `{serviceDate, serviceDayStartMs, connectionChunks, stopIndexes,
// trips, positions, names, connections}`: `connectionChunks` is its manifest
// entry's, `trips`, `positions`, and `names` are each a table keyed by
// `kind`, found or missing, and `connections` holds the decoded chunks the
// page read for the time, those `chunksAt` names, in departure order.

import {assertCondition} from "./assert.js"
import {lerp} from "./math/interpolation.js"
import {TableKind, savedRouteChip, savedRouteName} from "./offline_answers.js"
import {POSITION_UNKNOWN_MICRODEGREES} from "./routing_snapshot.js"
import {connectionsByTrip, fallbackPath} from "./scheduled_path.js"

/** How often an offline page places its markers and writes its arrivals again. */
export const SCHEDULE_REFRESH_MS = 10 * 1000

/** The most markers an offline page draws. */
export const SCHEDULED_MARKER_COUNT_MAX = 3000

/** How far before the time a page reads connections, so a trip on a long hop is placed. */
export const LOOKBACK_SECONDS = 60 * 60

/** How far after the time a stop's arrivals reach, the window OneBusAway answers by default. */
export const ARRIVAL_HORIZON_SECONDS = 35 * 60

/** The most arrivals shown for one stop, as the server shows them. */
export const ARRIVAL_COUNT_MAX = 8

/** The most departures a stop's list holds. */
export const DEPARTURE_COUNT_MAX = 40

/** The most connection chunks of one date a page reads for the time. */
export const CHUNK_READ_COUNT_MAX = 4

/** The kinds of the routes a filter keeps: every route, or a list. */
export const KeptKind = Object.freeze({every: "every", routes: "routes"})

/** The kinds of a stop's departures: the list, or no snapshot holding the stop. */
export const DeparturesKind = Object.freeze({found: "found", unknownStop: "unknownStop"})

/** The status every scheduled marker carries. */
export const SCHEDULED_STATUS = "scheduled"

const SECOND_MS = 1000
const MINUTE_SECONDS = 60
const MINUTE_MS = 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const MICRODEGREES_PER_DEGREE = 1000000
const PREVIOUS_DATE_OFFSET = 1
const ISO_DATE_LENGTH = 10
const NO_LOCATION_REPORTED = "No location reported"
const REAL_TIME_NO = "No"
const NO_CONNECTION = -1

function assertTime(nowMs) {
  assertCondition(Number.isFinite(nowMs), `the time is a number: ${nowMs}`)
}

// The instant the last connection of `entry` departs, in milliseconds since
// the Unix epoch; past it the date places nothing.
function validUntilMs(entry) {
  let lastDepartureS = 0

  for (const chunk of entry.connectionChunks) {
    lastDepartureS = Math.max(lastDepartureS, chunk.departureSMax)
  }

  return entry.serviceDayStartMs + lastDepartureS * SECOND_MS
}

function secondsOfDay({snapshot, nowMs}) {
  return (nowMs - snapshot.serviceDayStartMs) / SECOND_MS
}

/**
 * The connection chunks of `entry` a page reads at `nowMs`: those departing
 * from LOOKBACK_SECONDS before the time to ARRIVAL_HORIZON_SECONDS after it,
 * in the manifest's order, at most CHUNK_READ_COUNT_MAX, and none once the
 * date's last connection has departed.
 */
export function chunksAt({entry, nowMs}) {
  assertTime(nowMs)

  if (nowMs > validUntilMs(entry)) {
    return []
  }

  const timeS = secondsOfDay({snapshot: entry, nowMs})
  const windowStartS = timeS - LOOKBACK_SECONDS
  const windowEndS = timeS + ARRIVAL_HORIZON_SECONDS
  const chunks = []

  for (const chunk of entry.connectionChunks) {
    const endsInWindow = chunk.departureSMax >= windowStartS
    const isInWindow = endsInWindow && chunk.departureSMin <= windowEndS
    const hasRoom = chunks.length < CHUNK_READ_COUNT_MAX

    if (!hasRoom) {
      break
    }

    if (isInWindow) {
      chunks.push(chunk)
    }
  }

  return chunks
}

// The ISO 8601 date the day before `serviceDate`.
function previousDate(serviceDate) {
  const dayMs = Date.parse(`${serviceDate}T00:00:00.000Z`)
  assertCondition(Number.isFinite(dayMs), `a service date is an ISO 8601 date: ${serviceDate}`)
  const previous = new Date(dayMs - DAY_MS)
  return previous.toISOString().slice(0, ISO_DATE_LENGTH)
}

// The key of one run of a trip, the same in both snapshots that hold it:
// the date it runs on and its identifier.
function runKeyOf({snapshot, trip}) {
  if (trip.serviceDayOffset === PREVIOUS_DATE_OFFSET) {
    return `${previousDate(snapshot.serviceDate)}/${trip.id}`
  }

  return `${snapshot.serviceDate}/${trip.id}`
}

// The start of the service day `trip` runs on, in milliseconds: its
// snapshot's own, or for a run of the previous date the start of that date's
// snapshot among `snapshots`, found, or missing where that snapshot is not
// saved.
function runStartOf({snapshots, snapshot, trip}) {
  if (trip.serviceDayOffset !== PREVIOUS_DATE_OFFSET) {
    return {kind: TableKind.found, startMs: snapshot.serviceDayStartMs}
  }

  const serviceDate = previousDate(snapshot.serviceDate)

  for (const saved of snapshots) {
    if (saved.serviceDate === serviceDate) {
      return {kind: TableKind.found, startMs: saved.serviceDayStartMs}
    }
  }

  return {kind: TableKind.missing}
}

// Whether `snapshot` can be read for trips at `nowMs`: its trips are saved
// and its last connection has not departed.
function isReadable({snapshot, nowMs}) {
  const hasTrips = snapshot.trips.kind === TableKind.found
  const isValid = nowMs <= validUntilMs(snapshot)
  return hasTrips && isValid
}

// Whether `snapshot` can place trips at `nowMs`: it is readable and its
// stop positions are saved.
function isPlaceable({snapshot, nowMs}) {
  const hasPositions = snapshot.positions.kind === TableKind.found
  return hasPositions && isReadable({snapshot, nowMs})
}

function isRouteKept({kept, routeId}) {
  if (kept.kind === KeptKind.every) {
    return true
  }

  return kept.routeIds.includes(routeId)
}

// For each trip, the chunk and index of its last connection departing at or
// before `timeS` and of its first departing after it, or NO_CONNECTION.
function tripConnections({snapshot, timeS}) {
  const tripCount = snapshot.trips.table.length
  const latestChunk = new Int32Array(tripCount).fill(NO_CONNECTION)
  const latestIndex = new Int32Array(tripCount)
  const nextChunk = new Int32Array(tripCount).fill(NO_CONNECTION)
  const nextIndex = new Int32Array(tripCount)

  for (const [chunkIndex, chunk] of snapshot.connections.entries()) {
    const count = chunk.departureS.length

    for (let index = 0; index < count; index++) {
      const trip = chunk.trip[index]
      assertCondition(trip < tripCount, `a connection names a trip of its snapshot: ${trip}`)

      if (chunk.departureS[index] <= timeS) {
        latestChunk[trip] = chunkIndex
        latestIndex[trip] = index
      } else if (nextChunk[trip] === NO_CONNECTION) {
        nextChunk[trip] = chunkIndex
        nextIndex[trip] = index
      }
    }
  }

  return {latestChunk, latestIndex, nextChunk, nextIndex}
}

function connectionAt({snapshot, chunkIndex, index}) {
  const chunk = snapshot.connections[chunkIndex]

  return {
    departureS: chunk.departureS[index],
    arrivalS: chunk.arrivalS[index],
    departureStop: chunk.departureStop[index],
    arrivalStop: chunk.arrivalStop[index],
    sequence: chunk.sequence[index]
  }
}

// Where the trip of `latest`, its last connection departed by `timeS`, is
// at `timeS`: on that hop, or waiting at its arrival stop for `next`, its
// following connection. A trip whose last connection has arrived and that
// has no following one, or whose following one leaves from elsewhere, has
// ended.
function placementOf({latest, next, timeS}) {
  if (latest.arrivalS >= timeS) {
    const hopS = latest.arrivalS - latest.departureS
    let share = 1

    if (hopS > 0) {
      share = (timeS - latest.departureS) / hopS
    }

    return {isRunning: true, fromStop: latest.departureStop, toStop: latest.arrivalStop, share, nextStop: latest.arrivalStop, nextArrivalS: latest.arrivalS}
  }

  if (next.kind === TableKind.missing) {
    return {isRunning: false}
  }

  const following = next.connection
  const isFollowing = following.sequence === latest.sequence + 1
  const isWaiting = isFollowing && following.departureStop === latest.arrivalStop

  if (!isWaiting) {
    return {isRunning: false}
  }

  return {isRunning: true, fromStop: latest.arrivalStop, toStop: latest.arrivalStop, share: 1, nextStop: following.arrivalStop, nextArrivalS: following.arrivalS}
}

function stopPositionOf({positions, stop}) {
  const latMicrodegrees = positions.latMicrodegrees[stop]
  const lonMicrodegrees = positions.lonMicrodegrees[stop]

  if (latMicrodegrees === POSITION_UNKNOWN_MICRODEGREES) {
    return {kind: TableKind.missing}
  }

  return {kind: TableKind.found, latMicrodegrees, lonMicrodegrees}
}

// The point a share of the way from one stop to the other, in degrees, or
// missing where either stop has no known position.
function pointOf({positions, placement}) {
  const from = stopPositionOf({positions, stop: placement.fromStop})
  const to = stopPositionOf({positions, stop: placement.toStop})
  const isFromKnown = from.kind === TableKind.found
  const isKnown = isFromKnown && to.kind === TableKind.found

  if (!isKnown) {
    return {kind: TableKind.missing}
  }

  const latMicrodegrees = lerp({from: from.latMicrodegrees, to: to.latMicrodegrees, fraction: placement.share})
  const lonMicrodegrees = lerp({from: from.lonMicrodegrees, to: to.lonMicrodegrees, fraction: placement.share})
  return {kind: TableKind.found, lat: latMicrodegrees / MICRODEGREES_PER_DEGREE, lon: lonMicrodegrees / MICRODEGREES_PER_DEGREE}
}

// How soon a stop `offsetS` away is, in the server's texts.
function timeAwayText(offsetS) {
  const minutes = Math.floor(offsetS / MINUTE_SECONDS)

  if (minutes === 0) {
    return "under 1 min"
  }

  return `${minutes} min`
}

// The next stop's text as the server writes it: its name and how soon, or
// how soon alone for a stop with no saved name.
function nextStopText({names, stop, offsetS}) {
  const timeAway = timeAwayText(offsetS)

  if (names.kind === TableKind.missing) {
    return timeAway
  }

  const name = names.table.stopNames[stop]

  if (typeof name === "string") {
    return `${name} · ${timeAway}`
  }

  return timeAway
}

function routeOf({names, routeId}) {
  if (names.kind === TableKind.missing) {
    return {kind: TableKind.missing}
  }

  if (Object.hasOwn(names.table.routes, routeId)) {
    return {kind: TableKind.found, route: names.table.routes[routeId]}
  }

  return {kind: TableKind.missing}
}

// The name a route is shown under: its saved name, or its identifier.
function routeNameOf({names, routeId}) {
  const saved = routeOf({names, routeId})

  if (saved.kind === TableKind.missing) {
    return routeId
  }

  return savedRouteName({route: saved.route, routeId})
}

// The trip's saved headsign, or missing where no names file or no headsign
// is saved.
function headsignOf({names, trip}) {
  if (names.kind === TableKind.missing) {
    return {kind: TableKind.missing}
  }

  const headsign = names.table.tripHeadsigns[trip]

  if (typeof headsign === "string") {
    return {kind: TableKind.found, headsign}
  }

  return {kind: TableKind.missing}
}

function markerOf({snapshot, trip, runKey, runStart, point, placement, timeS, color}) {
  const {routeId} = snapshot.trips.table[trip]
  const {names} = snapshot
  const savedHeadsign = headsignOf({names, trip})
  // The server's marker holds null for a trip with no headsign.
  let headsign = null

  if (savedHeadsign.kind === TableKind.found) {
    headsign = savedHeadsign.headsign
  }

  let serviceDateMs = null

  if (runStart.kind === TableKind.found) {
    serviceDateMs = runStart.startMs
  }

  return {
    id: `scheduled/${runKey}`,
    vehicle_id: null,
    lat: point.lat,
    lon: point.lon,
    color,
    heading: null,
    route_id: routeId,
    route: routeNameOf({names, routeId}),
    headsign,
    schedule: null,
    next_stop: nextStopText({names, stop: placement.nextStop, offsetS: placement.nextArrivalS - timeS}),
    status: SCHEDULED_STATUS,
    location_age: NO_LOCATION_REPORTED,
    real_time: REAL_TIME_NO,
    trip_id: snapshot.trips.table[trip].id,
    service_date_ms: serviceDateMs,
    is_saved_schedule: true
  }
}

// The connection a trip's `chunks` and `indexes` name for it, or missing.
function connectionOf({snapshot, chunks, indexes, trip}) {
  const chunkIndex = chunks[trip]

  if (chunkIndex === NO_CONNECTION) {
    return {kind: TableKind.missing}
  }

  const connection = connectionAt({snapshot, chunkIndex, index: indexes[trip]})
  return {kind: TableKind.found, connection}
}

// Adds the markers of `snapshot` to `placed`, keyed by run, skipping the
// runs a snapshot read before placed, and gives the count of running trips
// it could not place for a stop with no known position.
function placeSnapshot({snapshots, snapshot, nowMs, kept, color, placed}) {
  const timeS = secondsOfDay({snapshot, nowMs})
  const {latestChunk, latestIndex, nextChunk, nextIndex} = tripConnections({snapshot, timeS})
  const trips = snapshot.trips.table
  let unplacedCount = 0

  for (const [trip, record] of trips.entries()) {
    const hasLatest = latestChunk[trip] !== NO_CONNECTION
    const isCandidate = hasLatest && isRouteKept({kept, routeId: record.routeId})

    if (!isCandidate) {
      continue
    }

    const runKey = runKeyOf({snapshot, trip: record})

    if (placed.has(runKey)) {
      continue
    }

    const latest = connectionOf({snapshot, chunks: latestChunk, indexes: latestIndex, trip})
    assertCondition(latest.kind === TableKind.found, `a candidate trip has a connection departed: ${trip}`)
    const next = connectionOf({snapshot, chunks: nextChunk, indexes: nextIndex, trip})
    const placement = placementOf({latest: latest.connection, next, timeS})

    if (!placement.isRunning) {
      continue
    }

    const point = pointOf({positions: snapshot.positions.table, placement})

    if (point.kind === TableKind.missing) {
      unplacedCount += 1
      continue
    }

    const runStart = runStartOf({snapshots, snapshot, trip: record})
    const marker = markerOf({snapshot, trip, runKey, runStart, point, placement, timeS, color})
    placed.set(runKey, {marker, snapshot, trip})
  }

  return unplacedCount
}

// The fallback path of the marker of `markerId` among `origins`, the snapshot
// and trip index each marker was placed from, found once and kept; the
// connections of a snapshot are grouped by trip the first time one of its
// markers asks.
function fallbackPathReaderOf(origins) {
  const groupedBySnapshot = new Map()
  const paths = new Map()

  return function fallbackPathOf(markerId) {
    if (paths.has(markerId)) {
      return paths.get(markerId)
    }

    let read = {kind: TableKind.missing}

    if (origins.has(markerId)) {
      const {snapshot, trip} = origins.get(markerId)

      if (!groupedBySnapshot.has(snapshot)) {
        groupedBySnapshot.set(snapshot, connectionsByTrip(snapshot))
      }

      const connections = groupedBySnapshot.get(snapshot).get(trip)

      if (connections !== undefined) {
        read = fallbackPath({snapshot, trip, connections})
      }
    }

    paths.set(markerId, read)
    return read
  }
}

/**
 * The markers of the trips running at `nowMs` in `snapshots`, read in the
 * order given, on the routes `kept` keeps, each in `color`: at most
 * `countMax`, with `droppedCount` past the bound and `unplacedCount` for the
 * running trips at a stop with no known position. A trip both dates hold is
 * placed once, from the first snapshot that places it. Each marker names its
 * `trip_id` and the `service_date_ms` its run starts on, null where that
 * date's snapshot is not saved, and `fallbackPathOf(markerId)` gives the
 * path of straight lines between the stops of its trip, found or missing.
 */
export function scheduledMarkers({snapshots, nowMs, kept, color, countMax}) {
  assertTime(nowMs)
  assertCondition(Number.isSafeInteger(countMax), `the most markers is a whole number: ${countMax}`)
  assertCondition(countMax >= 0, `the most markers is not negative: ${countMax}`)
  const placed = new Map()
  let unplacedCount = 0

  for (const snapshot of snapshots) {
    if (isPlaceable({snapshot, nowMs})) {
      unplacedCount += placeSnapshot({snapshots, snapshot, nowMs, kept, color, placed})
    }
  }

  const all = Array.from(placed.values())
  const bounded = all.slice(0, countMax)
  assertCondition(bounded.length <= countMax, `the markers are bounded: ${bounded.length}`)
  const markers = []
  const origins = new Map()

  for (const {marker, snapshot, trip} of bounded) {
    markers.push(marker)
    origins.set(marker.id, {snapshot, trip})
  }

  return {markers, droppedCount: all.length - markers.length, unplacedCount, fallbackPathOf: fallbackPathReaderOf(origins)}
}

// The headsign `headsign` as a stop's arrival shows it on `routeId`, as the
// server shows it: without the route's short name where it starts with it.
function arrivalHeadsignText({names, headsign, routeId}) {
  const saved = routeOf({names, routeId})
  const isRouteSaved = saved.kind === TableKind.found
  const hasShortName = isRouteSaved && typeof saved.route.shortName === "string"

  if (!hasShortName) {
    return headsign
  }

  const prefix = `${saved.route.shortName} `
  const rest = headsign.slice(prefix.length).trim()
  const startsWithPrefix = headsign.startsWith(prefix)
  const isPrefixed = startsWithPrefix && rest !== ""

  if (isPrefixed) {
    return rest
  }

  return headsign
}

// Each visit of a trip to `stop` in the read chunks, keyed by trip and the
// visit's place in the trip: its arrival where riders can get off there,
// and otherwise its departure where they can get on, which is a trip's
// first stop or a stop it only picks up at.
function visitsOf({snapshot, stop}) {
  const arrivals = new Map()
  const departures = new Map()

  for (const chunk of snapshot.connections) {
    const count = chunk.departureS.length

    for (let index = 0; index < count; index++) {
      const isArrivalHere = chunk.arrivalStop[index] === stop
      const isArrival = isArrivalHere && chunk.alighting[index] === 1
      const isDepartureHere = chunk.departureStop[index] === stop
      const isDeparture = isDepartureHere && chunk.boarding[index] === 1

      if (isArrival) {
        arrivals.set(`${chunk.trip[index]}:${chunk.sequence[index] + 1}`, {trip: chunk.trip[index], timeS: chunk.arrivalS[index]})
      }

      if (isDeparture) {
        departures.set(`${chunk.trip[index]}:${chunk.sequence[index]}`, {trip: chunk.trip[index], timeS: chunk.departureS[index]})
      }
    }
  }

  for (const [key, visit] of departures) {
    if (!arrivals.has(key)) {
      arrivals.set(key, visit)
    }
  }

  return arrivals.values()
}

// Adds to `soonest`, keyed by run, each run's soonest visit to the stop
// within the horizon that `snapshot` holds, keeping a sooner one already
// there.
function addArrivals({snapshot, stop, nowMs, soonest}) {
  const horizonMs = nowMs + ARRIVAL_HORIZON_SECONDS * SECOND_MS

  for (const visit of visitsOf({snapshot, stop})) {
    const timeMs = snapshot.serviceDayStartMs + visit.timeS * SECOND_MS
    const isComing = timeMs >= nowMs
    const isShown = isComing && timeMs <= horizonMs

    if (!isShown) {
      continue
    }

    const record = snapshot.trips.table[visit.trip]
    const runKey = runKeyOf({snapshot, trip: record})
    const held = soonest.get(runKey)
    const isSooner = held === undefined || timeMs < held.timeMs

    if (isSooner) {
      soonest.set(runKey, {timeMs, snapshot, trip: visit.trip, routeId: record.routeId})
    }
  }
}

function bySoonest(left, right) {
  return left.timeMs - right.timeMs
}

function lineOf({arrival, nowMs}) {
  const {snapshot, trip, routeId} = arrival
  const {names} = snapshot
  const savedHeadsign = headsignOf({names, trip})
  // The server's arrival holds null for a trip with no headsign.
  let headsign = null

  if (savedHeadsign.kind === TableKind.found) {
    headsign = arrivalHeadsignText({names, headsign: savedHeadsign.headsign, routeId})
  }

  return {
    route: routeNameOf({names, routeId}),
    headsign,
    minutes: Math.floor((arrival.timeMs - nowMs) / MINUTE_MS),
    time_ms: arrival.timeMs,
    predicted: false
  }
}

/**
 * What a page shows of the arrivals at `stopId` at `nowMs`, in the server's
 * shape with `scheduled` set: each trip's next visit within
 * ARRIVAL_HORIZON_SECONDS, the soonest first, at most ARRIVAL_COUNT_MAX, all
 * scheduled; or refused for a stop no snapshot holds.
 */
export function scheduledArrivals({snapshots, stopId, nowMs}) {
  assertTime(nowMs)
  const soonest = new Map()
  let isHeld = false

  for (const snapshot of snapshots) {
    const stop = snapshot.stopIndexes.get(stopId)
    const isStopHeld = stop !== undefined
    const isStopReadable = isStopHeld && isReadable({snapshot, nowMs})

    if (isStopHeld) {
      isHeld = true
    }

    if (isStopReadable) {
      addArrivals({snapshot, stop, nowMs, soonest})
    }
  }

  if (!isHeld) {
    return {stop_id: stopId, status: "refused"}
  }

  const ordered = Array.from(soonest.values()).sort(bySoonest)
  const shown = ordered.slice(0, ARRIVAL_COUNT_MAX)
  const arrivals = []

  for (const arrival of shown) {
    arrivals.push(lineOf({arrival, nowMs}))
  }

  return {stop_id: stopId, status: "arrivals", age_minutes: 0, scheduled: true, arrivals}
}

/**
 * The connection chunks of `entry` that hold a departure at or after
 * `fromMs`, in the manifest's order, which are the chunks a list of
 * departures from that time reads.
 */
export function chunksFrom({entry, fromMs}) {
  assertTime(fromMs)
  const fromS = secondsOfDay({snapshot: entry, nowMs: fromMs})
  const chunks = []

  for (const chunk of entry.connectionChunks) {
    if (chunk.departureSMax >= fromS) {
      chunks.push(chunk)
    }
  }

  return chunks
}

// Each boarding at `stop` in the read chunks: the trip's connection that
// leaves it, where riders can get on. A trip's last stop has none.
function boardingsOf({snapshot, stop}) {
  const boardings = []

  for (const chunk of snapshot.connections) {
    const count = chunk.departureS.length

    for (let index = 0; index < count; index++) {
      const isDepartureHere = chunk.departureStop[index] === stop

      const isBoarding = isDepartureHere && chunk.boarding[index] === 1

      if (isBoarding) {
        boardings.push({trip: chunk.trip[index], sequence: chunk.sequence[index], timeS: chunk.departureS[index]})
      }
    }
  }

  return boardings
}

// Adds to `listed`, keyed by run and the hop's sequence, each boarding at
// the stop at or after `fromMs` that `snapshot` holds on a kept route,
// leaving one a snapshot read before listed: the previous date's trips
// are in both snapshots that hold their run.
function addDepartures({snapshot, stop, fromMs, kept, listed}) {
  for (const boarding of boardingsOf({snapshot, stop})) {
    const timeMs = snapshot.serviceDayStartMs + boarding.timeS * SECOND_MS
    const record = snapshot.trips.table[boarding.trip]
    const isListed = timeMs >= fromMs && isRouteKept({kept, routeId: record.routeId})

    if (isListed) {
      const key = `${runKeyOf({snapshot, trip: record})}:${boarding.sequence}`

      if (!listed.has(key)) {
        listed.set(key, {timeMs, snapshot, trip: boarding.trip, routeId: record.routeId})
      }
    }
  }
}

// The route's color as a CSS color, or null where no names file is saved or it holds no such route.
function routeColorOf({names, routeId}) {
  const saved = routeOf({names, routeId})
  let color = null

  if (saved.kind === TableKind.found) {
    color = savedRouteChip({route: saved.route, routeId}).color
  }

  return color
}

function departureLineOf(departure) {
  const {snapshot, trip, routeId, timeMs} = departure
  const {names} = snapshot
  const savedHeadsign = headsignOf({names, trip})
  let headsign = null

  if (savedHeadsign.kind === TableKind.found) {
    headsign = arrivalHeadsignText({names, headsign: savedHeadsign.headsign, routeId})
  }

  return {timeMs, tripId: snapshot.trips.table[trip].id, routeId, route: routeNameOf({names, routeId}), color: routeColorOf({names, routeId}), headsign}
}

/**
 * The scheduled departures from `stopId` at or after `fromMs` in
 * `snapshots`, read in the order given, on the routes `kept` keeps, the
 * soonest first: a DeparturesKind member, found with at most `countMax`
 * departures and the `droppedCount` past the bound, or `unknownStop` where
 * no snapshot holds the stop. A departure is a boarding, so a trip's last
 * stop is none, and a trip both dates hold is listed once, from the first
 * snapshot that holds it. Each departure names its `tripId`, route, the
 * route's `color` and `headsign`, null where no names file gives one.
 */
export function scheduledDepartures({snapshots, stopId, fromMs, kept, countMax}) {
  assertTime(fromMs)
  assertCondition(Number.isSafeInteger(countMax), `the most departures is a whole number: ${countMax}`)
  assertCondition(countMax >= 0, `the most departures is not negative: ${countMax}`)
  const listed = new Map()
  let isHeld = false

  for (const snapshot of snapshots) {
    const stop = snapshot.stopIndexes.get(stopId)

    if (stop !== undefined) {
      isHeld = true
    }

    const isReadableHere = stop !== undefined && snapshot.trips.kind === TableKind.found

    if (isReadableHere) {
      addDepartures({snapshot, stop, fromMs, kept, listed})
    }
  }

  if (!isHeld) {
    return {kind: DeparturesKind.unknownStop}
  }

  const ordered = Array.from(listed.values()).sort(bySoonest)
  const shown = ordered.slice(0, countMax)
  const departures = []

  for (const departure of shown) {
    departures.push(departureLineOf(departure))
  }

  return {kind: DeparturesKind.found, departures, droppedCount: ordered.length - shown.length}
}
