// What a vehicle's details view says of the chosen journey, as a pure
// function of the chosen journey and the vehicle's trip and service date:
// the line that names the vehicle as the journey's first bus, with the stop
// it is boarded at and when. The vehicle is found as the map's "Your bus"
// label finds it. Nothing here reads the document, the network, storage, or
// a clock.

import {ChosenKind} from "./chosen_journey.js"
import {BoardingKind, firstRideBoarding} from "./journey_labels.js"
import {clockText, stopName} from "./trip_plan.js"

/** Whether a vehicle's view carries the line. */
export const YourBusLineKind = Object.freeze({line: "line", none: "none"})

const SEPARATOR = " · "

/**
 * The line of the vehicle of the trip `tripId` on the service day starting
 * at `serviceDateMs` under `chosen`: `{kind: YourBusLineKind.line, text}`
 * where it is the first bus, "Your bus · Board at <stop> · <time>", the
 * time moved by the bus's lateness as the strip's times are, and
 * `{kind: YourBusLineKind.none}` for any other vehicle and while no
 * journey is chosen.
 */
export function vehicleYourBusLine({chosen, tripId, serviceDateMs}) {
  if (chosen.kind === ChosenKind.none) {
    return {kind: YourBusLineKind.none}
  }

  const boarding = firstRideBoarding({chosen})

  if (boarding.kind === BoardingKind.none) {
    return {kind: YourBusLineKind.none}
  }

  const isTrip = boarding.tripId === tripId
  const isServiceDate = boarding.serviceDateMs === serviceDateMs
  const isFirstBus = isTrip && isServiceDate

  if (!isFirstBus) {
    return {kind: YourBusLineKind.none}
  }

  const stop = stopName({names: chosen.names, stopId: boarding.stopId})
  const time = clockText({ms: boarding.boardMs, timeZone: chosen.timeZone})
  return {kind: YourBusLineKind.line, text: ["Your bus", `Board at ${stop}`, time].join(SEPARATOR)}
}
