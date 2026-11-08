// Which install offer a page shows, as pure functions over what the browser
// reports: whether the page runs as an installed app, whether the browser
// has handed over an install prompt, and the platform its user agent names.
// Nothing here reads the browser.
//
// Safari has no install prompt, so on Apple platforms the offer says where
// Safari's own menu adds the page: Share › Add to Home Screen on an iPhone
// or iPad, in any browser there, and File › Add to Dock in Safari on a Mac.
// https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable — checked 2026-11-08
// https://webkit.org/blog/17333/webkit-features-in-safari-26-0/ — checked 2026-11-08

import {unreachable} from "./assert.js"

/** The offers: none, as in an installed app or a browser that installs nothing, the browser's prompt, or Safari's menus. */
export const InstallOfferKind = Object.freeze({
  installed: "installed",
  prompt: "prompt",
  appleHomeScreen: "appleHomeScreen",
  appleDock: "appleDock",
  none: "none"
})

/** The platforms whose offer differs. */
export const PlatformKind = Object.freeze({appleMobile: "appleMobile", appleDesktopSafari: "appleDesktopSafari", other: "other"})

const APPLE_MOBILE_PATTERN = /\b(?:iPhone|iPad|iPod)\b/
const MACINTOSH_PATTERN = /\bMacintosh\b/
const SAFARI_PATTERN = /\bSafari\//
// Chromium browsers, Firefox, and Opera on a Mac name Safari in their user
// agent too, and each names itself beside it, headless Chrome as
// HeadlessChrome.
const OTHER_BROWSER_PATTERN = /(?:Chrome|Chromium|CriOS|Edg|EdgiOS|Firefox|FxiOS|OPR)\//
const TOUCH_POINTS_MIN = 2

/**
 * The platform of a browser whose user agent is `userAgent` and whose
 * screen takes `maxTouchPoints` touches. An iPad asks for the desktop site
 * with a Mac's user agent, and a Mac has no touch screen.
 */
export function platformOf({userAgent, maxTouchPoints}) {
  const isMacintosh = MACINTOSH_PATTERN.test(userAgent)
  const isTouchMacintosh = isMacintosh && maxTouchPoints >= TOUCH_POINTS_MIN

  if (APPLE_MOBILE_PATTERN.test(userAgent)) {
    return PlatformKind.appleMobile
  }

  if (isTouchMacintosh) {
    return PlatformKind.appleMobile
  }

  const isSafari = SAFARI_PATTERN.test(userAgent) && !OTHER_BROWSER_PATTERN.test(userAgent)
  const isMacintoshSafari = isMacintosh && isSafari

  if (isMacintoshSafari) {
    return PlatformKind.appleDesktopSafari
  }

  return PlatformKind.other
}

/**
 * The offer of a page that runs as an installed app when `standalone`, in a
 * browser that has handed over an install prompt when `promptAvailable`, on
 * `platform`.
 */
export function installOffer({standalone, promptAvailable, platform}) {
  if (standalone) {
    return InstallOfferKind.installed
  }

  if (promptAvailable) {
    return InstallOfferKind.prompt
  }

  switch (platform) {
    case PlatformKind.appleMobile:
      return InstallOfferKind.appleHomeScreen
    case PlatformKind.appleDesktopSafari:
      return InstallOfferKind.appleDock
    case PlatformKind.other:
      return InstallOfferKind.none
    default:
      return unreachable(platform, "install offer platform")
  }
}
