// The Save for offline use setting of the Settings tab. The checkbox is the
// setting, kept through the stored settings module and off by default.
// While it is on, the region's schedules are saved, and, where the element
// carries the address of the basemap's offline extract, the extract too,
// each in its own Cache API store; turning it off deletes both stores. The
// status element says what each store holds, and the breakdown list the size
// of each part of what they hold, hidden while they hold nothing.
//
// A save never competes with the page: it starts once the page has loaded
// and the browser is idle, and runs again every 30 minutes and when the
// browser comes back online. Each file of a save has a bound of its own,
// past which the save is aborted, so a stuck file never holds back the
// next save.
//
// A page that opens with the setting off deletes both stores once its
// connection is live, so a page opened offline keeps drawing from what is
// saved. Every deletion announces the map as not saved.

import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state.js"
import {ConnectionKind} from "./connection_rules.js"
import {OFFLINE_SCHEDULES_CACHE_NAME, SettingKind, statusMessage} from "#core/offline_bundle.js"
import {appendMessage, writeMessage} from "./message"
import {OFFLINE_BASEMAP_CACHE_NAME, savedBasemapOf} from "./offline_basemap"
import {
  announceSavedBasemap,
  deleteSavedBasemap,
  describeBasemap,
  readSavedBasemap,
  saveBasemap
} from "./offline_basemap_setting"
import {breakdownRows, offlineBreakdown} from "./offline_breakdown.js"
import {deleteSavedSchedules, describeSchedules, readSavedIndex, saveSchedules} from "./offline_schedules"
import {FILE_SAVE_MS_MAX, saveDeadlineOf} from "./save_deadline.js"
import {readPersistence, requestPersistence} from "./storage_persistence"
import {storedSettings} from "./stored_settings"

const REFRESH_INTERVAL_MS = 30 * 60 * 1000
const IDLE_TIMEOUT_MS = 10 * 1000
// The saves one start runs after its first, each asked for by a turn-off
// and turn-on while the one before was ending; more wait for the next
// refresh.
const SAVE_RESTART_COUNT_MAX = 3
// The address of no extract, the archive a page whose basemap has none
// names.
const NO_ARCHIVE_URL = ""
const STORE_NAMES = Object.freeze([OFFLINE_SCHEDULES_CACHE_NAME, OFFLINE_BASEMAP_CACHE_NAME])

function isSupported() {
  return "caches" in window
}

function isEnabled() {
  return storedSettings.readOfflineUseEnabled()
}

// A save the hook stopped ends in an AbortError, which is no failure.
function warnUnlessAborted({description, error}) {
  if (error.name !== "AbortError") {
    console.warn(description, error)
  }
}

// Deletes both stores, and never rejects, since a save waits for it.
async function deleteStores() {
  try {
    await deleteSavedSchedules()
    await deleteSavedBasemap()
  } catch (error) {
    console.warn("Offline use stores not deleted", error)
  }
}

function pathOf(request) {
  return new URL(request.url).pathname
}

// Every file the store `cacheName` holds, with its size. A store `caches.has`
// does not find is not opened, so a read after a deletion makes no store;
// a file deleted between the listing and its read is left out.
async function storedFilesOf(cacheName) {
  const hasStore = await caches.has(cacheName)
  const files = []

  if (!hasStore) {
    return files
  }

  const cache = await caches.open(cacheName)
  const requests = await cache.keys()

  for (const request of requests) {
    const response = await cache.match(request)

    if (response !== undefined) {
      const blob = await response.blob()
      files.push({cacheName, path: pathOf(request), bytes: blob.size})
    }
  }

  return files
}

async function storedFiles() {
  const files = []

  for (const cacheName of STORE_NAMES) {
    const storeFiles = await storedFilesOf(cacheName)

    for (const file of storeFiles) {
      files.push(file)
    }
  }

  return files
}

async function readBreakdownRows() {
  const savedIndex = await readSavedIndex()
  const files = await storedFiles()
  const breakdown = offlineBreakdown({savedIndex, files})
  return breakdownRows(breakdown)
}

// Writes `rows` into the list `element` as text nodes, each term and its
// definition in a group of their own, and hides the list while it holds none.
function writeRows({element, rows}) {
  element.replaceChildren()

  for (const {term, definition} of rows) {
    const group = document.createElement("div")
    const termElement = document.createElement("dt")
    termElement.textContent = term
    const definitionElement = document.createElement("dd")
    definitionElement.textContent = definition
    group.append(termElement, definitionElement)
    element.append(group)
  }

  const isEmpty = rows.length === 0
  element.toggleAttribute("hidden", isEmpty)
}

function archiveUrlOf(element) {
  const url = element.dataset.archiveUrl

  if (url === undefined) {
    return NO_ARCHIVE_URL
  }

  return url
}

export const OfflineUse = {
  mounted() {
    this.checkbox = this.el.querySelector("input[type=checkbox]")
    this.status = this.el.querySelector("[data-offline-status]")
    this.breakdown = this.el.querySelector("[data-offline-breakdown]")
    this.archiveUrl = archiveUrlOf(this.el)
    this.controller = null
    this.timer = null
    this.persistence = null
    this.onConnectionChange = null
    // A start the idle callback, the load event, or a turn-on asks for after
    // the hook is destroyed saves nothing, since no clear could stop it.
    this.isDestroyed = false
    // A start asked for while an aborted save is still ending runs once it
    // has ended.
    this.isRestartDue = false
    // The deletion of the stores a turn-off started, which a save waits for
    // so it never writes into a store about to be deleted.
    this.deletion = Promise.resolve()

    if (!isSupported()) {
      this.checkbox.checked = false
      this.checkbox.disabled = true
      writeMessage({element: this.status, message: statusMessage({kind: SettingKind.unsupported})})
      return
    }

    const enabled = isEnabled()
    this.checkbox.checked = enabled
    this.onChange = () => { this.changed() }
    this.onOnline = () => { this.start() }
    this.checkbox.addEventListener("change", this.onChange)
    window.addEventListener("online", this.onOnline)
    this.timer = window.setInterval(this.onOnline, REFRESH_INTERVAL_MS)
    this.show()

    if (enabled) {
      this.whenIdle()
    } else {
      this.clearWhenLive()
    }
  },

  destroyed() {
    this.isDestroyed = true

    if (this.onOnline !== undefined) {
      window.clearInterval(this.timer)
      window.removeEventListener("online", this.onOnline)
      this.checkbox.removeEventListener("change", this.onChange)
    }

    this.stopWaitingForLive()
    this.stop()
  },

  // Starts the first save once the page has loaded and the browser is idle.
  whenIdle() {
    const idle = () => {
      if (typeof window.requestIdleCallback === "function") {
        window.requestIdleCallback(() => { this.start() }, {timeout: IDLE_TIMEOUT_MS})
      } else {
        window.setTimeout(() => { this.start() }, 0)
      }
    }

    if (document.readyState === "complete") {
      idle()
    } else {
      window.addEventListener("load", idle, {once: true})
    }
  },

  // Deletes both stores now while the page is live, and otherwise once it
  // turns live with the setting still off.
  clearWhenLive() {
    const connection = connectionState()

    if (connection.kind === ConnectionKind.live) {
      this.clear()
      return
    }

    this.onConnectionChange = (event) => { this.connectionChanged(event.detail.connection) }
    window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onConnectionChange)
  },

  connectionChanged(connection) {
    if (connection.kind !== ConnectionKind.live) {
      return
    }

    this.stopWaitingForLive()

    if (!isEnabled()) {
      this.clear()
    }
  },

  stopWaitingForLive() {
    if (this.onConnectionChange !== null) {
      window.removeEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onConnectionChange)
      this.onConnectionChange = null
    }
  },

  // The persistence request comes first, so it stays inside the click's
  // activation.
  changed() {
    const enabled = this.checkbox.checked

    if (enabled) {
      this.persistence = requestPersistence()
      storedSettings.writeOfflineUseEnabled(enabled)
      this.stopWaitingForLive()
      this.start()
    } else {
      storedSettings.writeOfflineUseEnabled(enabled)
      this.clear()
    }
  },

  hasArchive() {
    return this.archiveUrl !== NO_ARCHIVE_URL
  },

  async start() {
    const isRunning = this.controller !== null
    const isOff = !isEnabled()

    if (this.isDestroyed) {
      return
    }

    if (isRunning) {
      // A save a turn-off aborted is still ending, so a turn-on since then
      // starts its own save once it has.
      this.isRestartDue = this.isRestartDue || this.controller.signal.aborted
      return
    }

    if (isOff) {
      return
    }

    let restartCount = 0
    let isSaveDue = true

    while (isSaveDue) {
      await this.saveOnce()
      const isRestartDue = this.isRestartDue
      this.isRestartDue = false
      const isRestartWanted = isRestartDue && isEnabled()
      const isRestartLive = isRestartWanted && !this.isDestroyed
      const isRestartWithinBound = restartCount < SAVE_RESTART_COUNT_MAX
      const isRestartPastBound = isRestartLive && !isRestartWithinBound
      isSaveDue = isRestartLive && isRestartWithinBound

      if (isRestartPastBound) {
        console.warn("Offline use restarts past their bound", {restartCount})
      }

      restartCount += 1
    }

    if (this.isDestroyed) {
      return
    }

    try {
      if (this.hasArchive()) {
        const saved = await readSavedBasemap(this.archiveUrl)
        announceSavedBasemap(saved)
      }

      await this.show()
    } catch (error) {
      warnUnlessAborted({description: "Offline use status not read", error})
    }
  },

  // One save of the schedules and then the map, each file within
  // FILE_SAVE_MS_MAX; a file past it aborts the save with a TimeoutError,
  // which the save logs, and the controller is released either way, so the
  // next start saves again.
  async saveOnce() {
    this.controller = new AbortController()
    const deadline = saveDeadlineOf({controller: this.controller, timers: window, fileMsMax: FILE_SAVE_MS_MAX})

    try {
      await this.deletion
      await saveSchedules(deadline)
      const isMapDue = this.hasArchive() && !deadline.signal.aborted

      if (isMapDue) {
        await saveBasemap({url: this.archiveUrl, deadline})
      }
    } catch (error) {
      warnUnlessAborted({description: "Offline use not saved", error})
    } finally {
      this.controller = null
    }
  },

  stop() {
    if (this.controller !== null) {
      this.controller.abort()
    }
  },

  async clear() {
    this.stop()
    this.deletion = deleteStores()
    await this.deletion
    const saved = savedBasemapOf({url: this.archiveUrl, isStored: false})
    announceSavedBasemap(saved)
    await this.show()
  },

  // The browser's answer to keeping the page's storage: the request's
  // where the rider turned the setting on in this page, and otherwise a
  // read that asks nothing.
  async persistenceAnswer() {
    if (this.persistence !== null) {
      return await this.persistence
    }

    return await readPersistence()
  },

  // The setting is read again after the reads, since the rider can turn it
  // off while they run, and the off message then stands.
  async show() {
    if (!isEnabled()) {
      this.showOff()
      return
    }

    try {
      const persistence = await this.persistenceAnswer()
      const schedulesMessage = await describeSchedules(persistence)
      let mapMessage = null

      if (this.hasArchive()) {
        mapMessage = await describeBasemap({url: this.archiveUrl, persistence})
      }

      const rows = await readBreakdownRows()

      if (!isEnabled()) {
        this.showOff()
        return
      }

      writeMessage({element: this.status, message: schedulesMessage})

      if (mapMessage !== null) {
        appendMessage({element: this.status, message: mapMessage})
      }

      writeRows({element: this.breakdown, rows})
    } catch (error) {
      console.warn("Offline use status not read", error)
    }
  },

  showOff() {
    writeMessage({element: this.status, message: statusMessage({kind: SettingKind.off})})
    writeRows({element: this.breakdown, rows: []})
  }
}
