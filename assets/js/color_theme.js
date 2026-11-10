// Keeps the page in the theme the rider's setting resolves to. The setting
// is kept by the stored settings module, and the
// theme is the `data-theme` attribute of the document's root element, which
// the root layout's head first sets before the page is drawn, with the
// content of the document's one `theme-color` meta element, which the
// browser draws its status bar and overscroll in. A change of the theme is
// announced on the window with the "gobusgo:theme-change" event, whose
// detail holds the theme.

import {assertCondition} from "./assert"
import {parseSetting, resolveTheme, settingStatusText, Theme, themeColor} from "./theme"
import {storedSettings} from "./stored_settings"

const DARK_QUERY = "(prefers-color-scheme: dark)"
const THEME_COLOR_SELECTOR = "meta[name=\"theme-color\"]"

export const CHANGE_EVENT_NAME = "gobusgo:theme-change"

function storedSetting() {
  return storedSettings.readTheme()
}

function systemDark() {
  return window.matchMedia(DARK_QUERY).matches
}

/** The theme the page is drawn in now. */
export function currentTheme() {
  if (document.documentElement.dataset.theme === Theme.dark) {
    return Theme.dark
  } else {
    return Theme.light
  }
}

function writeThemeColor(theme) {
  const metas = document.querySelectorAll(THEME_COLOR_SELECTOR)
  assertCondition(metas.length === 1, `the document must hold one theme-color meta element, got: ${metas.length}`)
  const color = themeColor(theme)
  metas[0].setAttribute("content", color)
}

// Draws the page in the theme `setting` resolves to, and announces it when
// it is another theme than the page had.
function applySetting(setting) {
  const theme = resolveTheme({setting, systemDark: systemDark()})
  const isChanged = theme !== currentTheme()
  document.documentElement.dataset.theme = theme
  writeThemeColor(theme)

  if (isChanged) {
    window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {theme}}))
  }
}

function applyStoredSetting() {
  const setting = storedSetting()
  applySetting(setting)
}

/**
 * Applies the stored setting, and applies it again whenever the system's
 * preference changes while the page is open, which changes the theme of
 * Match system.
 */
export function followSystemTheme() {
  applyStoredSetting()
  window.matchMedia(DARK_QUERY).addEventListener("change", applyStoredSetting)
}

function writeStatus(element) {
  const status = element.querySelector("[data-theme-status]")
  const setting = storedSetting()
  status.textContent = settingStatusText({setting, theme: currentTheme()})
}

// The hook of the theme setting, a group of radio buttons named by their
// values. It checks the stored setting, stores and applies the one the
// rider checks, and says what Match system resolves to. It sends the
// server no event.
export const ColorTheme = {
  mounted() {
    const setting = storedSetting()

    for (const input of this.el.querySelectorAll("input[type=radio]")) {
      input.checked = input.value === setting
    }

    writeStatus(this.el)

    this.el.addEventListener("change", (event) => {
      const chosen = parseSetting(event.target.value)
      storedSettings.writeTheme(chosen)
      applySetting(chosen)
      writeStatus(this.el)
    })

    this.onThemeChange = () => { writeStatus(this.el) }
    window.addEventListener(CHANGE_EVENT_NAME, this.onThemeChange)
  },

  destroyed() {
    window.removeEventListener(CHANGE_EVENT_NAME, this.onThemeChange)
  }
}
