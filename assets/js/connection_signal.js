// The offline signal of a map page: a chip over the map whose headline says
// the page is offline and whose caption says what the map shows and how old
// the saved schedules are, and a polite live region that announces going
// offline and coming back. The
// stylesheet shows the chip while the document's root element carries
// `data-connection="offline"`; this hook writes its texts and opens the
// Settings tab's offline section on a click.

import {AGE_REFRESH_MS, AnnouncementKind, announcementOf, signalMessage} from "./offline_signal.js"
import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state.js"
import {ConnectionKind} from "./connection_rules.js"
import {OPEN_EVENT_NAME} from "./panel_sheet"
import {readSavedIndex} from "./offline_schedules"

export const ConnectionSignal = {
  mounted() {
    this.caption = this.el.querySelector("[data-signal-caption]")
    this.announcer = document.getElementById(this.el.dataset.announcerId)
    this.section = document.getElementById(this.el.dataset.sectionId)
    this.ageTimer = null
    this.onChange = (event) => { this.changed(event.detail) }
    this.onClick = () => { this.openSection() }
    window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onChange)
    this.el.addEventListener("click", this.onClick)
    this.follow(connectionState())
  },

  destroyed() {
    window.removeEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onChange)
    this.stopAge()
  },

  changed({previous, connection}) {
    const announcement = announcementOf({previous, next: connection})

    if (announcement.kind === AnnouncementKind.say) {
      this.announcer.textContent = announcement.text
    }

    this.follow(connection)
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
    try {
      const savedIndex = await readSavedIndex()
      const {caption} = signalMessage({savedIndex, nowMs: Date.now()})
      this.caption.textContent = caption
      this.caption.hidden = false
    } catch (error) {
      console.warn("Offline signal not written", error)
    }
  },

  // Opens the Settings tab at its offline section, and moves focus there so
  // a keyboard continues from it.
  openSection() {
    this.section.dispatchEvent(new CustomEvent(OPEN_EVENT_NAME, {bubbles: true}))
    this.section.scrollIntoView({block: "start"})
    this.section.focus({preventScroll: true})
  }
}
