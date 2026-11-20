// The core for the shell: the Rust core's WebAssembly, loaded once with a
// top-level await, so a module importing this one runs only once the core is
// ready. Each export carries the name of the JavaScript core's export it
// stands in for, so a caller moves to the Rust core by its import path alone.
//
// The module is fetched from the address of the document's preload of it,
// which the server writes under the file's digested name, so the fetch here
// takes the response the preload started. A document with no preload, or a
// module that fails to load, rejects this module and every module importing
// it.

import initialize from "../../priv/static/assets/core/gobusgo_core.js"
import {assertCondition} from "#core/assert.js"

export {coreVersion} from "../../priv/static/assets/core/gobusgo_core.js"

const MODULE_PRELOAD_SELECTOR = "link[rel=preload][data-core-module]"
const MODULE_FETCH_TIMEOUT_MS = 20 * 1000

const preload = document.querySelector(MODULE_PRELOAD_SELECTOR)
assertCondition(preload !== null, "core: the document must preload the core's module")
const signal = AbortSignal.timeout(MODULE_FETCH_TIMEOUT_MS)
// The request a preload without `crossorigin` makes, `no-cors` with credentials
// included, so the browser hands it the preload's response; WebKit hands one
// to no other mode. The module is of this origin, so the response is readable,
// and streaming compilation takes it.
const response = fetch(preload.href, {mode: "no-cors", credentials: "include", signal})
await initialize({module_or_path: response})
