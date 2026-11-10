// The rules of the map saved for offline use: the basemap's offline
// extract, the copy of its lower zooms that the rider's setting saves.
// Everything here is pure: whether the extract is stored, the page's
// connection state, and the browser's answers are given as values, and
// nothing here touches a store or the network.
//
// The map draws the full archive while the page is connecting or live, and
// the saved extract while it is offline, so a rider online sees every zoom
// and a rider offline sees the streets the extract holds, enlarged past its
// highest zoom. A page whose extract is not stored draws the full archive
// in every state, and offline that draws an empty background.

import {assertCondition, unreachable} from "./assert.js"
import {ConnectionKind} from "./connection_rules.js"
import {PersistenceKind} from "./offline_bundle.js"

const MEGABYTE_BYTES = 1000 * 1000

/** The Cache API store of the saved map, which the service worker reads and never deletes. */
export const OFFLINE_BASEMAP_CACHE_NAME = "gobusgo-offline-basemap-v1"

/** The DOM event on the window that announces a change of what is saved, with the read of the store as `detail.saved`. */
export const CHANGE_EVENT_NAME = "gobusgo:offline-basemap-change"

/** The kinds of a read of the saved map: the extract at `url` is stored, or none is. */
export const BasemapSaveKind = Object.freeze({saved: "saved", notSaved: "notSaved"})

/** The kinds of the setting's state: off, on, or a browser that cannot save the map. */
export const SettingKind = Object.freeze({off: "off", on: "on", unsupported: "unsupported"})

const NOT_SAVED = Object.freeze({kind: BasemapSaveKind.notSaved})

/** The read of the saved map for the extract at `url`, which the store holds where `isStored`. */
export function savedBasemapOf({url, isStored}) {
  assertCondition(typeof url === "string", "offline basemap: the extract's address is not a text: " + String(url))

  if (isStored) {
    return Object.freeze({kind: BasemapSaveKind.saved, url})
  }

  return NOT_SAVED
}

/**
 * The address of the archive the map draws: `offlineArchiveUrl`, the
 * page's extract or the empty string where its basemap has none, while
 * `connection` is offline and `saved` holds that extract, and otherwise
 * `archiveUrl`, the full archive.
 */
export function drawnArchiveUrl({connection, saved, archiveUrl, offlineArchiveUrl}) {
  assertCondition(typeof archiveUrl === "string", "offline basemap: the archive's address is not a text: " + String(archiveUrl))
  const isOffline = connection.kind === ConnectionKind.offline
  const isSaved = saved.kind === BasemapSaveKind.saved
  const isPageExtract = isSaved && saved.url === offlineArchiveUrl
  const drawsExtract = isOffline && isPageExtract

  if (drawsExtract) {
    return offlineArchiveUrl
  }

  return archiveUrl
}

/** The paths a store holds other than `keptPath`, the extract a save keeps, which can go. */
export function stalePaths({keptPath, storedPaths}) {
  const stale = []

  for (const path of storedPaths) {
    if (path !== keptPath) {
      stale.push(path)
    }
  }

  return stale
}

function persistenceText(kind) {
  switch (kind) {
    case PersistenceKind.granted:
      return "Your browser keeps it until you remove it."
    case PersistenceKind.notGranted:
      return "Your browser can remove it when the device runs short of space."
    case PersistenceKind.unknown:
      return "Your browser does not say whether it keeps it."
    default:
      return unreachable(kind, "persistence kind")
  }
}

function sizeText(bytes) {
  assertCondition(Number.isSafeInteger(bytes), "offline basemap: the stored size is not an integer: " + String(bytes))
  const megabytes = bytes / MEGABYTE_BYTES
  return megabytes.toFixed(1) + " MB"
}

const OFF_MESSAGE = Object.freeze({headline: "Map not saved", caption: "Turn this on to keep streets and places offline."})
const NOT_SAVED_MESSAGE = Object.freeze({headline: "Map not saved yet", caption: "It's saved while you're online."})
const UNSUPPORTED_MESSAGE = Object.freeze({headline: "Can't save the map", caption: "This browser can't save it for offline use."})

function onMessage({saved, bytes, persistence}) {
  switch (saved.kind) {
    case BasemapSaveKind.saved:
      return {headline: "Map saved for offline use", caption: `It takes ${sizeText(bytes)}. ${persistenceText(persistence)}`}
    case BasemapSaveKind.notSaved:
      return NOT_SAVED_MESSAGE
    default:
      return unreachable(saved.kind, "basemap save kind")
  }
}

/**
 * The headline and caption of the setting's status line for `setting`:
 * off; on, with the read of the store, the bytes it holds, and the
 * browser's answer to keeping the page's storage; or unsupported.
 */
export function statusMessage(setting) {
  switch (setting.kind) {
    case SettingKind.off:
      return OFF_MESSAGE
    case SettingKind.on:
      return onMessage(setting)
    case SettingKind.unsupported:
      return UNSUPPORTED_MESSAGE
    default:
      return unreachable(setting.kind, "offline basemap setting kind")
  }
}
