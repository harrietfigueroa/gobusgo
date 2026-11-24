// Registers the service worker, and offers a reload once a new release's
// worker has installed and waits. A page keeps the release it started with
// until the rider takes the offer: the page then asks the waiting worker to
// take over, and reloads once it has, so the page and its files always
// come from one release.
//
// Before it offers, the page asks the waiting worker for its release and
// compares it with the one the root layout names (`offerStep`). A worker of
// the page's own release, the case of a page loaded from the network after
// a release, takes over with no offer and no reload; a worker that gives no
// release within RELEASE_ANSWER_WAIT_MS is offered.
//
// Every open page shows the offer, and the worker one page has take over
// controls them all, so the offer of another page can name a worker that
// has already taken over: its click reloads at once (`reloadStep`). A
// takeover that has not come after RELOAD_WAIT_MS lets the rider take the
// offer again, with a message that says so.
//
// The browser checks for a new worker on every page load; a page left open
// checks again every UPDATE_CHECK_INTERVAL_MS.

import {unreachable} from "#core/assert.js"
import {writeMessage} from "./message.js"
import {
  NO_RELEASE_ANSWER,
  OfferStepKind,
  RELEASE_ANSWER_WAIT_MS,
  RELOAD_WAIT_MS,
  ReloadStepKind,
  TAKEOVER_LATE_MESSAGE,
  offerStep,
  pageReleaseOf,
  releaseAnswerOf,
  reloadStep
} from "./release_offer.js"
import {MessageKind} from "./service_worker_strategy.js"

const SERVICE_WORKER_PATH = "/sw.js"
const SERVICE_WORKER_SCOPE = "/"
const UPDATE_CHECK_INTERVAL_MS = 60 * 60 * 1000
const RELEASE_ELEMENT_SELECTOR = 'meta[name="gobusgo:release"]'

// The page's one offer. Its click acts on the worker the offer named last,
// so a newer release that installs while the offer is shown replaces the
// worker it names. Returns the function that shows the offer for a worker.
function releaseOffer() {
  const offer = document.getElementById("release-update")
  const button = offer.querySelector("[data-release-reload]")
  const text = offer.querySelector("[data-release-message]")
  let offered = null
  let reloading = false

  function controllerChanged() {
    if (reloading) {
      window.location.reload()
    }
  }

  // The rider asked for the reload, so `reloading` stays set: a takeover
  // that comes after the wait still reloads the page.
  function takeoverWaitEnded() {
    button.disabled = false
    writeMessage({element: text, message: TAKEOVER_LATE_MESSAGE})
  }

  function reloadClicked() {
    const step = reloadStep({workerState: offered.state})
    button.disabled = true

    switch (step) {
      case ReloadStepKind.activate:
        reloading = true
        offered.postMessage({kind: MessageKind.activate})
        window.setTimeout(takeoverWaitEnded, RELOAD_WAIT_MS)
        break
      case ReloadStepKind.reload:
        window.location.reload()
        break
      default:
        unreachable(step, "reload step")
    }
  }

  function show(worker) {
    offered = worker
    offer.hidden = false
  }

  navigator.serviceWorker.addEventListener("controllerchange", controllerChanged)
  button.addEventListener("click", reloadClicked)
  return show
}

// The release the root layout names, read once, since it is the release of
// the files the page loaded.
function readPageRelease() {
  const element = document.querySelector(RELEASE_ELEMENT_SELECTOR)

  if (element === null) {
    return pageReleaseOf(null)
  }

  const content = element.getAttribute("content")
  return pageReleaseOf(content)
}

// Asks `worker` for its release on a port of its own, and settles on its
// answer or, once RELEASE_ANSWER_WAIT_MS has passed, on none.
function askRelease(worker) {
  function askReleaseExecutor(resolve) {
    const channel = new MessageChannel()
    let timer = null

    function settled(answer) {
      window.clearTimeout(timer)
      channel.port1.close()
      resolve(answer)
    }

    function answered(event) {
      const answer = releaseAnswerOf(event.data)
      settled(answer)
    }

    function waitEnded() {
      settled(NO_RELEASE_ANSWER)
    }

    channel.port1.onmessage = answered
    timer = window.setTimeout(waitEnded, RELEASE_ANSWER_WAIT_MS)
    worker.postMessage({kind: MessageKind.release}, [channel.port2])
  }

  return new Promise(askReleaseExecutor)
}

// Offers a waiting worker of another release, and has one of the page's own
// release take over with no offer. The worker's state is read after the
// answer, since a newer install can replace it meanwhile.
async function settleWaiting({worker, pageRelease, offerReload}) {
  const answer = await askRelease(worker)
  const step = offerStep({pageRelease, answer, workerState: worker.state})

  switch (step) {
    case OfferStepKind.offer:
      offerReload(worker)
      break
    case OfferStepKind.activate:
      worker.postMessage({kind: MessageKind.activate})
      break
    case OfferStepKind.none:
      break
    default:
      unreachable(step, "offer step")
  }
}

// A worker that installs while another controls the page is a new worker;
// one that installs with none is the first, which takes over by itself.
function watchInstalling({registration, pageRelease, offerReload}) {
  const worker = registration.installing

  function stateChanged() {
    const isInstalled = worker.state === "installed"
    const isNewRelease = isInstalled && navigator.serviceWorker.controller !== null

    if (isNewRelease) {
      settleWaiting({worker, pageRelease, offerReload})
    }
  }

  worker.addEventListener("statechange", stateChanged)
}

async function checkForRelease(registration) {
  try {
    await registration.update()
  } catch (error) {
    console.warn("Service worker update not checked", error)
  }
}

async function register() {
  const offerReload = releaseOffer()
  const pageRelease = readPageRelease()
  let registration = null

  try {
    registration = await navigator.serviceWorker.register(SERVICE_WORKER_PATH, {
      scope: SERVICE_WORKER_SCOPE,
      type: "classic",
      updateViaCache: "none"
    })
  } catch (error) {
    console.warn("Service worker not registered", error)
    return
  }

  if (registration.waiting !== null) {
    settleWaiting({worker: registration.waiting, pageRelease, offerReload})
  }

  function updateFound() {
    watchInstalling({registration, pageRelease, offerReload})
  }

  registration.addEventListener("updatefound", updateFound)
  window.setInterval(() => checkForRelease(registration), UPDATE_CHECK_INTERVAL_MS)
}

/** Registers the service worker once the page has loaded, in a browser that has them. */
export function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) {
    return
  }

  if (document.readyState === "complete") {
    register()
  } else {
    window.addEventListener("load", register, {once: true})
  }
}
