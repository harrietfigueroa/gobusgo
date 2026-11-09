// The offline host of the vehicle page: a copy of the page opened with no
// network mounts no hook, since LiveView mounts hooks only on a join, so
// while the page is offline before its first join this module mounts each
// `[phx-hook]` element's hook itself, in document order, from the hooks map
// LiveView is given. It mounts them over the saved data: the saved route
// and stop tile archive's address in place of the copy's, and the routes of
// the address's filter, or else of the stored filter, in place of the
// copy's, which holds no filter, with the summary line naming that filter.
//
// The start of LiveView's first patch hands the page over: the host keeps
// what each instance hands over, destroys the instances in reverse order,
// and LiveView mounts its own on the patched page, with no reload. The
// page's `phx-mounted` commands, which keep the panel sheet's open tab and
// expanded state across a patch, are run when the host mounts, so the
// first patch keeps them too.

import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state"
import {ConnectionKind} from "./connection_rules"
import {HandoffKind, keepHandoffState} from "./hook_handoff"
import {IndexKind} from "./offline_bundle"
import {
  BootEventKind,
  BootPhase,
  KeptRoutesKind,
  SummaryKind,
  addressFilterOf,
  bootFilterOf,
  isHostMounted,
  keptRoutesOf,
  nextBootPhase,
  storedFilterOf,
  summaryOf
} from "./offline_boot_rules"
import {readSavedIndex} from "./offline_schedules"
import {savedSnapshots} from "./saved_snapshots"
import {storedSettings} from "./stored_settings"

const TILES_ELEMENT_ID = "route-stop-tiles"
const SUMMARY_LINE_SELECTOR = "#panel-sheet-summary > p.panel-sheet-summary-line:not(.local-trip-summary)"
const HOOK_SELECTOR = "[phx-hook]"
const MOUNTED_SELECTOR = "[phx-mounted]"
const NO_SERVER_TEXT = "the offline host has no server to send to"

let phase = BootPhase.waiting
let hooks = null
let liveSocket = null
// The instances the host mounted, each with its element, in document order.
let instances = []

async function savedArchivePath() {
  try {
    const read = await readSavedIndex()

    if (read.kind === IndexKind.none) {
      return ""
    }

    return read.index.tileArchivePath
  } catch (error) {
    console.warn("Saved index not read for the offline host", error)
    return ""
  }
}

async function snapshotsRead() {
  try {
    return await savedSnapshots()
  } catch (error) {
    console.warn("Saved snapshots not read for the offline host", error)
    return []
  }
}

async function overridesRead() {
  const archivePath = await savedArchivePath()
  const snapshots = await snapshotsRead()
  const address = addressFilterOf(window.location.search)
  const stored = storedFilterOf(storedSettings.readVehicleFilter())
  const filter = bootFilterOf({address, stored})
  const kept = keptRoutesOf({filter, snapshots})
  const summary = summaryOf({filter, snapshots})
  return {archivePath, kept, summary}
}

function applyTiles({archivePath, kept}) {
  const element = document.getElementById(TILES_ELEMENT_ID)

  if (element === null) {
    return
  }

  // An archive the bundle does not hold cannot be read offline, so the
  // copy's address stands only where nothing is saved.
  if (archivePath !== "") {
    element.dataset.archiveUrl = archivePath
  }

  if (kept.kind === KeptRoutesKind.every) {
    element.removeAttribute("data-route-ids")
  } else {
    element.dataset.routeIds = JSON.stringify(kept.routeIds)
  }
}

function span({className, text}) {
  const element = document.createElement("span")
  element.className = className
  element.textContent = text
  return element
}

function appendChips({line, names}) {
  for (const name of names) {
    line.append(span({className: "panel-sheet-chip", text: name}), " ")
  }
}

// Writes the summary line as the server renders it for the filter.
function applySummary(summary) {
  if (summary.kind === SummaryKind.rendered) {
    return
  }

  const line = document.querySelector(SUMMARY_LINE_SELECTOR)

  if (line === null) {
    return
  }

  const {agencyNames, routeNames} = summary
  line.replaceChildren(span({className: "offline-prefix", text: "Offline · "}), span({className: "text-slate-600", text: "Showing"}), " ")
  appendChips({line, names: agencyNames})
  const namesBoth = agencyNames.length > 0 && routeNames.length > 0

  if (namesBoth) {
    line.append(span({className: "text-slate-600", text: "and"}), " ")
  }

  appendChips({line, names: routeNames})
}

function runMountedCommands() {
  for (const element of document.querySelectorAll(MOUNTED_SELECTOR)) {
    liveSocket.execJS(element, element.getAttribute("phx-mounted"))
  }
}

function hostPushEvent() {
  return Promise.reject(new Error(NO_SERVER_TEXT))
}

function hostHandleEvent() {
  // The host's instances hear no server, so a handler is kept by nobody.
}

function hostRemoveHandleEvent() {
  // No handler is kept, so none is removed.
}

// LiveView hands a hook its element as `el`, the name every hook reads, so
// the host writes that one property and reads the element from its own
// entry.
function instanceOf({element, definition}) {
  const instance = Object.create(definition)
  instance.el = element
  instance.pushEvent = hostPushEvent
  instance.handleEvent = hostHandleEvent
  instance.removeHandleEvent = hostRemoveHandleEvent
  return instance
}

function mountHooks() {
  for (const element of document.querySelectorAll(HOOK_SELECTOR)) {
    const name = element.getAttribute("phx-hook")

    if (!isHostMounted(name)) {
      continue
    }

    const definition = hooks[name]

    if (definition === undefined) {
      console.warn("Offline host: no hook of this name", {name})
      continue
    }

    const instance = instanceOf({element, definition})

    // One hook that fails leaves the others drawing what they can.
    try {
      instance.mounted()
      instances.push({instance, element})
    } catch (error) {
      console.error("Offline host: hook not mounted", {name, error})
    }
  }
}

function mount(overrides) {
  applyTiles(overrides)
  applySummary(overrides.summary)
  runMountedCommands()
  mountHooks()
}

function handOver({instance, element}) {
  if (typeof instance.handoffState !== "function") {
    return
  }

  const handed = instance.handoffState()

  if (handed.kind === HandoffKind.found) {
    keepHandoffState({elementId: element.id, state: handed.state})
  }
}

function destroyHooks() {
  const mounted = instances
  instances = []

  for (const entry of Array.from(mounted).reverse()) {
    try {
      handOver(entry)

      if (typeof entry.instance.destroyed === "function") {
        entry.instance.destroyed()
      }
    } catch (error) {
      console.error("Offline host: hook not destroyed", {id: entry.element.id, error})
    }
  }
}

async function prepare() {
  const overrides = await overridesRead()
  report({kind: BootEventKind.prepared, overrides})
}

function prepareCallback() {
  prepare().catch(prepareFailedCallback)
}

function prepareFailedCallback(error) {
  console.error("Offline host not prepared", error)
}

function report(event) {
  const previous = phase
  phase = nextBootPhase({phase: previous, event: event.kind})
  const isPreparing = previous === BootPhase.waiting && phase === BootPhase.preparing
  const isMounting = previous === BootPhase.preparing && phase === BootPhase.mounted
  const isHandingOff = previous === BootPhase.mounted && phase === BootPhase.handedOff
  const isDone = previous !== BootPhase.handedOff && phase === BootPhase.handedOff

  if (isPreparing) {
    prepareCallback()
  } else if (isMounting) {
    mount(event.overrides)
  } else if (isHandingOff) {
    destroyHooks()
  }

  if (isDone) {
    window.removeEventListener(CONNECTION_CHANGE_EVENT_NAME, connectionChanged)
  }
}

function connectionChanged(event) {
  if (event.detail.connection.kind === ConnectionKind.offline) {
    report({kind: BootEventKind.offline})
  }
}

/**
 * Starts the host over `hookDefinitions`, the hooks map `socket`, the
 * LiveSocket, is given. Called once, after the connection state is watched
 * and the socket is told to connect, which makes the views the page's
 * `phx-mounted` commands run in and cannot join before the host has read
 * the state: a page offline then mounts once its overrides are read, and
 * one that goes offline before its first join mounts then.
 */
export function startOfflineHost({hookDefinitions, socket}) {
  hooks = hookDefinitions
  liveSocket = socket
  window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, connectionChanged)

  if (connectionState().kind === ConnectionKind.offline) {
    report({kind: BootEventKind.offline})
  }
}

/** Hands the page over to LiveView: given to the LiveSocket as its `onPatchStart`, whose first call is the first join's patch. */
export function handOffOfflineHost() {
  report({kind: BootEventKind.joinPatch})
}
