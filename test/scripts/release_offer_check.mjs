// Checks what a click on the offer to reload into a new release does, for
// each state the offered worker can be in, against cases written out by
// hand, and that a state the offer is never shown in is refused. Run it with
// `node test/scripts/release_offer_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {RELOAD_WAIT_MS, ReloadStepKind, reloadStep} from "../../assets/js/release_offer.js"

const stepCases = [
  {
    name: "a worker that waits is asked to take over",
    workerState: "installed",
    step: ReloadStepKind.activate
  },
  {
    name: "a worker another page asked to take over, still activating, needs only a reload",
    workerState: "activating",
    step: ReloadStepKind.reload
  },
  {
    name: "a worker another page had take over needs only a reload",
    workerState: "activated",
    step: ReloadStepKind.reload
  },
  {
    name: "a worker a newer release replaced reloads into whatever controls the page",
    workerState: "redundant",
    step: ReloadStepKind.reload
  }
]

for (const testCase of stepCases) {
  deepStrictEqual(reloadStep({workerState: testCase.workerState}), testCase.step, testCase.name)
}

const refusedStates = ["parsed", "installing", "", "waiting"]

for (const workerState of refusedStates) {
  throws(() => reloadStep({workerState}), AssertionError, `the state ${JSON.stringify(workerState)} is refused`)
}

const waitCases = [
  {name: "the wait for a takeover is a whole count of milliseconds", holds: Number.isSafeInteger(RELOAD_WAIT_MS)},
  {name: "the wait for a takeover is positive", holds: RELOAD_WAIT_MS > 0}
]

for (const testCase of waitCases) {
  deepStrictEqual(testCase.holds, true, testCase.name)
}

const caseCount = stepCases.length + refusedStates.length + waitCases.length
console.log(`release offer: ${caseCount} cases pass`)
