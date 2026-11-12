// The rules of the offer to reload into a new release: what a click does,
// from the state of the worker the offer names, and how long the page waits
// for that worker to take over. Everything here is pure.
//
// Every open page shows the offer while a new worker waits, and taking it
// in one page has that worker take over every page, so another page can
// hold an offer whose worker is already active: its click reloads.

import {assertCondition} from "./core/assert.js"

/** What a click on the offer does: ask the offered worker to take over, or reload the page. */
export const ReloadStepKind = Object.freeze({activate: "activate", reload: "reload"})

/** How long a page waits for the offered worker to take over before the offer can be taken again. */
export const RELOAD_WAIT_MS = 10 * 1000

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
