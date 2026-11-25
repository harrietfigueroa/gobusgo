// Checks the offline basemap's pure rules against cases written out by
// hand: which archive the map draws in each connection state, with the
// extract saved and not saved, which stored copies a save deletes, and what the
// status line says of the map while the setting is on. Run it with
// `node test/scripts/offline_basemap_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {ConnectionKind, OfflineReason} from "../../assets/js/connection_rules.js"
import {PersistenceKind} from "../../assets/js/core/offline_bundle.js"
import {
  BasemapSaveKind,
  drawnArchiveUrl,
  savedBasemapOf,
  stalePaths,
  statusMessage
} from "../../assets/js/offline_basemap.js"

const ARCHIVE_URL = "/basemap/basemap-20261004-01.pmtiles"
const OFFLINE_ARCHIVE_URL = "/basemap/basemap-20261004-01-z13.pmtiles"
const OLDER_OFFLINE_ARCHIVE_URL = "/basemap/basemap-20260901-01-z13.pmtiles"
const LIVE = {kind: ConnectionKind.live}
const CONNECTING = {kind: ConnectionKind.connecting}
const OFFLINE = {kind: ConnectionKind.offline, reason: OfflineReason.browserOffline}
const UNREACHABLE = {kind: ConnectionKind.offline, reason: OfflineReason.serverUnreachable}
const SAVED = savedBasemapOf({url: OFFLINE_ARCHIVE_URL, isStored: true})
const NOT_SAVED = savedBasemapOf({url: OFFLINE_ARCHIVE_URL, isStored: false})
const OLDER_SAVED = savedBasemapOf({url: OLDER_OFFLINE_ARCHIVE_URL, isStored: true})

deepStrictEqual(SAVED, {kind: BasemapSaveKind.saved, url: OFFLINE_ARCHIVE_URL}, "a stored extract reads as saved")
deepStrictEqual(NOT_SAVED, {kind: BasemapSaveKind.notSaved}, "an extract the store lacks reads as not saved")

const drawnCases = [
  {name: "live, with the extract saved", connection: LIVE, saved: SAVED, drawn: ARCHIVE_URL},
  {name: "connecting, with the extract saved", connection: CONNECTING, saved: SAVED, drawn: ARCHIVE_URL},
  {name: "offline, with the extract saved", connection: OFFLINE, saved: SAVED, drawn: OFFLINE_ARCHIVE_URL},
  {name: "server unreachable, with the extract saved", connection: UNREACHABLE, saved: SAVED, drawn: OFFLINE_ARCHIVE_URL},
  {name: "offline, with no extract saved", connection: OFFLINE, saved: NOT_SAVED, drawn: ARCHIVE_URL},
  {name: "offline, with another build's extract saved", connection: OFFLINE, saved: OLDER_SAVED, drawn: ARCHIVE_URL}
]

for (const drawnCase of drawnCases) {
  const drawn = drawnArchiveUrl({
    connection: drawnCase.connection,
    saved: drawnCase.saved,
    archiveUrl: ARCHIVE_URL,
    offlineArchiveUrl: OFFLINE_ARCHIVE_URL
  })
  deepStrictEqual(drawn, drawnCase.drawn, `drawn archive: ${drawnCase.name}`)
}

{
  const drawn = drawnArchiveUrl({connection: OFFLINE, saved: SAVED, archiveUrl: ARCHIVE_URL, offlineArchiveUrl: ""})
  deepStrictEqual(drawn, ARCHIVE_URL, "drawn archive: offline, on a page whose basemap has no extract")
}

const staleCases = [
  {name: "the current extract alone", storedPaths: [OFFLINE_ARCHIVE_URL], stale: []},
  {name: "an earlier build's extract", storedPaths: [OLDER_OFFLINE_ARCHIVE_URL, OFFLINE_ARCHIVE_URL], stale: [OLDER_OFFLINE_ARCHIVE_URL]},
  {name: "an empty store", storedPaths: [], stale: []}
]

for (const staleCase of staleCases) {
  const stale = stalePaths({keptPath: OFFLINE_ARCHIVE_URL, storedPaths: staleCase.storedPaths})
  deepStrictEqual(stale, staleCase.stale, `stale paths: ${staleCase.name}`)
}

const statusCases = [
  {
    name: "saved, kept by the browser",
    read: {saved: SAVED, persistence: PersistenceKind.granted},
    expected: {headline: "Map saved for offline use", caption: "Your browser keeps it until you remove it."}
  },
  {
    name: "saved, open to eviction",
    read: {saved: SAVED, persistence: PersistenceKind.notGranted},
    expected: {headline: "Map saved for offline use", caption: "Your browser can remove it when the device runs short of space."}
  },
  {
    name: "saved, with no answer from the browser",
    read: {saved: SAVED, persistence: PersistenceKind.unknown},
    expected: {headline: "Map saved for offline use", caption: "Your browser does not say whether it keeps it."}
  },
  {
    name: "not saved yet",
    read: {saved: NOT_SAVED, persistence: PersistenceKind.unknown},
    expected: {headline: "Map not saved yet", caption: "It's saved while you're online."}
  }
]

for (const statusCase of statusCases) {
  deepStrictEqual(statusMessage(statusCase.read), statusCase.expected, `status: ${statusCase.name}`)
}

console.log("offline basemap check passed")
