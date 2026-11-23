// Checks what crosses the facade the shell loads the core through: the case
// writes a preload of the core's module into the document, as the root layout
// does, and imports the facade. `coreVersion` is compared with the one version
// line of the workspace's manifest, and each export of the routing snapshot
// reader with the JavaScript module's export of the same name, a decoder by
// its records of the shared fixture of its file.

import {beforeAll, expect, test} from "vitest"
import {server} from "vitest/browser"
import * as javascriptSnapshot from "../../../assets/js/core/routing_snapshot.js"
import {fixtureBytes} from "../fixtures.mjs"

const MODULE_URL = new URL("../../../priv/static/assets/core/gobusgo_core_bg.wasm", import.meta.url)
// The commands resolve a path against this package's directory.
const MANIFEST_PATH = "../../core/Cargo.toml"
const VERSION_LINE = /^version = "(\d+\.\d+\.\d+)"$/gm
const SNAPSHOT_DIRECTORY = "routing/v2/"
const SNAPSHOT_CONSTANTS = ["DecodeKind", "RefusalReason", "FORMAT_VERSION", "POSITION_UNKNOWN_MICRODEGREES"]
const SNAPSHOT_DECODERS = [
  {decoder: "decodeStops", file: "stops"},
  {decoder: "decodeTrips", file: "trips"},
  {decoder: "decodeTransfers", file: "transfers"},
  {decoder: "decodeConnections", file: "connections"},
  {decoder: "decodePositions", file: "positions"}
]

let facade = null

beforeAll(async () => {
  const preload = document.createElement("link")
  preload.rel = "preload"
  preload.as = "fetch"
  preload.type = "application/wasm"
  preload.href = MODULE_URL.href
  preload.dataset.coreModule = ""
  document.head.append(preload)
  facade = await import("../../../assets/js/core.js")
})

test("coreVersion crosses the facade as the workspace's version", async () => {
  const manifest = await server.commands.readFile(MANIFEST_PATH, {encoding: "utf-8"})
  const versionMatches = Array.from(manifest.matchAll(VERSION_LINE))

  expect(versionMatches).toHaveLength(1)
  expect(facade.coreVersion()).toBe(versionMatches[0][1])
})

test.for(SNAPSHOT_CONSTANTS)("%s crosses the facade as the JavaScript module's", (name) => {
  expect(javascriptSnapshot).toHaveProperty(name)
  expect(facade[name]).toStrictEqual(javascriptSnapshot[name])
})

test.for(SNAPSHOT_DECODERS)("$decoder through the facade decodes as the JavaScript module's", async ({decoder, file}) => {
  const bytes = await fixtureBytes(SNAPSHOT_DIRECTORY + file + ".bin")
  const expected = javascriptSnapshot[decoder](bytes)
  const decoded = facade[decoder](bytes)

  expect(expected.kind).toBe(javascriptSnapshot.DecodeKind.decoded)
  expect(decoded).toStrictEqual(expected)
})
