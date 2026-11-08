import {FilterKind, storedSettings} from "./stored_settings"

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
// filter the page turns down is removed.
export const VehicleFilter = {
  mounted() {
    this.handleEvent(STORE_EVENT_NAME, storeFilter)

    if (this.el.dataset.supplied === "false") {
      const stored = storedSettings.readVehicleFilter()

      if (stored.kind === FilterKind.found) {
        this.pushEvent(RESTORE_EVENT_NAME, {filter: stored.filter}, removeRefused)
      }
    }
  }
}
