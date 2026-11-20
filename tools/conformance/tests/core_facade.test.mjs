// Checks that a function crosses the facade the shell loads the core through:
// the case writes the root layout's preload of the core's module into the
// document, imports `assets/js/core.js`, which finishes loading the module
// before its importer runs, and compares `coreVersion` with the workspace
// version in `core/Cargo.toml`.

import {beforeAll, expect, test} from "vitest"
import {server} from "vitest/browser"

const MODULE_URL = new URL("../../../priv/static/assets/core/gobusgo_core_bg.wasm", import.meta.url)
// The commands resolve a path against this package's directory.
const MANIFEST_PATH = "../../core/Cargo.toml"
const VERSION_LINE = /^version = "(\d+\.\d+\.\d+)"$/gm

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
