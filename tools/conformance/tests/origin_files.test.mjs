// Checks the guard of the runs made by hand against a site: the manifest and
// the snapshot files pass, and a path that leaves the snapshots through a dot
// segment, an escaped one, another origin, a query, or a fragment does not.

import {describe, expect, test} from "vitest"
import {isAllowedPath} from "../origin_files.mjs"

const ORIGIN = "https://example.test"

const allowedPaths = [
  {name: "the manifest", path: "/api/routing/manifest"},
  {name: "a snapshot file", path: "/routing/snapshots/dt=2026-11-14/stops-ab12.bin"}
]

const refusedPaths = [
  {name: "a dot segment out of the snapshots", path: "/routing/snapshots/../../admin"},
  {name: "an escaped dot segment", path: "/routing/snapshots/%2e%2e/%2e%2e/admin"},
  {name: "an escaped slash", path: "/routing/snapshots/..%2f..%2fadmin"},
  {name: "another origin", path: "//elsewhere.test/routing/snapshots/stops.bin"},
  {name: "a query", path: "/api/routing/manifest?x=1"},
  {name: "a fragment", path: "/api/routing/manifest#x"},
  {name: "another path", path: "/api/routing/other"}
]

describe("origin files", () => {
  test.each(allowedPaths)("allowed: $name", ({path}) => {
    expect(isAllowedPath({path, origin: ORIGIN})).toBe(true)
  })

  test.each(refusedPaths)("refused: $name", ({path}) => {
    expect(isAllowedPath({path, origin: ORIGIN})).toBe(false)
  })
})
