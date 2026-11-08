const STORAGE_KEY = "gobusgo:vehicle-filter"
const STORE_EVENT_NAME = "vehicle-filter:store"
const RESTORE_EVENT_NAME = "vehicle-filter:restore"

// The kinds of a read of the stored filter.
const StoredKind = Object.freeze({found: "found", none: "none"})

// The filter this browser stored, or none when it stored none. Reading
// throws where storage is blocked, such as a private window, and parsing
// throws for text that is not JSON; both read as nothing stored, and the
// page then shows what its address says.
function readStored() {
  let filter

  try {
    const text = window.localStorage.getItem(STORAGE_KEY)

    if (text === null) {
      return {kind: StoredKind.none}
    }

    filter = JSON.parse(text)
  } catch (error) {
    console.warn("Stored vehicle filter not readable", error)
    return {kind: StoredKind.none}
  }

  if (filter === null) {
    return {kind: StoredKind.none}
  } else {
    return {kind: StoredKind.found, filter}
  }
}

function writeStored(filter) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(filter))
  } catch (error) {
    console.warn("Vehicle filter not stored", error)
  }
}

function removeStored() {
  try {
    window.localStorage.removeItem(STORAGE_KEY)
  } catch (error) {
    console.warn("Stored vehicle filter not removed", error)
  }
}

function storeFilter({filter}) {
  writeStored(filter)
}

function removeRefused({accepted}) {
  if (!accepted) {
    removeStored()
  }
}

function isDetailsOpen(details) {
  return details.open
}

// Keeps the filter of the vehicle page in this browser. The page says
// which filter to store, after a change of its controls. A page whose
// address supplies no filter is offered the stored one, and a stored
// filter the page turns down is removed.
export const VehicleFilter = {
  mounted() {
    this.detailsOpen = []
    this.handleEvent(STORE_EVENT_NAME, storeFilter)

    if (this.el.dataset.supplied === "false") {
      const stored = readStored()

      if (stored.kind === StoredKind.found) {
        this.pushEvent(RESTORE_EVENT_NAME, {filter: stored.filter}, removeRefused)
      }
    }
  },

  // The server's markup never holds the `open` attribute, so an update
  // closes each list unless its state is carried across. The lists keep
  // their order, so a list is known by its place.
  beforeUpdate() {
    this.detailsOpen = Array.from(this.el.querySelectorAll("details"), isDetailsOpen)
  },

  updated() {
    let index = 0

    for (const details of this.el.querySelectorAll("details")) {
      details.open = this.detailsOpen[index] === true
      index += 1
    }
  }
}
