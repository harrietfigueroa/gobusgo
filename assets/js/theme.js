// The page's color theme as pure functions: the rider's setting, the theme
// it resolves to on a system that prefers dark or light, the basemap flavor
// and sprites a theme draws, and the colors of the layers the hooks add to
// the map. Nothing here reads storage, a media query, or the document.

/** The rider's choices: a theme of its own, or the one the system prefers. */
export const ThemeSetting = Object.freeze({light: "light", dark: "dark", system: "system"})

/** The themes a page is drawn in. */
export const Theme = Object.freeze({light: "light", dark: "dark"})

/** The kinds of a route line's casing: none, or a casing in one color. */
export const CasingKind = Object.freeze({none: "none", casing: "casing"})

// The colors of the layers the hooks add, per theme. On the dark map a
// route's own color can be as dark as the land under it, so its line gets
// a light casing, and the stops and the labels turn light on dark.
const lightMapColors = Object.freeze({
  routeCasing: {kind: CasingKind.none},
  stopFill: "#ffffff",
  stopStroke: "#334155",
  stopLabel: "#334155",
  stopHalo: "#ffffff",
  vehicleStroke: "#ffffff",
  vehicleLabel: "#0f172a",
  vehicleHalo: "#ffffff",
  tripCasing: "#ffffff",
  tripWalk: "#475569",
  tripOrigin: "#16a34a",
  tripDestination: "#dc2626"
})

const darkMapColors = Object.freeze({
  routeCasing: {kind: CasingKind.casing, color: "#e2e8f0"},
  stopFill: "#1e293b",
  stopStroke: "#e2e8f0",
  stopLabel: "#e2e8f0",
  stopHalo: "#0f172a",
  vehicleStroke: "#e2e8f0",
  vehicleLabel: "#e2e8f0",
  vehicleHalo: "#0f172a",
  tripCasing: "#e2e8f0",
  tripWalk: "#cbd5e1",
  tripOrigin: "#22c55e",
  tripDestination: "#f87171"
})

const settings = Object.values(ThemeSetting)

/**
 * The setting `stored` names, the value storage holds or null. A missing or
 * unknown value is Match system, the default.
 */
export function parseSetting(stored) {
  if (settings.includes(stored)) {
    return stored
  } else {
    return ThemeSetting.system
  }
}

/**
 * The theme of `setting` on a system whose preference for dark is
 * `systemDark`.
 */
export function resolveTheme({setting, systemDark}) {
  const isSystemDark = setting === ThemeSetting.system && systemDark

  if (setting === ThemeSetting.dark) {
    return Theme.dark
  } else if (isSystemDark) {
    return Theme.dark
  } else {
    return Theme.light
  }
}

/**
 * The name of the vendored basemap flavor for `theme`, which is also the
 * name of the vendored sprites drawn with it.
 */
export function flavorName(theme) {
  if (theme === Theme.dark) {
    return "dark"
  } else {
    return "light"
  }
}

/** The colors of the layers the hooks add to a map drawn in `theme`. */
export function mapColors(theme) {
  if (theme === Theme.dark) {
    return darkMapColors
  } else {
    return lightMapColors
  }
}

/**
 * The line under the setting that says what Match system resolves to, and
 * nothing for a theme the rider chose.
 */
export function settingStatusText({setting, theme}) {
  if (setting !== ThemeSetting.system) {
    return ""
  } else if (theme === Theme.dark) {
    return "Your system is set to dark, so the page is dark."
  } else {
    return "Your system is set to light, so the page is light."
  }
}
