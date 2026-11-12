// What an MCP app does with the frame the host renders it in: it takes the
// host's theme as the stylesheet's `data-theme`, and it tells the host how
// tall it is so the host can size the frame.

import {HostMethod, ThemeKind, themeOf} from "./mcp_host.js"

/** Sets the stylesheet's theme to the one `hostContext`, a context or the part of one the host changed, names. */
export function applyTheme(hostContext) {
  const theme = themeOf(hostContext)

  if (theme.kind === ThemeKind.named) {
    document.documentElement.dataset.theme = theme.theme
  }
}

/** Tells `host` the size of `body` now and whenever it changes. */
export function reportSize({host, body}) {
  const observer = new ResizeObserver(() => {
    host.notify({method: HostMethod.sizeChanged, params: {width: Math.ceil(body.scrollWidth), height: Math.ceil(body.scrollHeight)}})
  })

  observer.observe(body)
}
