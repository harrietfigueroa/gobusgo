// Plans the trip the trip planner app's two resolved ends make, in the
// browser: the manifest, the time, the router's journeys, and the names of
// their stops and routes, all from files fetched from `origin`. No request
// names a place or the rider's position; a fetch names only a file.

import {assertCondition, unreachable} from "./core/assert.js"
import {FromKind, JourneysKind} from "./core/routing_journeys.js"
import {AnswerKind, answerOutcome, fetchManifest, routeTo, serviceDayStartsOf} from "./trip_route.js"
import {EndKind, PlannedKind, StateKind, failureState, plannedTime} from "./core/trip_plan.js"

const MANIFEST_PATH = "/api/routing/manifest"

/** The kinds of what planning a trip gives. */
export const PlanKind = Object.freeze({journeys: "journeys", state: "state"})

// The router's start for `from`: a stop, a point, or the rider's position.
function startOf({from, position}) {
  switch (from.kind) {
    case EndKind.stop:
      return {kind: FromKind.stop, stopId: from.stopId}
    case EndKind.point:
      return {kind: FromKind.position, lat: from.lat, lon: from.lon}
    case EndKind.location:
      assertCondition(position !== null, "mcp trip plan: a start at the rider's location has no position")
      return {kind: FromKind.position, lat: position.lat, lon: position.lon}
    default:
      return unreachable(from.kind, "mcp trip plan: a start of unknown kind")
  }
}

// The names of the stops and routes of `journeys`, from the names file of
// each service date they are routed in; a date whose names are not read is
// left to show identifiers.
async function namesOf({files, manifest, journeys}) {
  const dates = new Set()

  for (const journey of journeys) {
    dates.add(journey.serviceDate)
  }

  const entries = manifest.snapshots.filter((entry) => dates.has(entry.serviceDate))
  const pending = Array.from(entries, (entry) => files.journeyNames({entry}))
  const settled = await Promise.allSettled(pending)
  let stops = {}
  let routes = {}

  for (const outcome of settled) {
    if (outcome.status === "fulfilled") {
      stops = {...stops, ...outcome.value.stops}
      routes = {...routes, ...outcome.value.routes}
    } else {
      console.warn("Journey names not read", outcome.reason)
    }
  }

  return {stops, routes}
}

/**
 * Plans the trip from `from` to `to`, the planner's ends, a stop or a point
 * each, for `when`, `{mode, day, clockText}`, at `nowMs` on the clock of
 * `timeZone`. `position` is the rider's `{lat, lon}`, which a `from` of the
 * rider's location needs. `files` is the app's search files, which read the
 * stops of a point end and the names. A PlanKind member: journeys with
 * `journeys`, `planned`, `serviceDayStartsMs`, and `names`, or the `state`,
 * a StateKind member, that says why there are none, and whether trying
 * again can help in `isRetry`.
 */
export async function planTrip({origin, files, from, to, when, position, nowMs, timeZone}) {
  const manifestOutcome = await fetchManifest({origin, path: MANIFEST_PATH})

  if (manifestOutcome.kind === JourneysKind.failed) {
    return {kind: PlanKind.state, state: failureState(manifestOutcome), isRetry: true}
  }

  const {manifest} = manifestOutcome
  const planned = plannedTime({when, nowMs, timeZone, manifest})

  if (planned.kind === PlannedKind.refused) {
    return {kind: PlanKind.state, state: planned.state, isRetry: planned.state === StateKind.noServiceDate}
  }

  const answer = await routeTo({origin, searchFiles: files, manifest, planned, from: startOf({from, position}), to})
  const outcome = answerOutcome({answer, planned})

  if (outcome.kind === AnswerKind.state) {
    return {kind: PlanKind.state, state: outcome.state, isRetry: outcome.isRetry}
  }

  const names = await namesOf({files, manifest, journeys: outcome.journeys})
  return {kind: PlanKind.journeys, journeys: outcome.journeys, planned, serviceDayStartsMs: serviceDayStartsOf(manifest), names}
}
