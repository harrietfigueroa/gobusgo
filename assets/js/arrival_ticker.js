// The clock that has a page write its arrivals again between the server's
// events: a tick every COUNTDOWN_INTERVAL_MS while the page is visible,
// none while it is hidden, and one at once when it is shown again.

import {COUNTDOWN_INTERVAL_MS} from "./arrival_countdown"

/**
 * Calls `onTick(nowMs)`, with the time in Unix milliseconds, at once and
 * then every COUNTDOWN_INTERVAL_MS while the page is visible. Returns the
 * function that stops it.
 */
export function startArrivalTicker(onTick) {
  const ticker = {timer: null}
  const tick = () => { onTick(Date.now()) }

  const follow = () => {
    const isRunning = ticker.timer !== null

    if (document.hidden) {
      window.clearInterval(ticker.timer)
      ticker.timer = null
    } else if (isRunning === false) {
      tick()
      ticker.timer = window.setInterval(tick, COUNTDOWN_INTERVAL_MS)
    }
  }

  document.addEventListener("visibilitychange", follow)
  follow()

  return () => {
    document.removeEventListener("visibilitychange", follow)
    window.clearInterval(ticker.timer)
    ticker.timer = null
  }
}
