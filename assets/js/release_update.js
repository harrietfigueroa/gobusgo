// Registers the service worker, and offers a reload once a new release's
// worker has installed and waits. A page keeps the release it started with
// until the rider takes the offer: the page then asks the waiting worker to
// take over, and reloads once it has, so the page and its files always
// come from one release.
//
// Every open page shows the offer, and the worker one page has take over
// controls them all, so the offer of another page can name a worker that
// has already taken over: its click reloads at once (`reloadStep`). A
// takeover that has not come after RELOAD_WAIT_MS lets the rider take the
// offer again, with a message that says so.
//
// The browser checks for a new worker on every page load; a page left open
// checks again every UPDATE_CHECK_INTERVAL_MS.

import {unreachable} from "./assert.js"
import {writeMessage} from "./message.js"
import {RELOAD_WAIT_MS, ReloadStepKind, TAKEOVER_LATE_MESSAGE, reloadStep} from "./release_offer.js"
import {MessageKind} from "./service_worker_strategy.js"

const SERVICE_WORKER_PATH = "/sw.js"
const SERVICE_WORKER_SCOPE = "/"
const UPDATE_CHECK_INTERVAL_MS = 60 * 60 * 1000

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

// A worker that installs while another controls the page is a new release;
// one that installs with none is the first, which takes over by itself.
function watchInstalling({registration, offerReload}) {
  const worker = registration.installing

  function stateChanged() {
    const isInstalled = worker.state === "installed"
    const isNewRelease = isInstalled && navigator.serviceWorker.controller !== null

    if (isNewRelease) {
      offerReload(worker)
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
    offerReload(registration.waiting)
  }

  function updateFound() {
    watchInstalling({registration, offerReload})
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
