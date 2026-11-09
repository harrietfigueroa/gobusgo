// How the service worker answers the vehicle page: from the network first,
// and from the stored bare copy of `/vehicles` when the network fails, the
// server errs, or the network has not answered within the wait. A
// successful answer to the bare address becomes the copy, so the copy holds
// no filter. The network, the copy's store, and the wait are functions this
// module is handed, so it reads no cache, fetches nothing, and starts no
// timer of its own.

import {StoredKind} from "./saved_files.js"

/** How long the network is waited for before a stored copy is answered. */
export const VEHICLE_PAGE_COPY_WAIT_MS = 5 * 1000

const SERVER_ERROR_STATUS_MIN = 500

// What came first of the network's answer and the end of the wait.
const OutcomeKind = Object.freeze({answered: "answered", failed: "failed", waited: "waited"})
const WAITED = Object.freeze({kind: OutcomeKind.waited})

function answeredOf(response) {
  return {kind: OutcomeKind.answered, response}
}

function failedOf(error) {
  return {kind: OutcomeKind.failed, error}
}

function waitedOf() {
  return WAITED
}

async function keepCopy({response, storeCopy}) {
  const copy = response.clone()

  try {
    await storeCopy(copy)
  } catch (error) {
    console.warn("Vehicle page copy not stored", error)
  }
}

async function keepBareSuccess({isBare, response, storeCopy}) {
  const isKept = isBare && response.ok

  if (isKept) {
    await keepCopy({response, storeCopy})
  }
}

async function answerWithoutCopy({isBare, network, storeCopy, offlineAnswer}) {
  let response

  try {
    response = await network
  } catch (error) {
    console.warn("Vehicle page not fetched, offline screen shown", error)
    return offlineAnswer()
  }

  await keepBareSuccess({isBare, response, storeCopy})
  return response
}

/**
 * The answer to a navigation to the vehicle page: `fetchNetwork()`'s, a
 * success of which replaces the copy through `storeCopy` when `isBare`;
 * else the copy `readCopy()` reads, from `storedOf`, once the network fails,
 * answers 5xx, or `copyWait()` resolves first; else, with no copy, the
 * network's answer or `offlineAnswer()`.
 */
export async function answerVehiclePage({isBare, fetchNetwork, readCopy, storeCopy, copyWait, offlineAnswer}) {
  const copy = await readCopy()
  const network = fetchNetwork()

  if (copy.kind === StoredKind.missing) {
    return await answerWithoutCopy({isBare, network, storeCopy, offlineAnswer})
  }

  const networkOutcome = network.then(answeredOf, failedOf)
  const waitOutcome = copyWait().then(waitedOf)
  const outcome = await Promise.race([networkOutcome, waitOutcome])

  if (outcome.kind !== OutcomeKind.answered) {
    return copy.response
  }

  const {response} = outcome

  if (response.status >= SERVER_ERROR_STATUS_MIN) {
    return copy.response
  }

  await keepBareSuccess({isBare, response, storeCopy})
  return response
}

/** Fetches the bare page with `fetchNetwork()` and keeps a success as the copy through `storeCopy`. */
export async function refreshVehiclePageCopy({fetchNetwork, storeCopy}) {
  let response

  try {
    response = await fetchNetwork()
  } catch (error) {
    console.warn("Vehicle page copy not fetched", error)
    return
  }

  if (response.ok) {
    await keepCopy({response, storeCopy})
  }
}
