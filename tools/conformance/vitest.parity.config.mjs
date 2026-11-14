// Runs the parity harness, by hand only: every implementation of the core
// answers the same journey queries over the routing snapshot a published
// site serves, and the answers must agree. The site's origin comes from
// GOBUSGO_FILE_ORIGIN, the variable a local run already uses for the same
// files. The test server fetches the files, so a browser's cross-origin rules
// play no part, and it fetches only the manifest and the snapshot files.
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {fileURLToPath} from "node:url"
import {playwright} from "@vitest/browser-playwright"
import {defineConfig} from "vitest/config"
import {assertCondition} from "../../assets/js/core/assert.js"

const REPOSITORY_ROOT = fileURLToPath(new URL("../..", import.meta.url))
const ORIGIN_VARIABLE = "GOBUSGO_FILE_ORIGIN"
const MANIFEST_PATH = "/api/routing/manifest"
const SNAPSHOT_PATH_PREFIX = "/routing/snapshots/"
const FETCH_TIMEOUT_MS = 30_000
// A date's files are under 40, so the cache holds every file of one date.
const CACHED_FILE_COUNT_MAX = 64
// A query over a date not yet fetched waits on several megabytes from the site.
const QUERY_TIMEOUT_MS = 120_000
const HTTP_OK = 200

const fileOrigin = originOf(process.env[ORIGIN_VARIABLE])
const cached = new Map()

function originOf(value) {
  const isSet = value !== undefined
  assertCondition(isSet, `the parity harness needs ${ORIGIN_VARIABLE}, the origin of a site that publishes routing snapshots`)
  const url = new URL(value)
  const isHttps = url.protocol === "https:"
  assertCondition(isHttps, `${ORIGIN_VARIABLE} is not an https origin: ${value}`)
  return url.origin
}

function isAllowedPath(path) {
  const isManifest = path === MANIFEST_PATH
  const isSnapshotFile = path.startsWith(SNAPSHOT_PATH_PREFIX)
  return isManifest || isSnapshotFile
}

// The bytes of `path` on the site, as base64, since a command's answer is text.
async function fileFromOrigin(_context, path) {
  const isRoutingFile = isAllowedPath(path)
  assertCondition(isRoutingFile, `parity harness: ${path} is no routing file`)

  if (cached.has(path)) {
    return cached.get(path)
  }

  const signal = AbortSignal.timeout(FETCH_TIMEOUT_MS)
  const response = await fetch(fileOrigin + path, {signal, redirect: "error"})

  const isOk = response.status === HTTP_OK
  assertCondition(isOk, `parity harness: ${path} answered ${response.status}`)

  const body = await response.arrayBuffer()
  const encoded = Buffer.from(body).toString("base64")

  if (cached.size >= CACHED_FILE_COUNT_MAX) {
    const [oldestPath] = cached.keys()
    cached.delete(oldestPath)
  }

  cached.set(path, encoded)
  return encoded
}

export default defineConfig({
  server: {fs: {allow: [REPOSITORY_ROOT]}},
  test: {
    include: ["parity/**/*.parity.mjs"],
    testTimeout: QUERY_TIMEOUT_MS,
    browser: {
      enabled: true,
      provider: playwright(),
      headless: true,
      instances: [{browser: "chromium"}, {browser: "firefox"}, {browser: "webkit"}],
      commands: {fileFromOrigin}
    }
  }
})
