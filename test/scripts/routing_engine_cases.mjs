// Turns the engine's hand-written fixtures, timetables with queries whose
// frontiers are written as readable legs, into the engine's own terms: per
// case the inputs `createEngine` takes, as JSON numbers, and per query the
// query `route` or `routeArrivingBy` takes with the frontier written for it,
// its stops and connections as indices. A frontier is translated from the
// readable legs and never routed, so the expectation stays the one written
// by hand. Everything here is pure, so the conformance suite runs it to check
// that the written file is current.

import {assertCondition, unreachable} from "../../assets/js/core/assert.js"
import {TRANSFER_RULES, seconds, snapshotOf} from "./routing_timetable.js"

const FORMAT_NOTE =
  "Written by test/scripts/routing_engine_fixtures.mjs from journeys.json and starts.json, whose frontiers are written by hand. Each case holds the arguments of createEngine: the stop count, the connection columns in departure order with the boarding and alighting flags as 1 or 0, the walking link columns in the order of the stop they leave, and the minimum transfer. Each query is as route ('leaving') or routeArrivingBy ('arrivingBy') takes it, with its expected frontier, stops and connections as indices into the case's columns."

const LegKind = Object.freeze({ride: "ride", walk: "walk", walkFromPosition: "walkFromPosition"})
const OriginKind = Object.freeze({stop: "stop", starts: "starts"})
const QueryKind = Object.freeze({leaving: "leaving", arrivingBy: "arrivingBy"})
const CONNECTION_COLUMN_NAMES = Object.freeze(["departureS", "arrivalS", "departureStop", "arrivalStop", "trip", "sequence", "boarding", "alighting"])
const LINK_COLUMN_NAMES = Object.freeze(["fromStop", "toStop", "durationS"])
const RIDE_PART_COUNT = 6
const WALK_PART_COUNT = 4
const POSITION_WALK_PART_COUNT = 3

/**
 * The engine cases of the parsed hand-written fixtures, those from a stop
 * in `journeys` and those from start stops in `starts`, in that order.
 */
export function engineCases({journeys, starts}) {
  const cases = []

  for (const fixture of journeys.cases) {
    cases.push(engineCase(fixture))
  }

  for (const fixture of starts.cases) {
    cases.push(engineCase(fixture))
  }

  return {formatNote: FORMAT_NOTE, cases}
}

function engineCase(fixture) {
  const snapshot = snapshotOf(fixture)
  const connections = columnsOf({records: snapshot.connections, names: CONNECTION_COLUMN_NAMES})
  const transfers = columnsOf({records: snapshot.links, names: LINK_COLUMN_NAMES})
  const engine = {stopCount: snapshot.stopIds.length, connections, transfers, minimumTransferS: TRANSFER_RULES.minimumTransferS}
  const queries = []

  for (const query of fixture.queries) {
    queries.push(engineQuery({snapshot, query}))
  }

  return {name: fixture.name, stopIds: snapshot.stopIds, engine, queries}
}

// A connection's flag is 1 or 0 in the engine's columns.
function cellOf(value) {
  if (value === true) {
    return 1
  }

  if (value === false) {
    return 0
  }

  assertCondition(Number.isInteger(value), "routing engine cases: a column holds " + value)
  return value
}

function columnsOf({records, names}) {
  const columns = {}

  for (const name of names) {
    const column = []

    for (const record of records) {
      column.push(cellOf(record[name]))
    }

    columns[name] = column
  }

  return columns
}

function stopOf({snapshot, stopId}) {
  const stop = snapshot.stopIndex.get(stopId)
  assertCondition(stop !== undefined, "routing engine cases: no stop " + stopId)
  return stop
}

function tripOf({snapshot, tripId}) {
  const trip = snapshot.tripIds.indexOf(tripId)
  const lastTrip = snapshot.tripIds.lastIndexOf(tripId)
  assertCondition(trip >= 0, "routing engine cases: no trip " + tripId)
  assertCondition(trip === lastTrip, "routing engine cases: the trip " + tripId + " is named twice")
  return trip
}

function onlyIndex({indices, leg}) {
  assertCondition(indices.length === 1, "routing engine cases: " + indices.length + " connections match " + leg)
  return indices[0]
}

function boardConnection({snapshot, trip, stop, departureS, leg}) {
  const indices = []

  for (const [index, connection] of snapshot.connections.entries()) {
    const isTrip = connection.trip === trip
    const isStop = isTrip && connection.departureStop === stop
    const isBoarding = isStop && connection.departureS === departureS

    if (isBoarding) {
      indices.push(index)
    }
  }

  return onlyIndex({indices, leg})
}

function alightConnection({snapshot, trip, stop, arrivalS, leg}) {
  const indices = []

  for (const [index, connection] of snapshot.connections.entries()) {
    const isTrip = connection.trip === trip
    const isStop = isTrip && connection.arrivalStop === stop
    const isAlighting = isStop && connection.arrivalS === arrivalS

    if (isAlighting) {
      indices.push(index)
    }
  }

  return onlyIndex({indices, leg})
}

function wholeSeconds(text) {
  const durationS = Number(text)
  assertCondition(Number.isInteger(durationS), "routing engine cases: a walk of " + text + " seconds")
  return durationS
}

// `ride TRIP FROM HH:MM TO HH:MM`.
function rideOf({snapshot, parts, leg}) {
  assertCondition(parts.length === RIDE_PART_COUNT, "routing engine cases: a ride of " + parts.length + " parts: " + leg)
  const [, tripId, fromId, departure, toId, arrival] = parts
  const trip = tripOf({snapshot, tripId})
  const fromStop = stopOf({snapshot, stopId: fromId})
  const toStop = stopOf({snapshot, stopId: toId})
  const departureS = seconds(departure)
  const arrivalS = seconds(arrival)
  const board = boardConnection({snapshot, trip, stop: fromStop, departureS, leg})
  const alight = alightConnection({snapshot, trip, stop: toStop, arrivalS, leg})
  return {kind: LegKind.ride, boardConnection: board, alightConnection: alight}
}

// `walk FROM TO SECONDS`.
function walkOf({snapshot, parts, leg}) {
  assertCondition(parts.length === WALK_PART_COUNT, "routing engine cases: a walk of " + parts.length + " parts: " + leg)
  const [, fromId, toId, durationText] = parts
  const fromStop = stopOf({snapshot, stopId: fromId})
  const toStop = stopOf({snapshot, stopId: toId})
  return {kind: LegKind.walk, fromStop, toStop, durationS: wholeSeconds(durationText)}
}

// `walkFromPosition TO SECONDS`.
function positionWalkOf({snapshot, parts, leg}) {
  assertCondition(parts.length === POSITION_WALK_PART_COUNT, "routing engine cases: a walk from the position of " + parts.length + " parts: " + leg)
  const [, toId, durationText] = parts
  const toStop = stopOf({snapshot, stopId: toId})
  return {kind: LegKind.walkFromPosition, toStop, durationS: wholeSeconds(durationText)}
}

function legOf({snapshot, leg}) {
  const parts = leg.split(" ")
  const [kind] = parts

  switch (kind) {
    case LegKind.ride:
      return rideOf({snapshot, parts, leg})
    case LegKind.walk:
      return walkOf({snapshot, parts, leg})
    case LegKind.walkFromPosition:
      return positionWalkOf({snapshot, parts, leg})
    default:
      return unreachable(kind, "routing engine cases: a leg of unknown kind")
  }
}

function legsOf({snapshot, journey}) {
  const legs = []

  for (const leg of journey.legs) {
    legs.push(legOf({snapshot, leg}))
  }

  return legs
}

function leavingJourneys({snapshot, query}) {
  const frontier = []

  for (const journey of query.expected) {
    const legs = legsOf({snapshot, journey})
    frontier.push({arrivalS: seconds(journey.arrive), changes: journey.changes, legs})
  }

  return frontier
}

function arrivingByJourneys({snapshot, query}) {
  const frontier = []

  for (const journey of query.expected) {
    const legs = legsOf({snapshot, journey})
    frontier.push({departureS: seconds(journey.depart), arrivalS: seconds(journey.arrive), changes: journey.changes, legs})
  }

  return frontier
}

function startOf({snapshot, start}) {
  const [stopId, walkS] = start
  assertCondition(Number.isInteger(walkS), "routing engine cases: a start's walk of " + walkS + " seconds")
  return {stop: stopOf({snapshot, stopId}), walkS}
}

// A query names one origin stop with `from`, or start stops with `starts`.
function originOf({snapshot, query}) {
  if (query.starts === undefined) {
    return {kind: OriginKind.stop, stop: stopOf({snapshot, stopId: query.from})}
  }

  assertCondition(query.from === undefined, "routing engine cases: a query names both an origin stop and start stops")
  const starts = []

  for (const start of query.starts) {
    starts.push(startOf({snapshot, start}))
  }

  return {kind: OriginKind.starts, starts}
}

function originName(query) {
  if (query.starts === undefined) {
    return query.from
  }

  return "a position"
}

function engineQuery({snapshot, query}) {
  const origin = originOf({snapshot, query})
  const target = stopOf({snapshot, stopId: query.to})
  const route = originName(query) + " to " + query.to

  if (query.arriveBy === undefined) {
    const expected = leavingJourneys({snapshot, query})
    const routed = {origin, target, departureS: seconds(query.depart)}
    return {name: route + " leaving at " + query.depart, kind: QueryKind.leaving, query: routed, expected}
  }

  assertCondition(query.depart === undefined, "routing engine cases: a query both leaves at and arrives by a time")
  const expected = arrivingByJourneys({snapshot, query})
  const routed = {origin, target, arrivalS: seconds(query.arriveBy)}
  return {name: route + " arriving by " + query.arriveBy, kind: QueryKind.arrivingBy, query: routed, expected}
}
