// What the map labels of the chosen journey say and where they stand, as
// pure functions of the chosen journey: where it leaves from and when, the
// minutes of each walk, each boarding with its route, time, and the first
// bus's lateness, each getting off, the arrival, and the first bus's label
// with the minutes it is away. The times are the ones the journey card
// writes, so the first bus's lateness moves them as it moves the card's.
// Nothing here reads the document, the network, storage, or a clock: the
// time the minutes are counted at arrives with the chosen journey.

import {assertCondition, unreachable} from "./assert.js"
import {LegKind} from "./routing_engine.js"
import {LEG_KIND_TO_POINT} from "./point_journeys.js"
import {LiveKind, latenessMinutes, liveShiftMs} from "./journey_cards.js"
import {clockText, journeyLeaveS, legCoordinates, routeChip, walkMinutes} from "./trip_plan.js"

/** The kinds of a label of the journey. */
export const LabelKind = Object.freeze({leave: "leave", walk: "walk", board: "board", alight: "alight", arrive: "arrive"})

/** Whether the journey has a first bus to label. */
export const YourBusLabelKind = Object.freeze({label: "label", none: "none"})

const SECOND_MS = 1000
const MINUTE_MS = 60 * SECOND_MS
const SEPARATOR = " · "
const ON_TIME_TEXT = "on time"
const DUE_TEXT = "due"
const FIRST_AND_LAST_COUNT_MIN = 2
const HALVING_DIVISOR = 2

function label({kind, text, coordinate}) {
  return {kind, text, coordinate}
}

// The first bus's lateness as a label writes it: "+2" late, "-3" early.
function latenessSuffix(latenessS) {
  const minutes = latenessMinutes(latenessS)

  if (minutes === 0) {
    return ON_TIME_TEXT
  } else if (minutes > 0) {
    return `+${minutes}`
  }

  return `${minutes}`
}

// The label standing on the stop `stopId`, or none where the journey does
// not know its position.
function stopLabels({journey, stopId, kind, text}) {
  const position = journey.stopPositions[stopId]

  if (position === undefined) {
    return []
  }

  return [label({kind, text, coordinate: [position.lon, position.lat]})]
}

// A walk's label stands midway between the ends of its line.
function walkLabels({coordinates, leg}) {
  if (coordinates.length < FIRST_AND_LAST_COUNT_MIN) {
    return []
  }

  const first = coordinates[0]
  const last = coordinates[coordinates.length - 1]
  const coordinate = [(first[0] + last[0]) / HALVING_DIVISOR, (first[1] + last[1]) / HALVING_DIVISOR]
  return [label({kind: LabelKind.walk, text: `${walkMinutes(leg.durationS)} min`, coordinate})]
}

function boardText({leg, names, timeText, isFirstLive, live}) {
  let text = `${routeChip({names, routeId: leg.routeId}).name} ${timeText}`

  if (isFirstLive) {
    text += ` ${latenessSuffix(live.latenessS)}`
  }

  return text
}

/**
 * The labels of the journey `chosen` holds, in the order taken, each
 * `{kind, text, coordinate}` with a LabelKind member and a `[lon, lat]`:
 * where it leaves from and when, a walk's minutes midway along its line, a
 * ride's route, time, and, on the first ride when its bus is live, its
 * lateness, at the boarding stop, "Get off" and the time at the stop of a
 * ride another leg follows, as the timeline has it, and the arrival at the
 * last point. The leave time, the first ride's times, and the arrival move
 * by the first bus's lateness, as the card's do; a later ride's stay
 * scheduled. A label whose position the journey does not know is left out.
 */
export function journeyLabels({chosen}) {
  const {journey, live, serviceDayStartsMs, timeZone, names, origin} = chosen
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "journey labels: no start for the service date " + journey.serviceDate)
  const shiftMs = liveShiftMs(live)
  const originCoordinates = []

  if (origin !== null) {
    originCoordinates.push([origin.lon, origin.lat])
  }

  const legCoordinatesByIndex = []
  const points = []

  for (const leg of journey.legs) {
    const coordinates = legCoordinates({journey, leg, origin: originCoordinates})
    legCoordinatesByIndex.push(coordinates)

    for (const coordinate of coordinates) {
      points.push(coordinate)
    }
  }

  function timeOf(seconds) {
    return clockText({ms: startMs + seconds * SECOND_MS, timeZone})
  }

  function shiftedTimeOf(seconds) {
    return clockText({ms: startMs + seconds * SECOND_MS + shiftMs, timeZone})
  }

  const labels = []
  const isPlaced = points.length > 0

  if (isPlaced) {
    labels.push(label({kind: LabelKind.leave, text: `Leave ${shiftedTimeOf(journeyLeaveS(journey))}`, coordinate: points[0]}))
  }

  const lastIndex = journey.legs.length - 1
  let isFirstRide = true

  for (const [index, leg] of journey.legs.entries()) {
    switch (leg.kind) {
      case LegKind.ride: {
        let departedText = timeOf(leg.departureS)
        let arrivedText = timeOf(leg.arrivalS)

        if (isFirstRide) {
          departedText = shiftedTimeOf(leg.departureS)
          arrivedText = shiftedTimeOf(leg.arrivalS)
        }

        const isFirstLive = isFirstRide && live.kind === LiveKind.live
        const text = boardText({leg, names, timeText: departedText, isFirstLive, live})

        for (const placed of stopLabels({journey, stopId: leg.fromStopId, kind: LabelKind.board, text})) {
          labels.push(placed)
        }

        if (index < lastIndex) {
          for (const placed of stopLabels({journey, stopId: leg.toStopId, kind: LabelKind.alight, text: `Get off ${arrivedText}`})) {
            labels.push(placed)
          }
        }

        isFirstRide = false
        break
      }
      case LegKind.walk:
      case LegKind.walkFromPosition:
      case LEG_KIND_TO_POINT:
        for (const placed of walkLabels({coordinates: legCoordinatesByIndex[index], leg})) {
          labels.push(placed)
        }

        break
      default:
        unreachable(leg.kind, "journey labels: a leg of unknown kind")
    }
  }

  if (isPlaced) {
    const arrivalText = shiftedTimeOf(journey.arrivalS)
    labels.push(label({kind: LabelKind.arrive, text: `Arrive ${arrivalText}`, coordinate: points[points.length - 1]}))
  }

  return labels
}

/**
 * The label of the first bus: `{kind: YourBusLabelKind.label, tripId,
 * serviceDateMs, text}` where the journey has a ride, the vehicle of the
 * trip `tripId` on the service day starting at `serviceDateMs` being the
 * one it labels, and `{kind: YourBusLabelKind.none}` for a journey that
 * only walks and for a bus past its boarding stop. The text counts whole
 * minutes from `chosen.nowMs` to the first ride's scheduled departure moved
 * by the first bus's lateness, which is the time the bus reaches the
 * boarding stop; under a minute reads as due.
 */
export function yourBusLabel({chosen}) {
  const {journey, live, serviceDayStartsMs, nowMs} = chosen
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "journey labels: no start for the service date " + journey.serviceDate)

  for (const leg of journey.legs) {
    if (leg.kind !== LegKind.ride) {
      continue
    }

    const boardMs = startMs + leg.departureS * SECOND_MS + liveShiftMs(live)
    const awayMs = boardMs - nowMs

    if (awayMs < 0) {
      return {kind: YourBusLabelKind.none}
    }

    const minutes = Math.floor(awayMs / MINUTE_MS)
    let awayText = DUE_TEXT

    if (minutes > 0) {
      awayText = `${minutes} min away`
    }

    return {kind: YourBusLabelKind.label, tripId: leg.tripId, serviceDateMs: startMs, text: "Your bus" + SEPARATOR + awayText}
  }

  return {kind: YourBusLabelKind.none}
}
