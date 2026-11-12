// What a stop's details view says of the chosen journey, as pure functions:
// whether the journey boards, gets off, or does neither at the stop, the
// line's text, and which arrival row is the first ride's bus. The row is
// found as the journey cards find their first bus. Nothing here reads the
// document, the network, storage, or a clock.

import {assertCondition} from "./core/assert.js"
import {LegKind} from "./core/routing_engine.js"
import {isRideRun, liveShiftMs} from "./journey_cards.js"
import {clockText} from "./core/trip_plan.js"

/** What a journey does at a stop. */
export const StopMarkKind = Object.freeze({none: "none", boardsFirst: "boardsFirst", boards: "boards", getsOff: "getsOff"})

/** Whether an arrival list holds the first ride's bus. */
export const YourBusKind = Object.freeze({row: "row", absent: "absent"})

const SECOND_MS = 1000
const SEPARATOR = " · "
const BOARDS_TEXT = "Your trip boards here"
const GETS_OFF_TEXT = "Your trip gets off here"
const ARRIVALS_STATUS = "arrivals"
const FIRST_RIDE_INDEX = 0

/** The answer for a list that marks no bus. */
export const NO_YOUR_BUS = Object.freeze({kind: YourBusKind.absent})

function rideLegs(journey) {
  const rides = []

  for (const leg of journey.legs) {
    if (leg.kind === LegKind.ride) {
      rides.push(leg)
    }
  }

  return rides
}

// How far the bus of the ride at `rideIndex` is from its schedule, in
// milliseconds: the first bus's lateness where it is live, and none for any
// other ride, whose bus is not the one the page sees.
function shiftMsOf({live, rideIndex}) {
  if (rideIndex === FIRST_RIDE_INDEX) {
    return liveShiftMs(live)
  }

  return 0
}

/**
 * What `chosen`, the journey the rider chose with `live`, the first bus's
 * `firstRideLive` answer, its `leadText`, `arriveText`,
 * `serviceDayStartsMs`, and `timeZone`, does at the stop `stopId`: a
 * StopMarkKind member with the `text` of the line. A boarding wins over a
 * getting off at a stop where one ride ends and the next begins, and the
 * first ride's boarding also names its `tripId` and scheduled
 * `departureMs`. The time the first ride gets off moves by its bus's
 * lateness, as the trip strip moves the times it writes. A stop a ride only
 * passes, a stop only walked to, and a stop the journey does not use are
 * none.
 */
export function stopMark({chosen, stopId}) {
  const {journey, live, leadText, arriveText, serviceDayStartsMs, timeZone} = chosen
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "journey stop marks: no start for the service date " + journey.serviceDate)
  const rides = rideLegs(journey)

  for (const [index, leg] of rides.entries()) {
    if (leg.fromStopId !== stopId) {
      continue
    }

    const departureMs = startMs + leg.departureS * SECOND_MS

    if (index === FIRST_RIDE_INDEX) {
      const text = [BOARDS_TEXT, leadText, arriveText].join(SEPARATOR)
      return {kind: StopMarkKind.boardsFirst, text, tripId: leg.tripId, departureMs}
    }

    return {kind: StopMarkKind.boards, text: BOARDS_TEXT + SEPARATOR + clockText({ms: departureMs, timeZone})}
  }

  for (const [index, leg] of rides.entries()) {
    if (leg.toStopId !== stopId) {
      continue
    }

    const arrivalMs = startMs + leg.arrivalS * SECOND_MS + shiftMsOf({live, rideIndex: index})
    return {kind: StopMarkKind.getsOff, text: GETS_OFF_TEXT + SEPARATOR + clockText({ms: arrivalMs, timeZone})}
  }

  return {kind: StopMarkKind.none}
}

/**
 * Which row of `shown`, a stop's arrivals as the page shows them, is the
 * first ride's bus at the stop `mark` is the mark of: a YourBusKind
 * member, the row with its `index` where an arrival is of the ride's trip
 * near its scheduled departure, and absent where the mark names no bus or
 * no arrival matches.
 */
export function yourBusRow({mark, shown}) {
  const isBoardingFirst = mark.kind === StopMarkKind.boardsFirst
  const hasArrivals = shown.status === ARRIVALS_STATUS

  const isMatchable = isBoardingFirst && hasArrivals

  if (isMatchable) {
    const {tripId, departureMs} = mark

    for (const [index, arrival] of shown.arrivals.entries()) {
      if (isRideRun({arrival, tripId, departureMs})) {
        return {kind: YourBusKind.row, index}
      }
    }
  }

  return {kind: YourBusKind.absent}
}
