// The offline signal of a map page: a chip over the map whose headline says
// the page is offline and whose caption points to the Save for offline use
// setting while it is off, and while it is on says what the map shows and
// how old the saved schedules are, and a polite live region that announces
// going offline and coming back. The stylesheet shows the chip while the
// document's root element carries `data-connection="offline"`; this hook
// writes its texts and its accessible name, again on each change of the
// setting, and opens the Settings tab at the setting on a click.

import {AGE_REFRESH_MS, AnnouncementKind, OfflineUseKind, announcementOf, signalMessage} from "./offline_signal.js"
import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state.js"
import {CHANGE_EVENT_NAME as OFFLINE_USE_CHANGE_EVENT_NAME, isSupported} from "./offline_use"
import {ConnectionKind} from "./connection_rules.js"
import {OPEN_EVENT_NAME} from "./panel_sheet"
import {readSavedIndex} from "./offline_schedules"
import {storedSettings} from "./stored_settings"

// Reads the stored setting at each write, so a change made in another tab
// is read too, and the index only while the setting is on, since the
// caption names no saved schedule otherwise.
async function readOfflineUse() {
  if (!isSupported()) {
    return {kind: OfflineUseKind.unsupported}
  }

  const isEnabled = storedSettings.readOfflineUseEnabled()

  if (!isEnabled) {
    return {kind: OfflineUseKind.off}
  }

  const savedIndex = await readSavedIndex()
  return {kind: OfflineUseKind.on, savedIndex}
}

export const ConnectionSignal = {
  mounted() {
    this.caption = this.el.querySelector("[data-signal-caption]")
    this.announcer = document.getElementById(this.el.dataset.announcerId)
    this.setting = document.getElementById(this.el.dataset.settingId)
    this.status = document.getElementById(this.el.dataset.statusId)
    this.ageTimer = null
    // Counts the writes started, so a write that ends after a later one
    // started leaves the later one's texts.
    this.writeCount = 0
    this.onChange = (event) => { this.changed(event.detail) }
    this.onOfflineUseChange = () => { this.offlineUseChanged() }
    this.onClick = () => { this.openSetting() }
    window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onChange)
    window.addEventListener(OFFLINE_USE_CHANGE_EVENT_NAME, this.onOfflineUseChange)
    this.el.addEventListener("click", this.onClick)
    this.follow(connectionState())
  },

  destroyed() {
    window.removeEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onChange)
    window.removeEventListener(OFFLINE_USE_CHANGE_EVENT_NAME, this.onOfflineUseChange)
    this.stopAge()
  },

  changed({previous, connection}) {
    const announcement = announcementOf({previous, next: connection})

    if (announcement.kind === AnnouncementKind.say) {
      this.announcer.textContent = announcement.text
    }

    this.follow(connection)
  },

  // A change of the setting while offline is written at once; otherwise the
  // next offline state writes it.
  offlineUseChanged() {
    const isOffline = connectionState().kind === ConnectionKind.offline

    if (isOffline) {
      this.write()
    }
  },

  // While offline the texts are written now and again each minute, so the
  // age stays true; otherwise nothing is written.
  follow(connection) {
    const isOffline = connection.kind === ConnectionKind.offline

    if (isOffline) {
      this.write()
      this.startAge()
    } else {
      this.stopAge()
    }
  },

  startAge() {
    if (this.ageTimer === null) {
      this.ageTimer = window.setInterval(() => { this.write() }, AGE_REFRESH_MS)
    }
  },

  stopAge() {
    if (this.ageTimer !== null) {
      window.clearInterval(this.ageTimer)
      this.ageTimer = null
    }
  },

  async write() {
    this.writeCount += 1
    const count = this.writeCount

    try {
      const offlineUse = await readOfflineUse()

      if (count !== this.writeCount) {
        return
      }

      const {caption, label} = signalMessage({offlineUse, nowMs: Date.now()})
      this.caption.textContent = caption
      this.caption.hidden = false
      this.el.setAttribute("aria-label", label)
    } catch (error) {
      console.warn("Offline signal not written", error)
    }
  },

  // Opens the Settings tab at the setting, and moves focus to its checkbox
  // so a keyboard or a press of Space continues from it; a disabled
  // checkbox takes no focus, so its status line, which says why, takes it.
  openSetting() {
    let target = this.setting

    if (this.setting.disabled) {
      target = this.status
    }

    target.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true}))
    target.scrollIntoView({block: "center"})
    target.focus({preventScroll: true})
  }
}
