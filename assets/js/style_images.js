// The images the hooks draw for the map's layers when a layer first asks
// for them. A map takes one resolver of missing images, which MapLibre
// awaits before it hands a tile its images, so each hook registers its own
// resolver here under a key, and the map's one resolver asks each in turn.
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#setmissingstyleimageresolver — checked 2026-11-09

const resolversByMap = new WeakMap()

/**
 * Has `resolve(id)` draw the missing images of `map` that it knows, under
 * `key`, in place of the resolver registered under that key before. A
 * resolver adds the image it draws with `map.addImage` and leaves any other
 * name alone.
 */
export function registerImageResolver({map, key, resolve}) {
  let resolvers = resolversByMap.get(map)

  if (resolvers === undefined) {
    resolvers = new Map()
    resolversByMap.set(map, resolvers)
    const registered = resolvers

    map.setMissingStyleImageResolver((id) => {
      for (const each of registered.values()) {
        each(id)
      }
    })
  }

  resolvers.set(key, resolve)
}
