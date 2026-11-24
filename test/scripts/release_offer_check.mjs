// Checks the rules of the offer to reload into a new release against cases
// written out by hand: what a click does for each state the offered worker
// can be in, with a state the offer is never shown in refused; how the
// page's release and the waiting worker's answer are read; and whether a
// waiting worker is offered or activated with no offer. Run it with
// `node test/scripts/release_offer_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {
  OfferStepKind,
  PageReleaseKind,
  RELEASE_ANSWER_WAIT_MS,
  RELOAD_WAIT_MS,
  ReleaseAnswerKind,
  ReloadStepKind,
  isOfferWithdrawn,
  offerStep,
  pageReleaseOf,
  releaseAnswerOf,
  reloadStep
} from "../../assets/js/release_offer.js"
import {MessageKind} from "../../assets/js/service_worker_strategy.js"

const RELEASE_ONE = "0123456789abcdef"
const RELEASE_TWO = "fedcba9876543210"

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
  {name: "the wait for a takeover is positive", holds: RELOAD_WAIT_MS > 0},
  {name: "the wait for a worker's release is a whole count of milliseconds", holds: Number.isSafeInteger(RELEASE_ANSWER_WAIT_MS)},
  {name: "the wait for a worker's release is positive", holds: RELEASE_ANSWER_WAIT_MS > 0},
  {name: "the wait for a worker's release ends before the wait for a takeover", holds: RELEASE_ANSWER_WAIT_MS < RELOAD_WAIT_MS}
]

for (const testCase of waitCases) {
  deepStrictEqual(testCase.holds, true, testCase.name)
}

const pageReleaseCases = [
  {name: "a release of 16 lowercase hexadecimal digits is the page's", content: RELEASE_ONE, pageRelease: {kind: PageReleaseKind.known, release: RELEASE_ONE}},
  {name: "a page with no release element names no release", content: null, pageRelease: {kind: PageReleaseKind.unknown}},
  {name: "an empty release names none", content: "", pageRelease: {kind: PageReleaseKind.unknown}},
  {name: "a release in uppercase names none", content: RELEASE_ONE.toUpperCase(), pageRelease: {kind: PageReleaseKind.unknown}},
  {name: "a release one digit short names none", content: RELEASE_ONE.slice(1), pageRelease: {kind: PageReleaseKind.unknown}},
  {name: "a release with a character past f names none", content: "0123456789abcdeg", pageRelease: {kind: PageReleaseKind.unknown}}
]

for (const testCase of pageReleaseCases) {
  deepStrictEqual(pageReleaseOf(testCase.content), testCase.pageRelease, testCase.name)
}

const answerCases = [
  {name: "a release message is the worker's release", data: {kind: MessageKind.release, release: RELEASE_TWO}, answer: {kind: ReleaseAnswerKind.release, release: RELEASE_TWO}},
  {name: "a message of another kind is no answer", data: {kind: MessageKind.activate, release: RELEASE_TWO}, answer: {kind: ReleaseAnswerKind.none}},
  {name: "a release message with no release is no answer", data: {kind: MessageKind.release}, answer: {kind: ReleaseAnswerKind.none}},
  {name: "a release message with a malformed release is no answer", data: {kind: MessageKind.release, release: "release"}, answer: {kind: ReleaseAnswerKind.none}},
  {name: "a release message whose release is not text is no answer", data: {kind: MessageKind.release, release: 16}, answer: {kind: ReleaseAnswerKind.none}},
  {name: "null is no answer", data: null, answer: {kind: ReleaseAnswerKind.none}},
  {name: "text is no answer", data: RELEASE_TWO, answer: {kind: ReleaseAnswerKind.none}}
]

for (const testCase of answerCases) {
  deepStrictEqual(releaseAnswerOf(testCase.data), testCase.answer, testCase.name)
}

const knownOne = {kind: PageReleaseKind.known, release: RELEASE_ONE}
const unknownPage = {kind: PageReleaseKind.unknown}
const answeredOne = {kind: ReleaseAnswerKind.release, release: RELEASE_ONE}
const answeredTwo = {kind: ReleaseAnswerKind.release, release: RELEASE_TWO}
const unanswered = {kind: ReleaseAnswerKind.none}

const offerCases = [
  {name: "a waiting worker of the page's own release takes over with no offer", pageRelease: knownOne, answer: answeredOne, workerState: "installed", step: OfferStepKind.activate},
  {name: "a waiting worker of another release is offered", pageRelease: knownOne, answer: answeredTwo, workerState: "installed", step: OfferStepKind.offer},
  {name: "a waiting worker that gave no release in time is offered", pageRelease: knownOne, answer: unanswered, workerState: "installed", step: OfferStepKind.offer},
  {name: "a page that names no release offers the waiting worker", pageRelease: unknownPage, answer: answeredOne, workerState: "installed", step: OfferStepKind.offer},
  {name: "a page that names no release offers a worker that gave none", pageRelease: unknownPage, answer: unanswered, workerState: "installed", step: OfferStepKind.offer},
  {name: "a worker of another release another page already had take over is offered, so its click reloads", pageRelease: knownOne, answer: answeredTwo, workerState: "activated", step: OfferStepKind.offer},
  {name: "a worker of the page's own release another page already had take over is asked again, which is harmless", pageRelease: knownOne, answer: answeredOne, workerState: "activated", step: OfferStepKind.activate},
  {name: "a worker a newer install replaced is not offered", pageRelease: knownOne, answer: answeredTwo, workerState: "redundant", step: OfferStepKind.none},
  {name: "a worker of the page's own release a newer install replaced is not activated", pageRelease: knownOne, answer: answeredOne, workerState: "redundant", step: OfferStepKind.none}
]

for (const testCase of offerCases) {
  const step = offerStep({pageRelease: testCase.pageRelease, answer: testCase.answer, workerState: testCase.workerState})
  deepStrictEqual(step, testCase.step, testCase.name)
}

const withdrawCases = [
  {
    name: "an offer whose worker still waits stands",
    workerState: "installed",
    isWithdrawn: false
  },
  {
    name: "an offer whose worker another page asked to take over is withdrawn",
    workerState: "activating",
    isWithdrawn: true
  },
  {
    name: "an offer whose worker controls the page is withdrawn",
    workerState: "activated",
    isWithdrawn: true
  },
  {
    name: "an offer whose worker a newer install replaced is withdrawn",
    workerState: "redundant",
    isWithdrawn: true
  }
]

for (const testCase of withdrawCases) {
  deepStrictEqual(isOfferWithdrawn({workerState: testCase.workerState}), testCase.isWithdrawn, testCase.name)
}

for (const workerState of refusedStates) {
  throws(() => isOfferWithdrawn({workerState}), AssertionError, `the state ${JSON.stringify(workerState)} is refused for a withdrawal`)
}

const caseCount =
  stepCases.length +
  refusedStates.length +
  waitCases.length +
  pageReleaseCases.length +
  answerCases.length +
  offerCases.length +
  withdrawCases.length +
  refusedStates.length
console.log(`release offer: ${caseCount} cases pass`)
