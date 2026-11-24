// The Save for offline use setting of the Settings tab. The checkbox is the
// setting, kept through the stored settings module and off by default.
// While it is on, the region's schedules are saved, and, where the element
// carries the address of the basemap's offline extract, the extract too,
// each in its own Cache API store; turning it off deletes both stores. The
// status element says what each store holds.
//
// A save never competes with the page: it starts once the page has loaded
// and the browser is idle, and runs again every 30 minutes and when the
// browser comes back online.
//
// A page that opens with the setting off deletes both stores once its
// connection is live, so a page opened offline keeps drawing from what is
// saved. Every deletion announces the map as not saved, so the map stops
// drawing a deleted extract.

import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state.js"
import {ConnectionKind} from "./connection_rules.js"
import {SettingKind, statusMessage} from "#core/offline_bundle.js"
import {appendMessage, writeMessage} from "./message"
import {savedBasemapOf} from "./offline_basemap"
import {
  announceSavedBasemap,
  deleteSavedBasemap,
  describeBasemap,
  readSavedBasemap,
  saveBasemap
} from "./offline_basemap_setting"
import {deleteSavedSchedules, describeSchedules, saveSchedules} from "./offline_schedules"
import {readPersistence, requestPersistence} from "./storage_persistence"
import {storedSettings} from "./stored_settings"

const REFRESH_INTERVAL_MS = 30 * 60 * 1000
const IDLE_TIMEOUT_MS = 10 * 1000
// The address of no extract, the archive a page whose basemap has none
// names.
const NO_ARCHIVE_URL = ""

function isSupported() {
  return "caches" in window
}

function isEnabled() {
  return storedSettings.readOfflineUseEnabled()
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
    this.archiveUrl = archiveUrlOf(this.el)
    this.controller = null
    this.timer = null
    this.persistence = null
    this.onConnectionChange = null

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
    const isBusyOrOff = isRunning || isOff

    if (isBusyOrOff) {
      return
    }

    this.controller = new AbortController()
    const signal = this.controller.signal

    try {
      await saveSchedules(signal)
      const isMapDue = this.hasArchive() && !signal.aborted

      if (isMapDue) {
        await saveBasemap({url: this.archiveUrl, signal})
      }
    } finally {
      this.controller = null
    }

    if (this.hasArchive()) {
      const saved = await readSavedBasemap(this.archiveUrl)
      announceSavedBasemap(saved)
    }

    await this.show()
  },

  stop() {
    if (this.controller !== null) {
      this.controller.abort()
    }
  },

  async clear() {
    this.stop()

    try {
      await deleteSavedSchedules()
      await deleteSavedBasemap()
    } catch (error) {
      console.warn("Offline use stores not deleted", error)
    }

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

  async show() {
    if (!isEnabled()) {
      writeMessage({element: this.status, message: statusMessage({kind: SettingKind.off})})
      return
    }

    try {
      const persistence = await this.persistenceAnswer()
      const schedulesMessage = await describeSchedules(persistence)
      let mapMessage = null

      if (this.hasArchive()) {
        mapMessage = await describeBasemap({url: this.archiveUrl, persistence})
      }

      writeMessage({element: this.status, message: schedulesMessage})

      if (mapMessage !== null) {
        appendMessage({element: this.status, message: mapMessage})
      }
    } catch (error) {
      console.warn("Offline use status not read", error)
    }
  }
}
