import {FilterKind, storedSettings} from "./stored_settings"
import {pageEvents} from "./page_events"

const STORE_EVENT_NAME = "vehicle-filter:store"
const RESTORE_EVENT_NAME = "vehicle-filter:restore"

function storeFilter({filter}) {
  storedSettings.writeVehicleFilter(filter)
}

function removeRefused({accepted}) {
  if (!accepted) {
    storedSettings.removeVehicleFilter()
  }
}

// Keeps the filter of the vehicle page in this browser. The page says
// which filter to store, after a change of its filter bar. A page whose
// address supplies no filter is offered the stored one, and a stored
// filter the page turns down is removed; offline the page accepts it as
// it is, since the filter is read-only then.
export const VehicleFilter = {
  mounted() {
    this.events = pageEvents(this)
    this.events.handle(STORE_EVENT_NAME, storeFilter)

    if (this.el.dataset.supplied === "false") {
      const stored = storedSettings.readVehicleFilter()

      if (stored.kind === FilterKind.found) {
        this.events.push({name: RESTORE_EVENT_NAME, payload: {filter: stored.filter}, onReply: removeRefused})
      }
    }
  },

  destroyed() {
    this.events.release()
  }
}
