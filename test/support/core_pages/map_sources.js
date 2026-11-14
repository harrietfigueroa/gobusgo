// The data of every GeoJSON source of the map the page probe kept, by
// source, or null where the page has drawn no map. A vector source names
// its archive and holds no data a core writes, so it is left out.
() => {
  const map = window.__corePagesMap

  if (map === undefined) {
    return null
  }

  const sources = {}

  for (const [id, source] of Object.entries(map.getStyle().sources)) {
    if (source.type === "geojson") {
      sources[id] = source.data
    }
  }

  return sources
}
