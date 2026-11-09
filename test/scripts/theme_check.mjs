// Checks the theme's pure functions against cases written out by hand: the
// setting a stored value names, the theme each setting resolves to on a
// light and on a dark system, the basemap flavor of each theme, the route
// line casing of each theme, and the line that says what Match system
// resolves to. Run it with `node test/scripts/theme_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {
  CasingKind,
  flavorName,
  mapColors,
  parseSetting,
  resolveTheme,
  settingStatusText,
  Theme,
  ThemeSetting
} from "../../assets/js/theme.js"

const parseCases = [
  {stored: "light", setting: ThemeSetting.light},
  {stored: "dark", setting: ThemeSetting.dark},
  {stored: "system", setting: ThemeSetting.system},
  {stored: null, setting: ThemeSetting.system},
  {stored: "sepia", setting: ThemeSetting.system},
  {stored: "", setting: ThemeSetting.system}
]

const resolveCases = [
  {setting: ThemeSetting.light, systemDark: false, theme: Theme.light},
  {setting: ThemeSetting.light, systemDark: true, theme: Theme.light},
  {setting: ThemeSetting.dark, systemDark: false, theme: Theme.dark},
  {setting: ThemeSetting.dark, systemDark: true, theme: Theme.dark},
  {setting: ThemeSetting.system, systemDark: false, theme: Theme.light},
  {setting: ThemeSetting.system, systemDark: true, theme: Theme.dark}
]

const flavorCases = [
  {theme: Theme.light, flavor: "light"},
  {theme: Theme.dark, flavor: "dark"}
]

// Each theme cases a route line, and strokes a marker, in a color that
// stands apart from its basemap's land: dark on the light map, light on the
// dark one.
const casingCases = [
  {theme: Theme.light, casing: {kind: CasingKind.casing, color: "#334155"}},
  {theme: Theme.dark, casing: {kind: CasingKind.casing, color: "#e2e8f0"}}
]

const strokeCases = [
  {theme: Theme.light, stroke: "#334155"},
  {theme: Theme.dark, stroke: "#e2e8f0"}
]

const statusCases = [
  {setting: ThemeSetting.system, theme: Theme.dark, text: "Your system is set to dark, so the page is dark."},
  {setting: ThemeSetting.system, theme: Theme.light, text: "Your system is set to light, so the page is light."},
  {setting: ThemeSetting.dark, theme: Theme.dark, text: ""},
  {setting: ThemeSetting.light, theme: Theme.light, text: ""}
]

for (const {stored, setting} of parseCases) {
  deepStrictEqual(parseSetting(stored), setting, `the setting stored as ${JSON.stringify(stored)}`)
}

for (const {setting, systemDark, theme} of resolveCases) {
  deepStrictEqual(resolveTheme({setting, systemDark}), theme, `${setting} on a system that prefers dark: ${systemDark}`)
}

for (const {theme, flavor} of flavorCases) {
  deepStrictEqual(flavorName(theme), flavor, `the flavor of the ${theme} theme`)
}

for (const {theme, casing} of casingCases) {
  deepStrictEqual(mapColors(theme).routeCasing, casing, `the route casing of the ${theme} theme`)
}

for (const {theme, stroke} of strokeCases) {
  deepStrictEqual(mapColors(theme).vehicleStroke, stroke, `the marker stroke of the ${theme} theme`)
}

for (const {setting, theme, text} of statusCases) {
  deepStrictEqual(settingStatusText({setting, theme}), text, `the status of ${setting} in the ${theme} theme`)
}

console.log("theme check passed")
