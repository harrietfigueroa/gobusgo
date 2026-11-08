// Registers the service worker, and offers a reload once a new release's
// worker has installed and waits. A page keeps the release it started with
// until the rider takes the offer: the page then asks the waiting worker to
// take over, and reloads once it has, so the page and its files always
// come from one release.
//
// The browser checks for a new worker on every page load; a page left open
// checks again every UPDATE_CHECK_INTERVAL_MS.

import {MessageKind} from "./service_worker_strategy.js"

const SERVICE_WORKER_PATH = "/sw.js"
const SERVICE_WORKER_SCOPE = "/"
const UPDATE_CHECK_INTERVAL_MS = 60 * 60 * 1000

function offerReload(worker) {
  const offer = document.getElementById("release-update")
  const button = offer.querySelector("[data-release-reload]")
  let reloading = false

  function controllerChanged() {
    if (reloading) {
      window.location.reload()
    }
  }

  function reloadClicked() {
    reloading = true
    button.disabled = true
    worker.postMessage({kind: MessageKind.activate})
  }

  navigator.serviceWorker.addEventListener("controllerchange", controllerChanged)
  button.addEventListener("click", reloadClicked, {once: true})
  offer.hidden = false
}

// A worker that installs while another controls the page is a new release;
// one that installs with none is the first, which takes over by itself.
function watchInstalling(registration) {
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

  registration.addEventListener("updatefound", () => watchInstalling(registration))
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
