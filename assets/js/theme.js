// The page's color theme as pure functions: the rider's setting, the theme
// it resolves to on a system that prefers dark or light, the basemap flavor
// and sprites a theme draws, the color the browser draws its own bars in,
// and the colors of the layers the hooks add to the map. Nothing here reads
// storage, a media query, or the document. The bars' colors come from the
// imported JSON file, which code outside the bundle can read as well.

import themeColors from "./theme_colors.json" with {type: "json"}

/** The rider's choices: a theme of its own, or the one the system prefers. */
export const ThemeSetting = Object.freeze({light: "light", dark: "dark", system: "system"})

/** The themes a page is drawn in. */
export const Theme = Object.freeze({light: "light", dark: "dark"})

/** The kinds of a route line's casing: none, or a casing in one color. */
export const CasingKind = Object.freeze({none: "none", casing: "casing"})

/** How opaque a regional dot's stroke is: whole, or as faded as its dot. */
export const StrokeOpacityKind = Object.freeze({full: "full", marker: "marker"})

// The colors of the layers the hooks add, per theme. A route's own color
// can be as light as the land of the light map or as dark as the land of
// the dark one, so its line gets a casing, and a marker a stroke, in a
// color that stands apart from the land: dark on the light map, light on
// the dark one. On the light map every vehicle marker's edge is that dark
// color at full opacity, a faded dot's stroke, a live glyph's outline, and a
// route badge's border included, whatever the route's color; on the dark
// map a dot's stroke fades with its dot. A stop's sign is dark on the light map
// and light on the dark one, outlined in the other, and so is its arrow.
const lightMapColors = Object.freeze({
  routeCasing: {kind: CasingKind.casing, color: "#334155"},
  stopSignFill: "#0f172a",
  stopSignInk: "#ffffff",
  chipCountFill: "#e2e8f0",
  chipCountInk: "#0f172a",
  vehicleStroke: "#334155",
  vehicleStrokeOpacity: StrokeOpacityKind.full,
  glyphLiveOutline: "#334155",
  routeBadgeBorder: "#334155",
  badgeInk: "#0f172a",
  badgePaper: "#ffffff",
  tripCasing: "#ffffff",
  tripWalk: "#475569",
  tripOrigin: "#16a34a",
  tripDestination: "#dc2626"
})

const darkMapColors = Object.freeze({
  routeCasing: {kind: CasingKind.casing, color: "#e2e8f0"},
  stopSignFill: "#e2e8f0",
  stopSignInk: "#0f172a",
  chipCountFill: "#334155",
  chipCountInk: "#e2e8f0",
  vehicleStroke: "#e2e8f0",
  vehicleStrokeOpacity: StrokeOpacityKind.marker,
  glyphLiveOutline: "#ffffff",
  routeBadgeBorder: "#ffffff",
  badgeInk: "#e2e8f0",
  badgePaper: "#0f172a",
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

/**
 * The color of the `theme-color` meta element for a page drawn in `theme`:
 * the theme's page background, which the browser draws its status bar and
 * overscroll in.
 */
export function themeColor(theme) {
  if (theme === Theme.dark) {
    return themeColors.dark
  } else {
    return themeColors.light
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
