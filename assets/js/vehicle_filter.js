const storageKey = "gobusgo:vehicle-filter"
const storeEventName = "vehicle-filter:store"
const restoreEventName = "vehicle-filter:restore"

// The filter this browser stored, or null when it stored none. Reading
// throws where storage is blocked, such as a private window, and parsing
// throws for text that is not JSON; both read as nothing stored, and the
// page then shows what its address says.
function readStored() {
  try {
    const text = window.localStorage.getItem(storageKey)
    return text === null ? null : JSON.parse(text)
  } catch (error) {
    console.warn("Stored vehicle filter not readable", error)
    return null
  }
}

function writeStored(filter) {
  try {
    window.localStorage.setItem(storageKey, JSON.stringify(filter))
  } catch (error) {
    console.warn("Vehicle filter not stored", error)
  }
}

function removeStored() {
  try {
    window.localStorage.removeItem(storageKey)
  } catch (error) {
    console.warn("Stored vehicle filter not removed", error)
  }
}

// Keeps the filter of the vehicle page in this browser. The page says
// which filter to store, after a change of its controls. A page whose
// address supplies no filter is offered the stored one, and a stored
// filter the page turns down is removed.
export const VehicleFilter = {
  mounted() {
    this.detailsOpen = false
    this.handleEvent(storeEventName, ({filter}) => writeStored(filter))

    if (this.el.dataset.supplied === "false") {
      const filter = readStored()

      if (filter !== null) {
        this.pushEvent(restoreEventName, {filter}, ({accepted}) => {
          if (!accepted) removeStored()
        })
      }
    }
  },

  // The server's markup never holds the `open` attribute, so an update
  // closes the list unless its state is carried across.
  beforeUpdate() {
    this.detailsOpen = this.el.querySelector("details").open
  },

  updated() {
    this.el.querySelector("details").open = this.detailsOpen
  }
}
