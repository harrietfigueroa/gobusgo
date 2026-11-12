// Drives a journey query: starts it, fetches the files each step asks for
// through the fetch function the caller hands in, each within
// FETCH_TIMEOUT_MS, holds their bytes for the query, and resumes it with
// every held file until it answers. The fetch function sees nothing but
// paths the manifest names.

import {assertCondition} from "./core/assert.js"
import {
  FETCH_TIMEOUT_MS,
  FailureReason,
  FetchKind,
  ROUND_COUNT_MAX,
  StepKind,
  TimeKind,
  checkedOutcome,
  resumeQuery,
  startQuery,
} from "./core/routing_journeys.js"

// Resolves on the outcome a timed-out fetch gets once `signal` aborts.
function timeoutOf(signal) {
  return new Promise(function awaitTimeout(resolve) {
    function resolveTimedOut() {
      resolve({kind: FetchKind.failed, reason: FailureReason.timedOut})
    }

    signal.addEventListener("abort", resolveTimedOut, {once: true})
  })
}

async function fetchSettled({fetchFile, path, signal}) {
  try {
    const outcome = await fetchFile({path, signal})
    const isFetched = outcome.kind === FetchKind.fetched
    const isFailed = outcome.kind === FetchKind.failed
    const isKnown = isFetched || isFailed
    assertCondition(isKnown, "routing driver: a fetch handed back an outcome of unknown kind " + outcome.kind)
    return outcome
  } catch (error) {
    return {kind: FetchKind.failed, reason: FailureReason.fetchFailed, error}
  }
}

// What fetching `path` through `fetchFile` hands back within
// FETCH_TIMEOUT_MS, a throw read as a failed fetch.
async function fetchTimed({fetchFile, path}) {
  const signal = AbortSignal.timeout(FETCH_TIMEOUT_MS)
  const pending = fetchSettled({fetchFile, path, signal})
  const expiry = timeoutOf(signal)
  return await Promise.race([pending, expiry])
}

/**
 * The content of `file`, an entry of the manifest, fetched through
 * `fetchFile` within FETCH_TIMEOUT_MS and of the size the manifest gives
 * it: `{kind: FetchKind.fetched, buffer}`, or the failure naming the file.
 */
export async function fetchChecked({fetchFile, file}) {
  const outcome = await fetchTimed({fetchFile, path: file.path})
  return checkedOutcome({outcome, file})
}

function fetchedValue(result) {
  assertCondition(result.status === "fulfilled", "routing driver: a timed fetch rejected: " + result.reason)
  return result.value
}

// What fetching each of `files` hands back, all at once, in their order.
async function fetchedOf({fetchFile, files}) {
  const pending = Array.from(files, function fetchRequested(file) {
    return fetchTimed({fetchFile, path: file.path})
  })
  const settled = await Promise.allSettled(pending)
  return Array.from(settled, fetchedValue)
}

async function driveQuery({manifest, request, fetchFile}) {
  const held = new Map()
  let {state, step} = startQuery({manifest, request})

  for (let round = 0; round < ROUND_COUNT_MAX; round++) {
    if (step.kind === StepKind.done) {
      return step.answer
    }

    const fetched = await fetchedOf({fetchFile, files: step.files})

    for (const [index, outcome] of fetched.entries()) {
      if (outcome.kind === FetchKind.fetched) {
        held.set(step.files[index].path, outcome.buffer)
      }
    }

    const resumed = resumeQuery({manifest, state, fetched, files: held})
    state = resumed.state
    step = resumed.step
  }

  assertCondition(step.kind === StepKind.done, "routing driver: a query asked for files past " + ROUND_COUNT_MAX + " rounds")
  return step.answer
}

/**
 * The journeys of `serviceDate` in `manifest` from `from` to the stop
 * `toStopId`, leaving at or after `departureS`, seconds from that date's
 * start, as `startQuery` answers them.
 * `fetchFile({path, signal})` hands back `{kind: FetchKind.fetched, buffer}`
 * with an ArrayBuffer, or `{kind: FetchKind.failed, reason}`.
 */
export async function routeJourneys({manifest, serviceDate, departureS, from, toStopId, fetchFile}) {
  const request = {kind: TimeKind.leaving, serviceDate, seconds: departureS, from, toStopId}
  return await driveQuery({manifest, request, fetchFile})
}

/**
 * The journeys of `serviceDate` in `manifest` from `from` to the stop
 * `toStopId`, arriving at or before `arrivalS`, seconds from that date's
 * start, as `startQuery` answers them, with `fetchFile` as `routeJourneys`
 * takes it.
 */
export async function routeJourneysArrivingBy({manifest, serviceDate, arrivalS, from, toStopId, fetchFile}) {
  const request = {kind: TimeKind.arrivingBy, serviceDate, seconds: arrivalS, from, toStopId}
  return await driveQuery({manifest, request, fetchFile})
}
