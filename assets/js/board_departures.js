// The arrivals board's list of scheduled departures: reads the time and the
// routes the call asked for, fetches the routing manifest and the snapshot
// files from the origin the document names, lists the departures at the stop
// on the device, draws them, and hands them to the model's context where the
// host takes it. No request names the time, the stop, or the routes: a fetch
// names only a file.

import {unreachable} from "./assert.js"
import {DepartureLoadKind, loadDepartures} from "./departure_files.js"
import {NO_HEADING, departuresView} from "./departures_view.js"
import {BoardInputKind} from "./mcp_board_input.js"
import {departuresContext, isOffered} from "./mcp_board_context.js"
import {FromKind, departureRows, fromMsOf, fromText, loadStatusText, refusalText} from "./mcp_board_departures.js"
import {OutcomeKind, updateModelContext} from "./mcp_host.js"
import {FetchKind} from "./routing_journeys.js"
import {DEPARTURE_COUNT_MAX, KeptKind} from "./scheduled_service.js"
import {fetchFileFrom, fetchManifest} from "./trip_route.js"

const ROUTING_MANIFEST_PATH = "/api/routing/manifest"
const LOADING_TEXT = "Reading the schedules"
const NO_ROWS = Object.freeze([])

function keptOf(routeIds) {
  if (routeIds.length === 0) {
    return {kind: KeptKind.every}
  }

  return {kind: KeptKind.routes, routeIds}
}

// What the read of the manifest and the files ended in, as a DepartureLoadKind member.
async function loadedOf({origin, input, fromMs}) {
  const manifestOutcome = await fetchManifest({origin, path: ROUTING_MANIFEST_PATH})

  if (manifestOutcome.kind !== FetchKind.fetched) {
    return {kind: DepartureLoadKind.failed, reason: manifestOutcome.reason, path: manifestOutcome.path}
  }

  return await loadDepartures({fetchFile: fetchFileFrom(origin), manifest: manifestOutcome.manifest, fromMs, stopId: input.stopId, kept: keptOf(input.routeIds), countMax: DEPARTURE_COUNT_MAX})
}

function rowsOf({loaded, fromMs, nowMs, timeZone}) {
  if (loaded.kind !== DepartureLoadKind.listed) {
    return NO_ROWS
  }

  return departureRows({departures: loaded.departures, fromMs, nowMs, timeZone})
}

function headingOf(loaded) {
  const isNamed = loaded.kind === DepartureLoadKind.listed && loaded.stopName !== null

  if (isNamed) {
    return loaded.stopName
  }

  return NO_HEADING
}

async function offer({host, loaded, input, fromMs, nowMs, timeZone}) {
  const context = departuresContext({loaded, stopId: input.stopId, fromMs, routeIds: input.routeIds, nowMs, timeZone})
  const outcome = await updateModelContext({host, structuredContent: context})

  if (outcome.kind !== OutcomeKind.answered) {
    console.debug("Departures not offered", {outcome: outcome.kind})
  }
}

/**
 * Shows the board's list of departures in `root` for `input`, a `scheduled`
 * or `refused` read of the call's arguments by `boardInput`, with files
 * fetched from `origin` and on the clock of `timeZone`. `isContextAccepted`
 * says whether the host takes the model's context, which the departures
 * go to once they are listed. Resolves once the list is drawn and offered.
 */
export async function showDepartures({root, host, origin, input, isContextAccepted, timeZone}) {
  const view = departuresView(root)

  if (input.kind === BoardInputKind.refused) {
    view.write({heading: NO_HEADING, fromLine: "", status: refusalText(input.field), rows: NO_ROWS})
    return
  }

  if (input.kind !== BoardInputKind.scheduled) {
    unreachable(input.kind, "board departures: a call that is not a list of departures")
  }

  const nowMs = Date.now()
  const from = fromMsOf({when: input.when, nowMs, timeZone})

  if (from.kind === FromKind.invalid) {
    view.write({heading: NO_HEADING, fromLine: "", status: refusalText("when"), rows: NO_ROWS})
    return
  }

  const fromMs = from.ms
  const fromLine = fromText({fromMs, nowMs, timeZone})
  view.write({heading: NO_HEADING, fromLine, status: LOADING_TEXT, rows: NO_ROWS})
  const loaded = await loadedOf({origin, input, fromMs})

  if (loaded.kind === DepartureLoadKind.failed) {
    console.warn("Departures not read", {reason: loaded.reason, path: loaded.path})
  }

  view.write({heading: headingOf(loaded), fromLine, status: loadStatusText(loaded), rows: rowsOf({loaded, fromMs, nowMs, timeZone})})

  const isToOffer = isContextAccepted && isOffered(loaded)

  if (isToOffer) {
    await offer({host, loaded, input, fromMs, nowMs, timeZone})
  }
}
