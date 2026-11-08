// Keeps the page in the theme the rider's setting resolves to. The setting
// is kept in local storage, with Match system kept as no value, and the
// theme is the `data-theme` attribute of the document's root element, which
// the root layout's head first sets before the page is drawn. A change of
// the theme is announced on the window with the "gobusgo:theme-change"
// event, whose detail holds the theme.

import {parseSetting, resolveTheme, settingStatusText, Theme, ThemeSetting} from "./theme"

const SETTING_KEY = "gobusgo:theme"
const DARK_QUERY = "(prefers-color-scheme: dark)"

export const CHANGE_EVENT_NAME = "gobusgo:theme-change"

// The rider's setting. Storage that throws, as in a private window, reads
// as the default, Match system.
function storedSetting() {
  try {
    const stored = window.localStorage.getItem(SETTING_KEY)
    return parseSetting(stored)
  } catch (error) {
    console.warn("Theme setting not readable", error)
    return ThemeSetting.system
  }
}

function storeSetting(setting) {
  try {
    if (setting === ThemeSetting.system) {
      window.localStorage.removeItem(SETTING_KEY)
    } else {
      window.localStorage.setItem(SETTING_KEY, setting)
    }
  } catch (error) {
    console.warn("Theme setting not stored", error)
  }
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

// Draws the page in the theme `setting` resolves to, and announces it when
// it is another theme than the page had.
function applySetting(setting) {
  const theme = resolveTheme({setting, systemDark: systemDark()})
  const isChanged = theme !== currentTheme()
  document.documentElement.dataset.theme = theme

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
      storeSetting(chosen)
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
