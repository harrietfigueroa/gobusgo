// Runs in every page and frame of a core page check before the page's own
// scripts. It keeps the map the Basemap hook announces, so the check reads
// the data of the map's sources in the page; it counts the offline
// schedules' index each save of this page writes, the save's last write,
// so the check knows when the page's save has ended; and it stores the
// favorites a scenario hands in before the page reads them.
((favorites) => {
  window.addEventListener("basemap:ready", (event) => { window.__corePagesMap = event.detail.map }, {capture: true})
  window.__corePagesIndexSaves = 0

  if (typeof Cache === "function") {
    const put = Cache.prototype.put

    Cache.prototype.put = function (request, response) {
      let url = request

      if (typeof request !== "string") {
        url = request.url
      }

      const isIndex = url.endsWith("/offline-schedules/index.json")

      return put.call(this, request, response).then((result) => {
        if (isIndex) {
          window.__corePagesIndexSaves += 1
        }

        return result
      })
    }
  }

  if (favorites.length > 0) {
    window.localStorage.setItem("gobusgo:stored-settings-version", "1")
    window.localStorage.setItem("gobusgo:favorite-stops", JSON.stringify(favorites))
  }
})(FAVORITES)
