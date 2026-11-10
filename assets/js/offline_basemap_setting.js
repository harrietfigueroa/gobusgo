// The Save the map for offline use setting of the Settings tab. The
// checkbox is the setting, kept through the stored settings module and off
// by default. While it is on, the basemap's offline extract, whose address
// the element carries, is saved whole in its own Cache API store, apart
// from the offline schedules, and turning it off deletes that store. Each
// change of what is saved is announced on the window, which the Basemap
// hook reads to choose the archive it draws.
//
// A save never competes with the page: it starts once the page has loaded
// and the browser is idle, fetches the one file at low priority, and runs
// again when the browser comes back online. The Cache API stores a response
// whole or not at all, so a save that stops part way stores nothing.

import {
  CHANGE_EVENT_NAME,
  OFFLINE_BASEMAP_CACHE_NAME,
  SettingKind,
  savedBasemapOf,
  stalePaths,
  statusMessage
} from "./offline_basemap"
import {writeMessage} from "./message"
import {requestPersistence} from "./storage_persistence"
import {storedSettings} from "./stored_settings"

const IDLE_TIMEOUT_MS = 10 * 1000

function isSupported() {
  return "caches" in window
}

function pathOf(request) {
  return new URL(request.url).pathname
}

/**
 * A read of the saved map for the extract at `url`, which reads the
 * browser's store alone and so answers offline. A match with a cache name
 * opens no cache, so a read never makes the store the setting deleted.
 */
export async function readSavedBasemap(url) {
  if (!isSupported()) {
    return savedBasemapOf({url, isStored: false})
  }

  const response = await caches.match(url, {cacheName: OFFLINE_BASEMAP_CACHE_NAME})
  return savedBasemapOf({url, isStored: response !== undefined})
}

function announce(saved) {
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {saved}}))
}

// Stores the extract at `url` unless the store holds it, then deletes every
// other copy, an earlier build's extract.
async function save({url, signal}) {
  const cache = await caches.open(OFFLINE_BASEMAP_CACHE_NAME)
  const stored = await cache.match(url)

  if (stored === undefined) {
    const response = await fetch(url, {signal, priority: "low"})

    if (!response.ok) {
      console.warn("Offline map not saved", url, response.status)
      return
    }

    await cache.put(url, response)
  }

  const requests = await cache.keys()
  const storedPaths = Array.from(requests, pathOf)
  const stale = stalePaths({keptPath: url, storedPaths})

  for (const path of stale) {
    await cache.delete(path)
  }
}

async function storedBytes(url) {
  const response = await caches.match(url, {cacheName: OFFLINE_BASEMAP_CACHE_NAME})

  if (response === undefined) {
    return 0
  }

  const blob = await response.blob()
  return blob.size
}

export const OfflineBasemap = {
  mounted() {
    this.checkbox = this.el.querySelector("input[type=checkbox]")
    this.status = this.el.querySelector("[data-offline-status]")
    this.url = this.el.dataset.archiveUrl
    this.controller = null
    this.persistence = null

    if (!isSupported()) {
      this.checkbox.checked = false
      this.checkbox.disabled = true
      writeMessage({element: this.status, message: statusMessage({kind: SettingKind.unsupported})})
      return
    }

    this.checkbox.checked = storedSettings.readOfflineBasemapEnabled()
    this.onChange = () => { this.changed() }
    this.onOnline = () => { this.start() }
    this.checkbox.addEventListener("change", this.onChange)
    window.addEventListener("online", this.onOnline)
    this.show()
    this.whenIdle()
  },

  destroyed() {
    if (this.onOnline !== undefined) {
      window.removeEventListener("online", this.onOnline)
      this.checkbox.removeEventListener("change", this.onChange)
    }

    this.stop()
  },

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

  // The persistence request comes first, so it stays inside the click's
  // activation.
  changed() {
    const enabled = this.checkbox.checked
    storedSettings.writeOfflineBasemapEnabled(enabled)

    if (enabled) {
      this.persistence = requestPersistence()
      this.start()
    } else {
      this.clear()
    }
  },

  async start() {
    const isRunning = this.controller !== null
    const isOff = !storedSettings.readOfflineBasemapEnabled()
    const isBusyOrOff = isRunning || isOff

    if (isBusyOrOff) {
      await this.removeWhenOff()
      return
    }

    this.controller = new AbortController()

    try {
      await save({url: this.url, signal: this.controller.signal})
    } catch (error) {
      if (error.name !== "AbortError") {
        console.warn("Offline map not saved", error)
      }
    } finally {
      this.controller = null
    }

    const saved = await readSavedBasemap(this.url)
    announce(saved)
    await this.show()
  },

  // A copy saved while the setting was on, which a lost setting leaves
  // behind, goes on the next page.
  async removeWhenOff() {
    const isOff = !storedSettings.readOfflineBasemapEnabled()

    if (isOff) {
      await caches.delete(OFFLINE_BASEMAP_CACHE_NAME)
    }
  },

  stop() {
    if (this.controller !== null) {
      this.controller.abort()
    }
  },

  async clear() {
    this.stop()
    await caches.delete(OFFLINE_BASEMAP_CACHE_NAME)
    const saved = savedBasemapOf({url: this.url, isStored: false})
    announce(saved)
    await this.show()
  },

  async show() {
    const isOff = !storedSettings.readOfflineBasemapEnabled()

    if (isOff) {
      writeMessage({element: this.status, message: statusMessage({kind: SettingKind.off})})
      return
    }

    try {
      if (this.persistence === null) {
        this.persistence = requestPersistence()
      }

      const persistence = await this.persistence
      const saved = await readSavedBasemap(this.url)
      const bytes = await storedBytes(this.url)
      const message = statusMessage({kind: SettingKind.on, saved, bytes, persistence})
      writeMessage({element: this.status, message})
    } catch (error) {
      console.warn("Offline map status not read", error)
    }
  }
}
