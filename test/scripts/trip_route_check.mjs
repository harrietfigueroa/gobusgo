// Checks the parts of the trip router's shell that need no snapshot: the
// manifest's fetch, which puts the origin in front of its path and answers
// each failure as a value, what each of the router's answers says to the
// rider, and the two tables read from a manifest. A stand-in for `fetch`
// keeps every request on the machine. Run it with `node
// test/scripts/trip_route_check.mjs`; it exits non-zero on the first case that
// differs.

import {deepStrictEqual} from "node:assert/strict"
import {FetchKind, FailureReason, JourneysKind} from "../../assets/js/core/routing_journeys.js"
import {PointJourneysKind} from "../../assets/js/core/point_journeys.js"
import {NOT_SAVED_HEADER} from "../../assets/js/core/offline_bundle.js"
import {PlannedKind, StateKind} from "../../assets/js/core/trip_plan.js"
import {AnswerKind, answerOutcome, fetchManifest, serviceDayStartsOf, walkSpeedsOf} from "../../assets/js/trip_route.js"

const PATH = "/api/routing/manifest"
const ORIGIN = "https://gobusgo.example"
const manifest = {
  formatVersion: 2,
  snapshots: [
    {serviceDate: "2026-11-08", serviceDayStartMs: 1000, transferRules: {walkSpeedMPerS: 1.2}},
    {serviceDate: "2026-11-09", serviceDayStartMs: 2000, transferRules: {walkSpeedMPerS: 1.4}},
  ],
}

const requests = []

function stubFetch(response) {
  globalThis.fetch = async (address, options) => {
    requests.push({address, options})

    if (response instanceof Error) {
      throw response
    }

    return response
  }
}

// The outcome of fetching the manifest over a stand-in that answers `response`; the warning a network fault logs is muted.
async function manifestOutcomeOf({response, origin}) {
  const warn = console.warn
  console.warn = noWarning
  stubFetch(response)
  const outcome = await fetchManifest({origin, path: PATH})
  console.warn = warn
  return outcome
}

function noWarning() {
  console.log("trip_route_check: a warning was muted")
}

function jsonResponse(body, init) {
  return new Response(JSON.stringify(body), {headers: {"content-type": "application/json"}, ...init})
}

// The manifest is fetched from the origin, revalidated, and read as JSON.
const fetched = await manifestOutcomeOf({response: jsonResponse(manifest), origin: ORIGIN})
deepStrictEqual(fetched, {kind: FetchKind.fetched, manifest}, "a manifest")
deepStrictEqual(requests[0].address, ORIGIN + PATH, "the manifest's address holds the origin")
deepStrictEqual(requests[0].options.cache, "no-cache", "the manifest is revalidated")
deepStrictEqual(requests[0].options.headers, {accept: "application/json"}, "the manifest is asked for as JSON")

// With no origin the path is the page's own.
await manifestOutcomeOf({response: jsonResponse(manifest), origin: ""})
deepStrictEqual(requests[1].address, PATH, "a page's own path")

// Each failure is a value that names the manifest.
const failures = [
  {name: "an unavailable manifest", response: new Response("", {status: 503}), reason: FailureReason.fetchFailed},
  {name: "a manifest the worker did not save", response: new Response("", {status: 503, headers: {[NOT_SAVED_HEADER.name]: NOT_SAVED_HEADER.value}}), reason: FailureReason.notSaved},
  {name: "a body with no snapshot list", response: jsonResponse({snapshots: "none"}), reason: FailureReason.refused},
  {name: "a body that is null", response: jsonResponse(null), reason: FailureReason.refused},
  {name: "a network fault", response: new TypeError("Failed to fetch"), reason: FailureReason.fetchFailed},
]

for (const {name, response, reason} of failures) {
  const outcome = await manifestOutcomeOf({response, origin: ORIGIN})
  deepStrictEqual(outcome, {kind: JourneysKind.failed, reason, path: PATH}, name)
}

// The tables read from the manifest.
deepStrictEqual(serviceDayStartsOf(manifest), {"2026-11-08": 1000, "2026-11-09": 2000}, "the days' starts")
deepStrictEqual(walkSpeedsOf(manifest), {"2026-11-08": 1.2, "2026-11-09": 1.4}, "the walking speeds")

// What each answer says.
const leaving = {kind: PlannedKind.leaving}
const arriving = {kind: PlannedKind.arrivingBy}
const journeys = [{serviceDate: "2026-11-08"}]
const failure = {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: "/routing/x"}
const answers = [
  {name: "found", answer: {kind: JourneysKind.found, journeys}, planned: leaving, expected: {kind: AnswerKind.journeys, journeys}},
  {name: "a point's found", answer: {kind: PointJourneysKind.found, journeys}, planned: leaving, expected: {kind: AnswerKind.journeys, journeys}},
  {name: "failed", answer: failure, planned: leaving, expected: {kind: AnswerKind.state, state: JourneysKind.failed, isRetry: true}},
  {name: "failed on a format it cannot read", answer: {...failure, reason: FailureReason.unsupportedVersion}, planned: leaving, expected: {kind: AnswerKind.state, state: JourneysKind.failed, isRetry: false}},
  {name: "failed on schedules not saved", answer: {...failure, reason: FailureReason.notSaved}, planned: leaving, expected: {kind: AnswerKind.state, state: StateKind.notSaved, isRetry: true}},
  {name: "none when leaving", answer: {kind: JourneysKind.none}, planned: leaving, expected: {kind: AnswerKind.state, state: JourneysKind.none, isRetry: false}},
  {name: "none when arriving by a time", answer: {kind: JourneysKind.none}, planned: arriving, expected: {kind: AnswerKind.state, state: StateKind.noneInTime, isRetry: false}},
  {name: "an unknown stop", answer: {kind: JourneysKind.unknownStop}, planned: leaving, expected: {kind: AnswerKind.state, state: JourneysKind.unknownStop, isRetry: false}},
  {name: "no stop near the start", answer: {kind: JourneysKind.noStartStop}, planned: leaving, expected: {kind: AnswerKind.state, state: JourneysKind.noStartStop, isRetry: false}},
  {name: "no stop near the destination", answer: {kind: PointJourneysKind.noEndStop}, planned: leaving, expected: {kind: AnswerKind.state, state: StateKind.noEndStop, isRetry: false}},
]

for (const {name, answer, planned, expected} of answers) {
  deepStrictEqual(answerOutcome({answer, planned}), expected, name)
}

console.log(`trip_route_check: ${answers.length} answers passed`)
