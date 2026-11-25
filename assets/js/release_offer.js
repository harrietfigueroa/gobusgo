// The rules of the offer to reload into a new release: whether a waiting
// worker is offered or takes over with no offer, from the release the page
// names and the release the worker answers with; what a click does, from the
// state of the worker the offer names; whether a shown offer is withdrawn
// once a worker of the page's own release takes over; and how long the page
// waits for each answer. Everything here is pure.
//
// A page loaded from the network after a release already runs that release
// under the worker before it, so a waiting worker of the page's own release
// takes over with no offer and no reload.
//
// Every open page of another release shows the offer while a new worker
// waits, and taking it in one page has that worker take over every page, so
// another page can hold an offer whose worker is already active: its click
// reloads.

import {assertCondition} from "#core/assert.js"
import {MessageKind} from "./service_worker_strategy.js"

/** What a click on the offer does: ask the offered worker to take over, or reload the page. */
export const ReloadStepKind = Object.freeze({activate: "activate", reload: "reload"})

/** What the page does with a waiting worker: offer the reload, have it take over with no offer, or nothing. */
export const OfferStepKind = Object.freeze({offer: "offer", activate: "activate", none: "none"})

/** The release the page names: one it belongs to, or none it can read. */
export const PageReleaseKind = Object.freeze({known: "known", unknown: "unknown"})

/** A waiting worker's answer to the page's question of its release: the release, or none in time. */
export const ReleaseAnswerKind = Object.freeze({release: "release", none: "none"})

/** The answer of a worker that gave no release before RELEASE_ANSWER_WAIT_MS passed. */
export const NO_RELEASE_ANSWER = Object.freeze({kind: ReleaseAnswerKind.none})

/** How long a page waits for the offered worker to take over before the offer can be taken again. */
export const RELOAD_WAIT_MS = 10 * 1000

/** How long a page waits for a waiting worker to name its release, which covers starting a stopped worker. */
export const RELEASE_ANSWER_WAIT_MS = 3 * 1000

/** The message the offer shows when the wait for a takeover has passed. */
export const TAKEOVER_LATE_MESSAGE = Object.freeze({
  headline: "The new version is still starting",
  caption: "Select Reload again, or reload the page from the browser."
})

// The states a worker holds once it has installed: waiting, taking over,
// in control, or replaced. The offer is shown for no other.
// https://w3c.github.io/ServiceWorker/#dom-serviceworker-state — checked 2026-11-10
const WAITING_STATE = "installed"
const TAKEN_OVER_STATES = Object.freeze(["activating", "activated", "redundant"])
// A worker that a newer install replaced, which is never offered.
// https://w3c.github.io/ServiceWorker/#installation-algorithm — checked 2026-11-20
const REPLACED_STATE = "redundant"

const RELEASE_DIGIT_COUNT = 16
const RELEASE_PATTERN = new RegExp(`^[0-9a-f]{${RELEASE_DIGIT_COUNT}}$`)

function isRelease(value) {
  const isText = typeof value === "string"

  if (isText) {
    return RELEASE_PATTERN.test(value)
  }

  return false
}

/** The release the page names in `content`, the release element's content, or null where it has none. */
export function pageReleaseOf(content) {
  const isKnown = isRelease(content)

  if (isKnown) {
    return {kind: PageReleaseKind.known, release: content}
  }

  return {kind: PageReleaseKind.unknown}
}

/** The answer a waiting worker's message `data` gives to the page's question of its release. */
export function releaseAnswerOf(data) {
  const isObject = typeof data === "object" && data !== null

  if (isObject) {
    const isReleaseMessage = data.kind === MessageKind.release
    const isAnswer = isReleaseMessage && isRelease(data.release)

    if (isAnswer) {
      return {kind: ReleaseAnswerKind.release, release: data.release}
    }
  }

  return NO_RELEASE_ANSWER
}

/**
 * What the page does with a waiting worker in `workerState` once it has
 * `answer`: a worker of the page's own release takes over with no offer, a
 * worker a newer install replaced is left alone, and any other is offered.
 */
export function offerStep({pageRelease, answer, workerState}) {
  const isReplaced = workerState === REPLACED_STATE

  if (isReplaced) {
    return OfferStepKind.none
  }

  const isPageKnown = pageRelease.kind === PageReleaseKind.known
  const isAnswered = answer.kind === ReleaseAnswerKind.release
  const isBothNamed = isPageKnown && isAnswered

  if (isBothNamed) {
    const isPageOwn = pageRelease.release === answer.release

    if (isPageOwn) {
      return OfferStepKind.activate
    }
  }

  return OfferStepKind.offer
}

/** The step a click takes for an offered worker in `workerState`; a worker that has not installed is refused. */
export function reloadStep({workerState}) {
  const isWaiting = workerState === WAITING_STATE

  if (isWaiting) {
    return ReloadStepKind.activate
  }

  const isTakenOver = TAKEN_OVER_STATES.includes(workerState)
  assertCondition(isTakenOver, "the offer names a worker that has installed, got the state: " + String(workerState))
  return ReloadStepKind.reload
}

/**
 * Whether the page withdraws an offer whose worker is in `workerState` once
 * a worker of the page's own release takes over: an offer whose click would
 * only reload, its worker no longer waiting, is withdrawn, and one whose
 * worker still waits stands. A worker that has not installed is refused, as
 * `reloadStep` refuses it.
 */
export function isOfferWithdrawn({workerState}) {
  const step = reloadStep({workerState})
  return step === ReloadStepKind.reload
}
