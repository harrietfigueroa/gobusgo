// The rows of the Trip tab's timeline of a chosen journey, as pure
// functions: where it leaves from, each walk with its minutes and meters,
// each boarding with its time, stop, and code, each ride with its route,
// headsign, live lateness, and the stops it passes, each change, and the
// arrival. Each row carries the sentence a screen reader reads, in the
// order the rider takes the steps. Nothing here reads the document, the
// network, storage, or a clock.

import {assertCondition, unreachable} from "./core/assert.js"
import {LegKind} from "./core/routing_engine.js"
import {LEG_KIND_TO_POINT} from "./core/point_journeys.js"
import {LiveKind} from "./journey_cards.js"
import {clockText, journeyLeaveS, routeChip, stopName, walkMinutes} from "./core/trip_plan.js"

/** The kinds of a timeline row. */
export const TimelineRowKind = Object.freeze({
  origin: "origin",
  walk: "walk",
  board: "board",
  ride: "ride",
  alight: "alight",
  arrive: "arrive",
})

const SECOND_MS = 1000
const MINUTE_S = 60
const METERS_ROUNDING = 10
const ONE_STOP = 1

/**
 * The headsign of each trip of a snapshot, keyed by its identifier and its
 * service day offset, from `trips`, the decoded trips file, and
 * `tripHeadsigns`, its names file's headsigns by trip index. A trip with
 * no headsign is left out.
 */
export function headsignsByTrip({trips, tripHeadsigns}) {
  assertCondition(tripHeadsigns.length === trips.length, `journey timeline: ${tripHeadsigns.length} headsigns for ${trips.length} trips`)
  const headsigns = new Map()

  for (const [index, trip] of trips.entries()) {
    const headsign = tripHeadsigns[index]

    if (typeof headsign === "string") {
      headsigns.set(tripKey({tripId: trip.id, serviceDayOffset: trip.serviceDayOffset}), headsign)
    }
  }

  return headsigns
}

function tripKey({tripId, serviceDayOffset}) {
  return `${tripId}:${serviceDayOffset}`
}

// A ride's headsign, or the empty text for a trip with none.
function headsignOf({headsigns, leg}) {
  const key = tripKey({tripId: leg.tripId, serviceDayOffset: leg.serviceDayOffset})

  if (headsigns.has(key)) {
    return headsigns.get(key)
  }

  return ""
}

function stopCode({names, stopId}) {
  const named = names.stops[stopId]
  const isCoded = named !== undefined && typeof named.code === "string"

  if (isCoded) {
    return named.code
  }

  return ""
}

function lateText(latenessS) {
  const minutes = Math.round(latenessS / MINUTE_S)

  if (minutes === 0) {
    return "on time"
  } else if (minutes > 0) {
    return `${minutes} min late`
  }

  return `${-minutes} min early`
}

function stopCountText(count) {
  if (count === ONE_STOP) {
    return "1 stop"
  }

  return `${count} stops`
}

function walkRow({leg, toName, walkSpeedMPerS}) {
  const minutes = walkMinutes(leg.durationS)
  const meters = Math.round(leg.durationS * walkSpeedMPerS / METERS_ROUNDING) * METERS_ROUNDING
  return {kind: TimelineRowKind.walk, text: `Walk ${minutes} min, ${meters} m`, sentence: `walk ${minutes} min, ${meters} m, to ${toName}`}
}

function boardRow({leg, chip, headsign, names, timeText}) {
  const name = stopName({names, stopId: leg.fromStopId})
  const code = stopCode({names, stopId: leg.fromStopId})
  let detail = ""
  let sentence = `${timeText} board ${chip.name}`

  if (headsign !== "") {
    sentence += ` to ${headsign}`
  }

  sentence += ` at ${name}`

  if (code !== "") {
    detail = `Stop #${code}`
    sentence += `, stop ${code}`
  }

  return {kind: TimelineRowKind.board, timeText, name, detail, color: chip.color, sentence}
}

function rideRow({leg, legIndex, chip, headsign, late, names}) {
  const count = leg.stopIds.length - 1
  const passed = leg.stopIds.slice(1, count)
  const passedStops = Array.from(passed, (stopId) => stopName({names, stopId}))
  let sentence = `ride ${stopCountText(count)}`

  if (late !== "") {
    sentence += `, ${late}`
  }

  return {kind: TimelineRowKind.ride, legIndex, chip, headsign, lateText: late, stopCountText: `Ride ${stopCountText(count)}`, passedStops, sentence}
}

function alightRow({leg, chip, isChange, names, timeText}) {
  const name = stopName({names, stopId: leg.toStopId})
  let detail = "Get off"
  let sentence = `${timeText} get off at ${name}`

  if (isChange) {
    detail = "Get off · change"
    sentence += " and change"
  }

  return {kind: TimelineRowKind.alight, timeText, name, detail, color: chip.color, sentence}
}

function arriveRow({name, timeText}) {
  return {kind: TimelineRowKind.arrive, timeText, name, sentence: `${timeText} arrive at ${name}`}
}

function rideIndexes(journey) {
  const indexes = []

  for (const [index, leg] of journey.legs.entries()) {
    if (leg.kind === LegKind.ride) {
      indexes.push(index)
    }
  }

  return indexes
}

// Where a journey leaves from before its first ride: the rider's start,
// `originName`, for a walk from a position, the stop a first walk leaves
// from, or none for a journey that boards at once.
function originRows({journey, names, originName, timeText}) {
  const [first] = journey.legs

  switch (first.kind) {
    case LegKind.walkFromPosition:
      return [{kind: TimelineRowKind.origin, timeText, name: originName, sentence: `${timeText} leave ${originName}`}]
    case LegKind.walk: {
      const name = stopName({names, stopId: first.fromStopId})
      return [{kind: TimelineRowKind.origin, timeText, name, sentence: `${timeText} leave ${name}`}]
    }
    default:
      return []
  }
}

// The name of where a journey ends.
function destinationName({journey, names}) {
  if (journey.destination !== undefined) {
    return journey.destination.name
  }

  const last = journey.legs[journey.legs.length - 1]
  return stopName({names, stopId: last.toStopId})
}

/**
 * The rows of the timeline of `journey`, in the order taken: the place it
 * leaves from, `originName` for a start from a position, then per leg a
 * walk row, or a ride's boarding, ride, and getting off, and the arrival,
 * each a TimelineRowKind member with its `sentence`. Times read on the
 * clock of `timeZone` from `serviceDayStartsMs`; the stops' names, codes,
 * and the routes' chips from `names`; headsigns from `headsigns`, as
 * `headsignsByTrip` keys them; a walk's meters at `walkSpeedMPerS`; and the
 * first ride's live lateness from `live`, a `firstRideLive` answer.
 */
export function timelineRows({journey, names, headsigns, live, originName, serviceDayStartsMs, timeZone, walkSpeedMPerS}) {
  assertCondition(walkSpeedMPerS > 0, "journey timeline: the walking speed is not positive: " + walkSpeedMPerS)
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "journey timeline: no start for the service date " + journey.serviceDate)

  function timeOf(seconds) {
    return clockText({ms: startMs + seconds * SECOND_MS, timeZone})
  }

  const rides = rideIndexes(journey)
  const lastIndex = journey.legs.length - 1
  const rows = originRows({journey, names, originName, timeText: timeOf(journeyLeaveS(journey))})

  for (const [legIndex, leg] of journey.legs.entries()) {
    switch (leg.kind) {
      case LegKind.walk:
      case LegKind.walkFromPosition:
        rows.push(walkRow({leg, toName: stopName({names, stopId: leg.toStopId}), walkSpeedMPerS}))
        break
      case LEG_KIND_TO_POINT:
        rows.push(walkRow({leg, toName: journey.destination.name, walkSpeedMPerS}))
        break
      case LegKind.ride: {
        const chip = routeChip({names, routeId: leg.routeId})
        const headsign = headsignOf({headsigns, leg})
        const isFirstRide = legIndex === rides[0]
        const isLiveRide = isFirstRide && live.kind === LiveKind.live
        let late = ""

        if (isLiveRide) {
          late = lateText(live.latenessS)
        }

        rows.push(boardRow({leg, chip, headsign, names, timeText: timeOf(leg.departureS)}))
        rows.push(rideRow({leg, legIndex, chip, headsign, late, names}))

        if (legIndex < lastIndex) {
          const isChange = rides.some((index) => index > legIndex)
          rows.push(alightRow({leg, chip, isChange, names, timeText: timeOf(leg.arrivalS)}))
        }

        break
      }
      default:
        unreachable(leg.kind, "journey timeline: a leg of unknown kind")
    }
  }

  rows.push(arriveRow({name: destinationName({journey, names}), timeText: timeOf(journey.arrivalS)}))
  return rows
}
