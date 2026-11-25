// Checks when the page offers the reload into a new release, when it has a
// waiting worker take over with no offer, and when it withdraws a shown
// offer, by driving `registerServiceWorker` against a stand-in for the
// browser's service worker container, registration, and workers, and reading
// the offer's `hidden`, the messages the case's worker received, and the
// page's reloads and logged errors after each lifecycle step. The steps
// follow the Service Worker spec's Install and Activate algorithms
// (https://w3c.github.io/ServiceWorker/#installation-algorithm — checked
// 2026-11-20); a stand-in worker answers the page's release question on the
// port it is handed, at once, when the case says, or never. Each case also
// counts the errors the page logs, so a step that fails and is logged fails
// its case. Run it with `node test/scripts/release_update_check.mjs`; it
// prints each case and exits non-zero when any case differs.

import {deepStrictEqual} from "node:assert/strict"
import {RELEASE_ANSWER_WAIT_MS} from "../../assets/js/release_offer.js"
import {registerServiceWorker} from "../../assets/js/release_update.js"
import {MessageKind} from "../../assets/js/service_worker_strategy.js"

const RELEASE_ONE = "0123456789abcdef"
const RELEASE_TWO = "fedcba9876543210"
const RELEASE_THREE = "00112233445566ff"
// The macrotask turns a case waits for a port's answer to arrive.
const SETTLE_TURN_COUNT = 5

class FakeWorker extends EventTarget {
  // `release` is what the worker answers with, or null for a worker that
  // never answers; a worker with `isAnswerHeld` answers when `answer` is called.
  constructor({state, release, isAnswerHeld = false}) {
    super()
    this.state = state
    this.release = release
    this.isAnswerHeld = isAnswerHeld
    this.messages = []
    this.ports = []
  }

  postMessage(message, transfer) {
    this.messages.push(message.kind)

    if (Array.isArray(transfer)) {
      for (const port of transfer) {
        this.ports.push(port)
      }
    }

    const isReleaseQuestion = message.kind === MessageKind.release
    const isAnswerNow = isReleaseQuestion && !this.isAnswerHeld

    if (isAnswerNow) {
      this.answer()
    }
  }

  answer() {
    const isAnswering = this.release !== null

    if (isAnswering) {
      this.ports[0].postMessage({kind: MessageKind.release, release: this.release})
    }
  }

  moveTo(state) {
    this.state = state
    this.dispatchEvent(new Event("statechange"))
  }
}

class FakeRegistration extends EventTarget {
  constructor({waiting}) {
    super()
    this.waiting = waiting
    this.installing = null
  }

  update() {
    return Promise.resolve()
  }

  // Install's steps as a page sees them: updatefound with the installing
  // worker, the waiting worker it replaces made redundant, then its state
  // "installed" once it is the waiting worker.
  install(worker) {
    this.installing = worker
    this.dispatchEvent(new Event("updatefound"))
    this.installing = null
    const replaced = this.waiting
    this.waiting = worker

    if (replaced !== null) {
      replaced.moveTo("redundant")
    }

    worker.moveTo("installed")
  }
}

class FakeContainer extends EventTarget {
  constructor({controller, registration}) {
    super()
    this.controller = controller
    this.registration = registration
  }

  register() {
    return Promise.resolve(this.registration)
  }

  // Activate's steps as a page that uses the registration sees them.
  takeOver(worker) {
    this.registration.waiting = null
    worker.moveTo("activating")
    this.controller = worker
    this.dispatchEvent(new Event("controllerchange"))
    worker.moveTo("activated")
  }
}

function fakeOffer() {
  const button = new EventTarget()
  button.disabled = false
  const message = {}
  const offer = {
    hidden: true,
    querySelector(selector) {
      if (selector === "[data-release-reload]") {
        return button
      }

      return message
    }
  }
  return offer
}

// A document whose release element holds `pageRelease`, or that has none for null.
function fakeDocument({offer, pageRelease}) {
  const releaseElement = {getAttribute: () => pageRelease}

  function querySelector() {
    if (pageRelease === null) {
      return null
    }

    return releaseElement
  }

  return {readyState: "complete", getElementById: () => offer, querySelector}
}

async function settle() {
  for (let turn = 0; turn < SETTLE_TURN_COUNT; turn += 1) {
    await new Promise(setImmediate)
  }
}

async function pageWith({controller, waiting, pageRelease}) {
  const registration = new FakeRegistration({waiting})
  const container = new FakeContainer({controller, registration})
  const offer = fakeOffer()
  const reloads = []
  const timers = []
  const timerIdsCleared = new Set()
  const windowListeners = []
  const errorsLogged = []

  function errorRecorded(...parts) {
    errorsLogged.push(parts)
  }

  function setTimeoutRecorded(callback, delayMs) {
    timers.push({callback, delayMs})
    return timers.length
  }

  function clearTimeoutRecorded(timerId) {
    timerIdsCleared.add(timerId)
  }

  function addEventListenerRecorded(type, listener) {
    windowListeners.push({type, listener})
  }

  // Runs the timers set for `delayMs`, as if that long had passed.
  async function pass(delayMs) {
    for (const [timerIndex, timer] of timers.entries()) {
      const timerId = timerIndex + 1
      const isDue = timer.delayMs === delayMs
      const isDueUncleared = isDue && !timerIdsCleared.has(timerId)

      if (isDueUncleared) {
        timer.callback()
      }
    }

    await settle()
  }

  Object.defineProperty(globalThis, "navigator", {value: {serviceWorker: container}, configurable: true})
  console.error = errorRecorded
  globalThis.document = fakeDocument({offer, pageRelease})
  globalThis.window = {
    setInterval: () => 0,
    setTimeout: setTimeoutRecorded,
    clearTimeout: clearTimeoutRecorded,
    addEventListener: addEventListenerRecorded,
    location: {reload: () => reloads.push(true)}
  }

  registerServiceWorker()
  await settle()
  return {container, registration, offer, reloads, errorsLogged, pass}
}

// An open port with a listener keeps Node running.
function closePorts(worker) {
  for (const port of worker.ports) {
    port.close()
  }
}

// The case's outcome, read before the ports the worker was handed are closed.
function outcomeOf({page, worker}) {
  const outcome = {
    hidden: page.offer.hidden,
    activated: worker.messages.includes(MessageKind.activate),
    reloadCount: page.reloads.length,
    errorCount: page.errorsLogged.length
  }
  closePorts(worker)
  return outcome
}

const offered = {hidden: false, activated: false, reloadCount: 0, errorCount: 0}
const takenOverQuietly = {hidden: true, activated: true, reloadCount: 0, errorCount: 0}
const untouched = {hidden: true, activated: false, reloadCount: 0, errorCount: 0}

const cases = [
  {
    name: "a worker of another release waiting at load is offered",
    async run() {
      const waiting = new FakeWorker({state: "installed", release: RELEASE_TWO})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting, pageRelease: RELEASE_ONE})
      return outcomeOf({page, worker: waiting})
    },
    outcome: offered
  },
  {
    name: "a worker of another release that installs while the page is open is offered",
    async run() {
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting: null, pageRelease: RELEASE_ONE})
      const installing = new FakeWorker({state: "installing", release: RELEASE_TWO})
      page.registration.install(installing)
      await settle()
      return outcomeOf({page, worker: installing})
    },
    outcome: offered
  },
  {
    name: "a worker of the page's own release waiting at load takes over with no offer and no reload",
    async run() {
      const waiting = new FakeWorker({state: "installed", release: RELEASE_TWO})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting, pageRelease: RELEASE_TWO})
      page.container.takeOver(waiting)
      return outcomeOf({page, worker: waiting})
    },
    outcome: takenOverQuietly
  },
  {
    name: "a worker of the page's own release that installs while the page is open takes over with no offer",
    async run() {
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting: null, pageRelease: RELEASE_TWO})
      const installing = new FakeWorker({state: "installing", release: RELEASE_TWO})
      page.registration.install(installing)
      await settle()
      return outcomeOf({page, worker: installing})
    },
    outcome: takenOverQuietly
  },
  {
    name: "a waiting worker that never answers is offered once the wait for its release has passed",
    async run() {
      const waiting = new FakeWorker({state: "installed", release: null})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting, pageRelease: RELEASE_ONE})
      await page.pass(RELEASE_ANSWER_WAIT_MS)
      return outcomeOf({page, worker: waiting})
    },
    outcome: offered
  },
  {
    name: "a waiting worker that has not answered is not offered before the wait for its release has passed",
    async run() {
      const waiting = new FakeWorker({state: "installed", release: null})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting, pageRelease: RELEASE_ONE})
      return outcomeOf({page, worker: waiting})
    },
    outcome: untouched
  },
  {
    name: "a page that names no release offers the waiting worker",
    async run() {
      const waiting = new FakeWorker({state: "installed", release: RELEASE_TWO})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting, pageRelease: null})
      return outcomeOf({page, worker: waiting})
    },
    outcome: offered
  },
  {
    name: "the first install, with no worker controlling the page, offers nothing and activates nothing",
    async run() {
      const page = await pageWith({controller: null, waiting: null, pageRelease: RELEASE_ONE})
      const installing = new FakeWorker({state: "installing", release: RELEASE_TWO})
      page.registration.install(installing)
      await settle()
      return outcomeOf({page, worker: installing})
    },
    outcome: untouched
  },
  {
    name: "a page of an older release keeps its offer after another page has the new worker take over",
    async run() {
      const waiting = new FakeWorker({state: "installed", release: RELEASE_TWO})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting, pageRelease: RELEASE_ONE})
      page.container.takeOver(waiting)
      return outcomeOf({page, worker: waiting})
    },
    outcome: offered
  },
  {
    name: "a page withdraws its offer of an older release once a worker of its own release installs and takes over",
    async run() {
      const older = new FakeWorker({state: "installed", release: RELEASE_THREE})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting: older, pageRelease: RELEASE_TWO})
      const own = new FakeWorker({state: "installing", release: RELEASE_TWO})
      page.registration.install(own)
      await settle()
      page.container.takeOver(own)
      closePorts(older)
      return outcomeOf({page, worker: own})
    },
    outcome: takenOverQuietly
  },
  {
    name: "an offer whose worker still waits stands when a worker of the page's own release, which another page had take over, answers late",
    async run() {
      const own = new FakeWorker({state: "installed", release: RELEASE_TWO, isAnswerHeld: true})
      const active = new FakeWorker({state: "activated", release: RELEASE_ONE})
      const page = await pageWith({controller: active, waiting: own, pageRelease: RELEASE_TWO})
      page.container.takeOver(own)
      const third = new FakeWorker({state: "installing", release: RELEASE_THREE})
      page.registration.install(third)
      await settle()
      own.answer()
      await settle()
      closePorts(own)
      return outcomeOf({page, worker: third})
    },
    outcome: offered
  }
]

let failureCount = 0

for (const testCase of cases) {
  const outcome = await testCase.run()

  try {
    deepStrictEqual(outcome, testCase.outcome, testCase.name)
    console.log(`pass: ${testCase.name}`)
  } catch {
    failureCount = failureCount + 1
    console.log(`FAIL: ${testCase.name}: got ${JSON.stringify(outcome)}, expected ${JSON.stringify(testCase.outcome)}`)
  }
}

console.log(`release update: ${cases.length - failureCount} of ${cases.length} cases pass`)
process.exitCode = failureCount
