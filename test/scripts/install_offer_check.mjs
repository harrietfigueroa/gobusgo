// Checks the install offer's pure functions against cases written out by
// hand: the platform of real user agents, and the offer each combination of
// an installed app, an install prompt, and a platform gets. Run it with
// `node test/scripts/install_offer_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {InstallOfferKind, PlatformKind, installOffer, platformOf} from "../../assets/js/install_offer.js"

const platformCases = [
  {
    name: "Safari on an iPhone",
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
    maxTouchPoints: 5,
    platform: PlatformKind.appleMobile
  },
  {
    name: "Chrome on an iPhone",
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.0.0 Mobile/15E148 Safari/604.1",
    maxTouchPoints: 5,
    platform: PlatformKind.appleMobile
  },
  {
    name: "Safari on an iPad, which asks for the desktop site",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
    maxTouchPoints: 5,
    platform: PlatformKind.appleMobile
  },
  {
    name: "Safari on a Mac",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
    maxTouchPoints: 0,
    platform: PlatformKind.appleDesktopSafari
  },
  {
    name: "Chrome on a Mac",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    maxTouchPoints: 0,
    platform: PlatformKind.other
  },
  {
    name: "Edge on a Mac",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
    maxTouchPoints: 0,
    platform: PlatformKind.other
  },
  {
    name: "Firefox on a Mac",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0",
    maxTouchPoints: 0,
    platform: PlatformKind.other
  },
  {
    name: "Chrome on Android",
    userAgent: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
    maxTouchPoints: 5,
    platform: PlatformKind.other
  },
  {
    name: "headless Chrome",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/142.0.0.0 Safari/537.36",
    maxTouchPoints: 0,
    platform: PlatformKind.other
  }
]

const offerCases = [
  {standalone: true, promptAvailable: true, platform: PlatformKind.other, offer: InstallOfferKind.installed},
  {standalone: true, promptAvailable: false, platform: PlatformKind.appleMobile, offer: InstallOfferKind.installed},
  {standalone: false, promptAvailable: true, platform: PlatformKind.other, offer: InstallOfferKind.prompt},
  {standalone: false, promptAvailable: true, platform: PlatformKind.appleDesktopSafari, offer: InstallOfferKind.prompt},
  {standalone: false, promptAvailable: false, platform: PlatformKind.appleMobile, offer: InstallOfferKind.appleHomeScreen},
  {standalone: false, promptAvailable: false, platform: PlatformKind.appleDesktopSafari, offer: InstallOfferKind.appleDock},
  {standalone: false, promptAvailable: false, platform: PlatformKind.other, offer: InstallOfferKind.none}
]

for (const {name, userAgent, maxTouchPoints, platform} of platformCases) {
  deepStrictEqual(platformOf({userAgent, maxTouchPoints}), platform, name)
}

for (const {standalone, promptAvailable, platform, offer} of offerCases) {
  const name = `standalone: ${standalone}, prompt: ${promptAvailable}, platform: ${platform}`
  deepStrictEqual(installOffer({standalone, promptAvailable, platform}), offer, name)
}

console.log("install offer check passed")
