// The stops the page has open for the server, and what in the page holds
// each one: a stop's popup, the favorite stop's panel, or both. The page
// registers an open stop in the demand registry once however many hold it,
// so a stop is closed for the server only when its last holder lets go.

export const popupHolder = "popup"
export const favoriteHolder = "favorite"

const openEventName = "stop-arrivals:open"
const closeEventName = "stop-arrivals:close"

// The holders of each open stop, by stop identifier.
const holdersByStop = new Map()

// Holds a stop for `holder` and tells the page, which answers with the
// stop's arrivals. A stop opened again is answered again, so a holder that
// comes to a stop another holds gets the arrivals too.
export function holdStop({pushEvent, stopId, holder}) {
  let holders = holdersByStop.get(stopId)

  if (holders === undefined) {
    holders = new Set()
    holdersByStop.set(stopId, holders)
  }

  holders.add(holder)
  pushEvent(openEventName, {stop_id: stopId})
}

// Lets go of a stop for `holder`, and closes it for the page once no holder
// is left.
export function releaseStop({pushEvent, stopId, holder}) {
  const holders = holdersByStop.get(stopId)

  if (holders === undefined || holders.delete(holder) === false) {
    return
  }

  if (holders.size === 0) {
    holdersByStop.delete(stopId)
    pushEvent(closeEventName, {stop_id: stopId})
  }
}

// Whether `holder` holds the stop.
export function holdsStop({stopId, holder}) {
  const holders = holdersByStop.get(stopId)
  return holders !== undefined && holders.has(holder)
}
