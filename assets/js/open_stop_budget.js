// The room the page has for stops held open for the server, as pure
// functions of the stops in play. The server keeps a bounded count of stops
// open for one page, room for every favorite and for every popup that opens
// by itself, so a stop the details view holds apart from those takes the
// place of one such popup.

// The zoom from which a screen holds few enough stops that their popups
// open by themselves and stand apart.
export const AUTO_OPEN_ZOOM_MIN = 16

// The most stops on screen whose popups open by themselves, out of
// `countMax`, while the details view holds `detailStopId`, or null for no
// stop. A stop the view holds is in that room already when it is on screen,
// among `visibleStopIds`, where its own popup opens or none does, or when
// it is one of `favoriteStopIds`; any other takes one place.
export function autoOpenCountMax({countMax, detailStopId, visibleStopIds, favoriteStopIds}) {
  if (detailStopId === null) {
    return countMax
  }

  const isVisible = visibleStopIds.includes(detailStopId)
  const isHeldElsewhere = isVisible || favoriteStopIds.includes(detailStopId)

  if (isHeldElsewhere) {
    return countMax
  } else {
    return countMax - 1
  }
}
