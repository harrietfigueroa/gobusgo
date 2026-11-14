// The core's trip plan rules, deliberately changed: every walk reads a
// minute longer than the core's own walkMinutes gives.
import {walkMinutes as walkMinutesUnchanged} from "../../../assets/js/core/trip_plan.js"

export * from "../../../assets/js/core/trip_plan.js"

export function walkMinutes(durationS) {
  return walkMinutesUnchanged(durationS) + 1
}
