// The install section of the Settings tab. It shows the one offer
// `installOffer` picks: the install button where the browser has handed
// over its prompt, Safari's menu on Apple platforms, and nothing in an
// installed app or a browser that installs nothing.
//
// The browser hands over its prompt with `beforeinstallprompt`, which can
// fire before the hook mounts, so this module keeps it from the moment the
// page's script runs, and announces each change with OFFER_CHANGE_EVENT.

import {InstallOfferKind, installOffer, platformOf} from "./install_offer.js"

const OFFER_CHANGE_EVENT = "gobusgo:install-offer-change"
const STANDALONE_QUERY = "(display-mode: standalone)"

let deferredPrompt = null

function announce() {
  window.dispatchEvent(new CustomEvent(OFFER_CHANGE_EVENT))
}

function promptHandedOver(event) {
  event.preventDefault()
  deferredPrompt = event
  announce()
}

function appInstalled() {
  deferredPrompt = null
  announce()
}

window.addEventListener("beforeinstallprompt", promptHandedOver)
window.addEventListener("appinstalled", appInstalled)

// Safari on iOS reports an app opened from the Home Screen with
// `navigator.standalone`, and every browser with the display mode.
function isStandalone(standaloneQuery) {
  if (standaloneQuery.matches) {
    return true
  }

  return navigator.standalone === true
}

export const InstallApp = {
  mounted() {
    this.offers = this.el.querySelectorAll("[data-install-kind]")
    this.button = this.el.querySelector("[data-install-button]")
    this.standaloneQuery = window.matchMedia(STANDALONE_QUERY)
    this.platform = platformOf({userAgent: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints})
    this.onChange = () => this.show()
    this.onClick = () => this.install()
    window.addEventListener(OFFER_CHANGE_EVENT, this.onChange)
    this.standaloneQuery.addEventListener("change", this.onChange)
    this.button.addEventListener("click", this.onClick)
    this.show()
  },

  destroyed() {
    window.removeEventListener(OFFER_CHANGE_EVENT, this.onChange)
    this.standaloneQuery.removeEventListener("change", this.onChange)
  },

  show() {
    const offer = installOffer({
      standalone: isStandalone(this.standaloneQuery),
      promptAvailable: deferredPrompt !== null,
      platform: this.platform
    })
    const isInstalled = offer === InstallOfferKind.installed
    const isHidden = isInstalled || offer === InstallOfferKind.none

    this.el.hidden = isHidden

    for (const element of this.offers) {
      element.hidden = element.dataset.installKind !== offer
    }
  },

  // A prompt can be shown once, so it is dropped before it is shown.
  async install() {
    const prompt = deferredPrompt

    if (prompt === null) {
      return
    }

    deferredPrompt = null

    try {
      await prompt.prompt()
    } catch (error) {
      console.warn("Install prompt not shown", error)
    }

    announce()
  }
}
