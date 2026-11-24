// The test server's command that fetches a published site's routing files
// for a case running in a browser, for the runs made by hand against a site:
// the parity harness and the decode measurement. The site's origin comes from
// GOBUSGO_FILE_ORIGIN, the variable a local run already uses for the same
// files. The test server fetches the files, so a browser's cross-origin rules
// play no part, and it fetches only the manifest and the snapshot files.
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {assertCondition} from "../../assets/js/core/assert.js"

const ORIGIN_VARIABLE = "GOBUSGO_FILE_ORIGIN"
const MANIFEST_PATH = "/api/routing/manifest"
const SNAPSHOT_PATH_PREFIX = "/routing/snapshots/"
const FETCH_TIMEOUT_MS = 30_000
// A date's files are under 40, so the cache holds every file of one date.
const CACHED_FILE_COUNT_MAX = 64
const HTTP_OK = 200

const cached = new Map()
let fileOrigin = null

function originOf(value) {
  const isSet = value !== undefined
  assertCondition(isSet, `a run against a site needs ${ORIGIN_VARIABLE}, the origin of a site that publishes routing snapshots`)
  const url = new URL(value)
  const isHttps = url.protocol === "https:"
  assertCondition(isHttps, `${ORIGIN_VARIABLE} is not an https origin: ${value}`)
  return url.origin
}

/**
 * Whether `path` names the manifest or a snapshot file on the site at
 * `origin`, judged on the address it resolves to: it must resolve on that
 * origin to itself, with no dot segment for the parser to remove, no
 * percent-escape for a server to decode, no query, and no fragment.
 */
export function isAllowedPath({path, origin}) {
  const url = new URL(path, origin)
  const isSameOrigin = url.origin === origin
  const isResolvedPath = url.pathname === path
  const isUnescaped = !path.includes("%")
  const isPlainPath = isResolvedPath && isUnescaped
  const isRoutingAddress = isSameOrigin && isPlainPath
  const isManifest = url.pathname === MANIFEST_PATH
  const isSnapshotFile = url.pathname.startsWith(SNAPSHOT_PATH_PREFIX)
  const isRoutingFile = isManifest || isSnapshotFile
  return isRoutingAddress && isRoutingFile
}

/** The origin of the site the runs fetch from, which the environment must name. */
export function siteOrigin() {
  if (fileOrigin === null) {
    fileOrigin = originOf(process.env[ORIGIN_VARIABLE])
  }

  return fileOrigin
}

/** The bytes of `path` on the site, as base64, since a command's answer is text. */
export async function fileFromOrigin(_context, path) {
  const origin = siteOrigin()
  const isRoutingFile = isAllowedPath({path, origin})
  assertCondition(isRoutingFile, `origin files: ${path} is no routing file`)

  if (cached.has(path)) {
    return cached.get(path)
  }

  const signal = AbortSignal.timeout(FETCH_TIMEOUT_MS)
  const address = new URL(path, origin)
  const response = await fetch(address, {signal, redirect: "error"})

  const isOk = response.status === HTTP_OK
  assertCondition(isOk, `origin files: ${path} answered ${response.status}`)

  const body = await response.arrayBuffer()
  const encoded = Buffer.from(body).toString("base64")

  if (cached.size >= CACHED_FILE_COUNT_MAX) {
    const [oldestPath] = cached.keys()
    cached.delete(oldestPath)
  }

  cached.set(path, encoded)
  return encoded
}
