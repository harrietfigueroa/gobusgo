// Checks that a function crosses the core's WebAssembly binding: it calls
// `coreVersion` through the JavaScript loader and compares the answer with
// the workspace version in the manifest at `MANIFEST_URL`. Node cannot fetch
// a `file:` address, so the module's bytes are handed to the loader's
// synchronous initialization. Run it with `node test/scripts/core_binding_check.mjs`
// after `mix gobusgo.assets.core`; it exits non-zero and names what differs.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {initSync, coreVersion} from "../../priv/static/assets/core/gobusgo_core.js"

const MODULE_URL = new URL("../../priv/static/assets/core/gobusgo_core_bg.wasm", import.meta.url)
const MANIFEST_URL = new URL("../../core/Cargo.toml", import.meta.url)
const VERSION_LINE = /^version = "(\d+\.\d+\.\d+)"$/gm

const manifest = readFileSync(MANIFEST_URL, "utf8")
const versionMatches = Array.from(manifest.matchAll(VERSION_LINE))
assert.equal(versionMatches.length, 1, "core/Cargo.toml holds one version line, its workspace's")
const manifestVersion = versionMatches[0][1]

const moduleBytes = readFileSync(MODULE_URL)
initSync({module: moduleBytes})

const bindingVersion = coreVersion()
assert.equal(bindingVersion, manifestVersion, "coreVersion() differs from core/Cargo.toml")

console.log(`The WebAssembly binding answers core version ${bindingVersion}.`)
