// Checks the service worker's pure functions against cases written out by
// hand: the strategy each kind of request gets, the cache names of a
// release, and the caches an activating worker deletes. Run it with
// `node test/scripts/service_worker_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {BUNDLE_MANIFEST_PATH} from "../../assets/js/offline_bundle.js"
import {CacheRole, StrategyKind, cacheNames, requestStrategy, staleCacheNames} from "../../assets/js/service_worker_strategy.js"

const ORIGIN = "https://gobusgo.example"
const precachePaths = ["/assets/js/app-0123.js", "/assets/css/app-4567.css", "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl.mjs"]

const strategyCases = [
  {
    name: "a digested script the worker stored, with the digest's query",
    request: {method: "GET", url: ORIGIN + "/assets/js/app-0123.js?vsn=d", mode: "no-cors"},
    strategy: {kind: StrategyKind.precached, path: "/assets/js/app-0123.js"}
  },
  {
    name: "a module file of the map library",
    request: {method: "GET", url: ORIGIN + "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl.mjs", mode: "cors"},
    strategy: {kind: StrategyKind.precached, path: "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl.mjs"}
  },
  {
    name: "a script of an earlier release",
    request: {method: "GET", url: ORIGIN + "/assets/js/app-89ab.js?vsn=d", mode: "no-cors"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a glyph range of the basemap's fonts",
    request: {method: "GET", url: ORIGIN + "/vendor/basemaps-assets/fonts/Noto%20Sans%20Regular/0-255.pbf", mode: "cors"},
    strategy: {kind: StrategyKind.basemapAsset, path: "/vendor/basemaps-assets/fonts/Noto%20Sans%20Regular/0-255.pbf"}
  },
  {
    name: "the basemap's sprite",
    request: {method: "GET", url: ORIGIN + "/vendor/basemaps-assets/sprites/v4/light.json", mode: "cors"},
    strategy: {kind: StrategyKind.basemapAsset, path: "/vendor/basemaps-assets/sprites/v4/light.json"}
  },
  {
    name: "the routing manifest, with the bundle's own copy before the latest one",
    request: {method: "GET", url: ORIGIN + "/api/routing/manifest", mode: "cors"},
    strategy: {
      kind: StrategyKind.networkFirst,
      path: "/api/routing/manifest",
      fallbacks: [
        {cache: CacheRole.offlineSchedules, path: BUNDLE_MANIFEST_PATH},
        {cache: CacheRole.release, path: "/api/routing/manifest"}
      ]
    }
  },
  {
    name: "the vehicle page opened from the home screen",
    request: {method: "GET", url: ORIGIN + "/vehicles", mode: "navigate"},
    strategy: {kind: StrategyKind.navigation}
  },
  {
    name: "the vehicle page under a filter",
    request: {method: "GET", url: ORIGIN + "/vehicles?agency=1", mode: "navigate"},
    strategy: {kind: StrategyKind.navigation}
  },
  {
    name: "another page",
    request: {method: "GET", url: ORIGIN + "/agencies", mode: "navigate"},
    strategy: {kind: StrategyKind.navigation}
  },
  {
    name: "the LiveView socket",
    request: {method: "GET", url: ORIGIN + "/live/websocket?vsn=2.0.0", mode: "websocket"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a path that starts like the socket's",
    request: {method: "GET", url: ORIGIN + "/lively", mode: "navigate"},
    strategy: {kind: StrategyKind.navigation}
  },
  {
    name: "a form post",
    request: {method: "POST", url: ORIGIN + "/vehicles", mode: "navigate"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a stored path asked for with another method",
    request: {method: "HEAD", url: ORIGIN + "/assets/js/app-0123.js", mode: "no-cors"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a stored path on another origin",
    request: {method: "GET", url: "https://cdn.example/assets/js/app-0123.js", mode: "no-cors"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a range of the basemap archive",
    request: {method: "GET", url: ORIGIN + "/basemap/basemap-20261004-01.pmtiles", mode: "cors"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a routing snapshot file, from the saved bundle first",
    request: {method: "GET", url: ORIGIN + "/routing/2026-11-08/stops-abcd.bin", mode: "cors"},
    strategy: {kind: StrategyKind.savedFile, path: "/routing/2026-11-08/stops-abcd.bin"}
  },
  {
    name: "a route and stop tile archive, from the saved bundle first",
    request: {method: "GET", url: ORIGIN + "/tiles/route-stops/dt=2026-11-08/route-stops-1.pmtiles", mode: "cors"},
    strategy: {kind: StrategyKind.savedFile, path: "/tiles/route-stops/dt=2026-11-08/route-stops-1.pmtiles"}
  },
  {
    name: "a path that starts like the tiles' directory",
    request: {method: "GET", url: ORIGIN + "/tilesets", mode: "cors"},
    strategy: {kind: StrategyKind.untouched}
  },
  {
    name: "a saved path asked for with another method",
    request: {method: "HEAD", url: ORIGIN + "/routing/2026-11-08/stops-abcd.bin", mode: "cors"},
    strategy: {kind: StrategyKind.untouched}
  }
]

const current = cacheNames({release: "0123456789abcdef", basemapAssetsId: "3472c1f2963aad00"})

const staleCases = [
  {
    name: "an earlier release",
    names: [current.release, current.basemapAssets, "gobusgo-release-fedcba9876543210"],
    stale: ["gobusgo-release-fedcba9876543210"]
  },
  {
    name: "fonts and sprites of another archive",
    names: [current.release, "gobusgo-basemap-assets-0000000000000000"],
    stale: ["gobusgo-basemap-assets-0000000000000000"]
  },
  {
    name: "the offline schedules' cache, which the worker does not own",
    names: [current.release, "gobusgo-offline-schedules-v1"],
    stale: []
  },
  {
    name: "the worker's own caches",
    names: [current.release, current.basemapAssets],
    stale: []
  }
]

deepStrictEqual(
  current,
  {release: "gobusgo-release-0123456789abcdef", basemapAssets: "gobusgo-basemap-assets-3472c1f2963aad00"},
  "the cache names of a release"
)

for (const {name, request, strategy} of strategyCases) {
  deepStrictEqual(requestStrategy({...request, origin: ORIGIN, precachePaths}), strategy, name)
}

for (const {name, names, stale} of staleCases) {
  deepStrictEqual(staleCacheNames({names, current}), stale, name)
}

console.log("service worker check passed")
