// The screen the service worker answers a page it cannot fetch with. It is
// drawn in the rider's theme: the stored setting where the page has stored
// one, and the system's preference otherwise. The key and the texts its
// script accepts are the stored settings module's.

import {STORED_THEMES, StorageKey} from "./stored_settings.js"

const storedThemesList = JSON.stringify(STORED_THEMES)

/** The HTML document of the offline screen. */
export const OFFLINE_SCREEN = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Gobusgo is offline</title>
<script>
try {
  var setting = localStorage.getItem(${JSON.stringify(StorageKey.theme)});
  if (${storedThemesList}.indexOf(setting) !== -1) {
    document.documentElement.dataset.theme = setting;
  }
} catch (error) {}
</script>
<style>
:root { color-scheme: light; --fill: #ffffff; --text: #0f172a; --accent: #16a34a; --surface: #f0f9ff; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { color-scheme: dark; --fill: #0f172a; --text: #e2e8f0; --accent: #22c55e; --surface: #0f1a24; }
}
:root[data-theme="dark"] { color-scheme: dark; --fill: #0f172a; --text: #e2e8f0; --accent: #22c55e; --surface: #0f1a24; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: var(--fill); color: var(--text); font: 16px/1.5 system-ui, sans-serif; }
main { max-width: 28rem; margin: 16px; padding: 24px; background: var(--surface); border: 1px solid var(--accent); border-radius: 8px; }
h1 { margin: 0 0 12px; font-size: 1.25rem; }
button { margin-top: 8px; padding: 6px 16px; font: inherit; font-weight: 600; color: inherit; background: transparent; border: 1px solid var(--accent); border-radius: 8px; }
</style>
</head>
<body>
<main>
<h1>Gobusgo is offline</h1>
<p>Gobusgo needs a network to show vehicles, stops, and arrivals, and this device has none right now.</p>
<p>Schedules saved for offline use stay saved on this device. The map opens again once you are back online.</p>
<button type="button" onclick="location.reload()">Try again</button>
</main>
</body>
</html>
`
