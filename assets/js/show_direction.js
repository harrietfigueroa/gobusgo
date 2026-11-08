// The Show my direction setting of the Settings tab. The checkbox is the
// setting, kept through the stored settings module and on by default; a
// change announces itself on the window, and turning it on is a click of
// its own, in which Safari on iOS asks for the motion permission.

import {requestMotionPermission} from "./motion_permission"
import {storedSettings} from "./stored_settings"

/** The DOM event on the window that carries the setting after a change, as `detail.isShown`. */
export const CHANGE_EVENT_NAME = "gobusgo:show-direction-change"

/** Whether Show my direction is on. */
export function isDirectionShown() {
  return storedSettings.readShowDirection()
}

function storeShown(isShown) {
  storedSettings.writeShowDirection(isShown)
}

export const ShowDirection = {
  mounted() {
    this.checkbox = this.el.querySelector("input[type=checkbox]")
    this.checkbox.checked = isDirectionShown()
    this.onChange = () => { this.changed() }
    this.checkbox.addEventListener("change", this.onChange)
  },

  // The request comes before the announcement, so it stays inside the
  // click's activation.
  changed() {
    const isShown = this.checkbox.checked
    storeShown(isShown)

    if (isShown) {
      requestMotionPermission()
    }

    window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {isShown}}))
  },

  destroyed() {
    this.checkbox.removeEventListener("change", this.onChange)
  }
}
