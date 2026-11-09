// While the page is offline, places the vehicle markers and writes the open
// stops' arrivals from the saved schedules, every SCHEDULE_REFRESH_MS and
// whenever the routes the page shows change. It hands each result to the
// `dispatch` it is
// started with, under the event the hooks take it by: the markers under
// SCHEDULED_MARKERS_EVENT_NAME, which replace every agency's, and each open
// stop's arrivals under the server's own arrivals event. A page with no
// saved schedules gets no markers and no arrivals, so the in-place notes
// stand. Nothing runs while the page is hidden.

import {
  SCHEDULED_MARKER_COUNT_MAX,
  SCHEDULED_STATUS,
  SCHEDULE_REFRESH_MS,
  chunksAt,
  scheduledArrivals,
  scheduledMarkers
} from "./scheduled_service"
import {TableKind} from "./offline_answers"
import {CHANGE_EVENT_NAME as ROUTES_CHANGE_EVENT_NAME, keptRoutes} from "./route_stop_tiles"
import {savedConnections, savedSnapshots} from "./saved_snapshots"
import {assertCondition} from "./assert"

/** The event the vehicle markers take the scheduled markers by, which only the page itself sends. */
export const SCHEDULED_MARKERS_EVENT_NAME = "vehicle-markers:scheduled"

/** The name of the measure each placement records in the page's performance timeline. */
export const PLACEMENT_MEASURE_NAME = "gobusgo:scheduled-placement"

const ARRIVALS_EVENT_NAME = "stop-arrivals:arrivals"
const STATUSES_ELEMENT_ID = "vehicle-markers"
const PLACEMENT_START_MARK_NAME = "gobusgo:scheduled-placement-start"
// A placement asked for while one runs is run once after it, however many
// were asked for.
const PLACEMENT_RUN_COUNT_MAX = 2

let service = null
// Whether a placement runs, and whether another was asked for meanwhile.
let isPlacing = false
let isDue = false

function isScheduledStatus(status) {
  return status.status === SCHEDULED_STATUS
}

// The color of a scheduled marker, as the server's status definitions give it.
function scheduledColor() {
  const element = document.getElementById(STATUSES_ELEMENT_ID)
  assertCondition(element !== null, "the page has the vehicle markers' element")
  const statuses = JSON.parse(element.dataset.statuses)
  const scheduled = statuses.find(isScheduledStatus)
  assertCondition(scheduled !== undefined, "the statuses define the scheduled status")
  return scheduled.color
}

// The connections of `snapshot`'s chunks the time reads, decoded; a chunk the
// bundle lacks is left out.
async function connectionsAt({snapshot, nowMs}) {
  const connections = []

  for (const chunk of chunksAt({entry: snapshot, nowMs})) {
    const read = await savedConnections(chunk.path)

    if (read.kind === TableKind.found) {
      connections.push(read.table)
    }
  }

  return connections
}

async function readSnapshots(nowMs) {
  const saved = await savedSnapshots()
  const snapshots = []

  for (const snapshot of saved) {
    const connections = await connectionsAt({snapshot, nowMs})
    snapshots.push({...snapshot, connections})
  }

  return snapshots
}

function measureFrom(startMark) {
  performance.clearMeasures(PLACEMENT_MEASURE_NAME)
  performance.measure(PLACEMENT_MEASURE_NAME, startMark.name)
  performance.clearMarks(PLACEMENT_START_MARK_NAME)
}

async function place(running) {
  const nowMs = Date.now()
  const snapshots = await readSnapshots(nowMs)

  if (service !== running) {
    return
  }

  const startMark = performance.mark(PLACEMENT_START_MARK_NAME)
  const placed = scheduledMarkers({snapshots, nowMs, kept: keptRoutes(), color: scheduledColor(), countMax: SCHEDULED_MARKER_COUNT_MAX})
  running.dispatch(SCHEDULED_MARKERS_EVENT_NAME, {markers: placed.markers})

  if (snapshots.length > 0) {
    for (const stopId of running.openStopIds()) {
      const shown = scheduledArrivals({snapshots, stopId, nowMs})
      running.dispatch(ARRIVALS_EVENT_NAME, shown)
    }
  }

  measureFrom(startMark)
}

// Places for the service running at each run, so a service started while
// an earlier one's placement runs is placed once that placement ends.
async function placeWhileDue() {
  isPlacing = true

  try {
    for (let runCount = 0; runCount < PLACEMENT_RUN_COUNT_MAX; runCount++) {
      isDue = false
      const running = service

      if (running === null) {
        break
      }

      await place(running)

      if (!isDue) {
        break
      }
    }
  } catch (error) {
    console.warn("Scheduled positions not placed", {error})
  } finally {
    isPlacing = false
  }
}

function request() {
  if (isPlacing) {
    isDue = true
  } else {
    placeWhileDue()
  }
}

function tick() {
  const isVisible = document.visibilityState === "visible"
  const isRunning = service !== null
  const isTickDue = isVisible && isRunning

  if (isTickDue) {
    request()
  }
}

/**
 * Starts placing the markers and the arrivals of `openStopIds()`, the stops
 * the page holds open, handing each to `dispatch(name, payload)`, until
 * `stopOfflineService`. Starting a running service only asks for a
 * placement now.
 */
export function startOfflineService({dispatch, openStopIds}) {
  if (service !== null) {
    request()
    return
  }

  const timer = window.setInterval(tick, SCHEDULE_REFRESH_MS)
  service = {dispatch, openStopIds, timer}
  window.addEventListener(ROUTES_CHANGE_EVENT_NAME, tick)
  document.addEventListener("visibilitychange", tick)
  request()
}

/** Asks a running service to place the markers and the arrivals now; does nothing while none runs. */
export function refreshOfflineService() {
  if (service !== null) {
    request()
  }
}

/** Stops placing, so nothing more is handed on once the page is live. */
export function stopOfflineService() {
  if (service === null) {
    return
  }

  window.clearInterval(service.timer)
  window.removeEventListener(ROUTES_CHANGE_EVENT_NAME, tick)
  document.removeEventListener("visibilitychange", tick)
  service = null
}
