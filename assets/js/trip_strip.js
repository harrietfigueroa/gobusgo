// What the trip strip says of the chosen journey, as pure functions: when to
// leave and the arrival as the journey's card writes them, the first bus's
// status, the bar, the first step, the next two steps, and the sentence the
// strip is named by. The strip reads what the card and the journey already
// hold, so it asks for nothing and reads the same offline. Nothing here
// reads the document, the network, storage, or a clock.

import {assertCondition, unreachable} from "./core/assert.js"
import {LegKind} from "./core/routing_engine.js"
import {LEG_KIND_TO_POINT} from "./core/point_journeys.js"
import {LiveKind, firstBusText, latenessText, liveShiftMs} from "./journey_cards.js"
import {clockText, routeChip, stopName, walkMinutes} from "./core/trip_plan.js"

/** How many steps after the first the strip lists where it has room. */
export const NEXT_STEP_COUNT_MAX = 2

const SECOND_MS = 1000
const ARRIVE_PREFIX = "arrive "

// The name of where a journey ends: the point a journey to a point walks
// to, or else the stop it ends at.
function destinationName({journey, names}) {
  if (journey.destination !== undefined) {
    return journey.destination.name
  }

  const last = journey.legs[journey.legs.length - 1]
  return stopName({names, stopId: last.toStopId})
}

function walkStep({leg, journey, names, isFirst}) {
  let toName = destinationName({journey, names})

  if (leg.kind !== LEG_KIND_TO_POINT) {
    toName = stopName({names, stopId: leg.toStopId})
  }

  if (isFirst) {
    return `Walk to ${toName}`
  }

  return `Walk ${walkMinutes(leg.durationS)} min to ${toName}`
}

// A boarding: the first step names the stop alone; a later one adds the
// time, moved by the first ride's lateness where the bus is live.
function boardStep({leg, index, isFirstRide, live, names, startMs, timeZone}) {
  const name = routeChip({names, routeId: leg.routeId}).name
  const stopText = stopName({names, stopId: leg.fromStopId})

  if (index === 0) {
    return `Board ${name} at ${stopText}`
  }

  let shiftMs = 0
  let lateText = ""
  const isLive = isFirstRide && live.kind === LiveKind.live

  if (isLive) {
    shiftMs = liveShiftMs(live)
    lateText = `, ${latenessText(live.latenessS)}`
  }

  const timeText = clockText({ms: startMs + leg.departureS * SECOND_MS + shiftMs, timeZone})
  return `Board ${name} at ${stopText}, ${timeText}${lateText}`
}

// The steps of a journey in the order taken: a walk, a boarding, a getting
// off before each change, and the arrival.
function stepTexts({journey, live, names, serviceDayStartsMs, timeZone}) {
  const startMs = serviceDayStartsMs[journey.serviceDate]
  assertCondition(Number.isInteger(startMs), "trip strip: no start for the service date " + journey.serviceDate)
  const steps = []
  const lastIndex = journey.legs.length - 1
  let isFirstRide = true

  for (const [index, leg] of journey.legs.entries()) {
    switch (leg.kind) {
      case LegKind.ride:
        steps.push(boardStep({leg, index, isFirstRide, live, names, startMs, timeZone}))
        isFirstRide = false

        if (index < lastIndex) {
          steps.push(`Get off at ${stopName({names, stopId: leg.toStopId})}`)
        }

        break
      case LegKind.walk:
      case LegKind.walkFromPosition:
      case LEG_KIND_TO_POINT:
        steps.push(walkStep({leg, journey, names, isFirst: index === 0}))
        break
      default:
        unreachable(leg.kind, "trip strip: a leg of unknown kind")
    }
  }

  steps.push(`Arrive at ${destinationName({journey, names})}`)
  return steps
}

/**
 * The strip of the journey `card` is the card of, whose first bus `live` is
 * from `firstRideLive`: `leadText`, "Leave in 4 min"; `arriveText`,
 * "Arrive 6:42 pm"; `statusText`, the first bus's; `isLive`; `segments`,
 * the card's bar; `firstStepText`; `nextStepTexts`, at most
 * NEXT_STEP_COUNT_MAX steps after the first; and `sentence`, which names
 * the strip to assistive technology.
 */
export function tripStrip({card, live, names, serviceDayStartsMs, timeZone}) {
  assertCondition(card.arriveText.startsWith(ARRIVE_PREFIX), "trip strip: a card's arrival does not lead with arrive: " + card.arriveText)
  const arriveText = "A" + card.arriveText.slice(1)
  const statusText = firstBusText({live, names})
  const steps = stepTexts({journey: card.row.journey, live, names, serviceDayStartsMs, timeZone})
  const [firstStepText, ...rest] = steps
  const nextStepTexts = rest.slice(0, NEXT_STEP_COUNT_MAX)

  return {
    leadText: card.leadText,
    arriveText,
    statusText,
    isLive: card.isLive,
    segments: card.segments,
    firstStepText,
    nextStepTexts,
    sentence: `Trip: ${card.leadText}, ${arriveText}. ${statusText}. ${firstStepText}.`,
  }
}
