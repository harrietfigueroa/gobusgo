// The path of a scheduled trip drawn from the saved snapshot alone: the
// straight lines between the stops the trip serves in the connection chunks
// the page read, with the times the schedule gives them. It has the shape a
// trip path is prepared from, so a trip no saved trip path shard covers moves
// like one that has a road path. Everything here is pure: the decoded
// snapshot and the trip are given as values.

import {assertCondition} from "./assert.js"
import {distanceMeters} from "./math/geodesy.js"
import {TableKind} from "./offline_answers.js"
import {POSITION_UNKNOWN_MICRODEGREES} from "./routing_snapshot.js"
import {isTripHeldBack} from "./trip_path_files.js"

const MICRODEGREES_PER_DEGREE = 1000000
// A path has a start and an end.
const PATH_STOP_COUNT_MIN = 2

/**
 * Whether `marker`, as the saved schedule places it, takes its fallback path
 * at `nowMs`: it is the saved schedule's, and either its date has no saved
 * snapshot, so no trip path shard names it, or the trip path `files` cannot
 * serve its trip and hold it back. A trip the files have not decided yet
 * takes none.
 */
export function isFallbackDue({marker, files, nowMs}) {
  if (marker.is_saved_schedule !== true) {
    return false
  }

  if (!Number.isSafeInteger(marker.service_date_ms)) {
    return true
  }

  const trip = {tripId: marker.trip_id, routeId: marker.route_id, serviceDateMs: marker.service_date_ms}
  return isTripHeldBack({files, trip, nowMs})
}

/**
 * The connections of each trip of `snapshot` in the chunks it holds, by
 * trip index, in departure order. A snapshot is `{trips, positions,
 * connections, serviceDayStartMs}` as the saved snapshots give them.
 */
export function connectionsByTrip(snapshot) {
  const byTrip = new Map()

  for (const chunk of snapshot.connections) {
    const count = chunk.departureS.length

    for (let index = 0; index < count; index++) {
      const trip = chunk.trip[index]

      if (!byTrip.has(trip)) {
        byTrip.set(trip, [])
      }

      byTrip.get(trip).push({
        departureS: chunk.departureS[index],
        arrivalS: chunk.arrivalS[index],
        departureStop: chunk.departureStop[index],
        arrivalStop: chunk.arrivalStop[index]
      })
    }
  }

  return byTrip
}

// The stops `connections` visit in order, each with its arrival and its
// departure in seconds: a stop a connection arrives at departs when the
// next connection leaves it, and a stop with no connection after it departs
// as it arrives.
function visitsOf(connections) {
  const [first] = connections
  const visits = [{stop: first.departureStop, arrivalS: first.departureS, departureS: first.departureS}]

  for (const connection of connections) {
    const last = visits[visits.length - 1]

    if (connection.departureStop === last.stop) {
      last.departureS = Math.max(last.departureS, connection.departureS)
    } else {
      visits.push({stop: connection.departureStop, arrivalS: connection.departureS, departureS: connection.departureS})
    }

    visits.push({stop: connection.arrivalStop, arrivalS: connection.arrivalS, departureS: connection.arrivalS})
  }

  return visits
}

// The [lon, lat] of `stop`, or null for a stop with no known position.
function pointOfStop({positions, stop}) {
  const latMicrodegrees = positions.latMicrodegrees[stop]
  const lonMicrodegrees = positions.lonMicrodegrees[stop]

  if (latMicrodegrees === POSITION_UNKNOWN_MICRODEGREES) {
    return null
  }

  return [lonMicrodegrees / MICRODEGREES_PER_DEGREE, latMicrodegrees / MICRODEGREES_PER_DEGREE]
}

/**
 * The fallback path of `trip`, a trip index of `snapshot`, given
 * `connections`, the trip's connections `connectionsByTrip` holds: found
 * with a `path` of `tripId`, `serviceDateMs`, the snapshot's own day start,
 * `points`, each stop's `[lon, lat]`, and `stops`, each with its
 * `distanceMeters` along the lines and its `arrivalSeconds` and
 * `departureSeconds` after the day start; or missing where fewer than two
 * stops of the trip have a known position. A stop with no known position is
 * left out, and a time that runs backward is held at the one before it.
 */
export function fallbackPath({snapshot, trip, connections}) {
  assertCondition(Array.isArray(connections), "a trip's connections are a list")
  const record = snapshot.trips.table[trip]
  assertCondition(record !== undefined, `the snapshot holds trip ${trip}`)

  if (connections.length === 0) {
    return {kind: TableKind.missing}
  }

  const points = []
  const stops = []
  let departedS = 0
  let meters = 0

  for (const visit of visitsOf(connections)) {
    const point = pointOfStop({positions: snapshot.positions.table, stop: visit.stop})

    if (point === null) {
      continue
    }

    if (points.length > 0) {
      meters += distanceMeters(points[points.length - 1], point)
    }

    const arrivalSeconds = Math.max(visit.arrivalS, departedS)
    const departureSeconds = Math.max(visit.departureS, arrivalSeconds)
    points.push(point)
    stops.push({distanceMeters: meters, arrivalSeconds, departureSeconds})
    departedS = departureSeconds
  }

  if (stops.length < PATH_STOP_COUNT_MIN) {
    return {kind: TableKind.missing}
  }

  const path = {tripId: record.id, serviceDateMs: snapshot.serviceDayStartMs, points, stops}
  return {kind: TableKind.found, path}
}
