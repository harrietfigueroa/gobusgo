// The decoded trip paths a page draws along, read on demand from the
// snapshot's route shards. `request` names the trips wanted, `paths` gives
// every decoded path held by its key, and `onPaths` runs when files that
// arrive after a request bring paths the page did not hold. The files a
// trip needs are decided by the pure plan over the files held, and each
// fetch the plan asks for runs here.

import {assertCondition} from "./core/assert.js"
import {withTripPaths} from "./core/trip_path"
import {emptyTripPathFiles, fileFetched, manifestFetched, planTripPathFiles} from "./core/trip_path_files"
import {fetchManifestOutcome, fetchTripPathFile} from "./trip_path_fetch"

/** The most trips one request names: a journey rides a handful of trips. */
export const REQUEST_TRIP_COUNT_MAX = 32

/**
 * A reader of trip paths from the manifest at `manifestUrl`, whose own and
 * files' paths go behind `fileOrigin`. `onPaths` runs after a request, once
 * files that arrived hold paths of the trips it named.
 */
export function createTripPathReader({fileOrigin, manifestUrl, onPaths}) {
  let files = emptyTripPathFiles()
  let held = new Map()
  let wanted = []
  let isDestroyed = false

  // Decides again which files the wanted trips need, starts their fetches,
  // and keeps the paths the held files serve; the count of paths kept.
  function plan() {
    const planned = planTripPathFiles({files, cache: held, trips: wanted, nowMs: performance.now()})
    files = planned.files

    if (planned.manifest.ask) {
      fetchManifest(planned.manifest.etag)
    }

    for (const file of planned.fetches) {
      fetchFile(file)
    }

    if (planned.paths.length > 0) {
      held = withTripPaths(held, planned.paths)
    }

    return planned.paths.length
  }

  function settled() {
    if (isDestroyed) {
      return
    }

    const keptCount = plan()

    if (keptCount > 0) {
      onPaths()
    }
  }

  async function fetchManifest(etag) {
    const outcome = await fetchManifestOutcome({url: fileOrigin + manifestUrl, etag})

    if (isDestroyed) {
      return
    }

    files = manifestFetched({files, outcome, nowMs: performance.now()})
    settled()
  }

  async function fetchFile(file) {
    const outcome = await fetchTripPathFile({origin: fileOrigin, file})

    if (isDestroyed) {
      return
    }

    files = fileFetched({files, fetch: file, outcome, nowMs: performance.now()})
    settled()
  }

  return {
    // Names the trips, each `{tripId, routeId, serviceDateMs}`, whose paths
    // are wanted in place of the last request's, and starts the fetches they
    // need. A path already held is in `paths` on return.
    request(trips) {
      assertCondition(trips.length <= REQUEST_TRIP_COUNT_MAX, "trip path reader: a request names at most " + REQUEST_TRIP_COUNT_MAX + " trips, not " + trips.length)
      wanted = trips
      plan()
    },

    // Every decoded path held, by `tripPathKey`.
    paths() {
      return held
    },

    destroy() {
      isDestroyed = true
      wanted = []
    }
  }
}
