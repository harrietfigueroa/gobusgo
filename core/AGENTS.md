# Rust core

`core/` is the Cargo workspace GOB-419 ports the logic of `assets/js/core/` into, so the web page and the native iOS and Android apps run one library. It holds three crates: `gobusgo-core`, the logic itself, and its two bindings, `gobusgo-core-wasm` for the web and `gobusgo-core-ffi` for Swift and Kotlin. Each exports `core_version`, the version of the core a binding was built from, and the modules ported so far: the assertions and the math of `assets/js/core/assert.js`, `assets/js/core/math/geodesy.js`, `assets/js/core/math/angles.js`, `assets/js/core/math/checks.js`, and `assets/js/core/math/interpolation.js` (GOB-425).

## Rules

- **Pure, synchronous, no IO.** `gobusgo-core` takes values and returns values: it reads no file, clock, or network, holds no handle, and starts no work that finishes later. A query is a `start` and `resume` pair that a platform's driver calls with the files it fetched, as `assets/js/core/AGENTS.md` describes for the JavaScript.
- **No third-party crate in the core.** A platform's driver expands the gzip files with the zlib or `DecompressionStream` it already ships and hands the core the expanded bytes. The bindings take one crate each, wasm-bindgen and uniffi, the only way to reach each platform.
- **A binding holds no logic.** Each export converts its arguments and result across its binding and calls `gobusgo-core`.
- **A programmer error crashes with a message.** The workspace's lints in `Cargo.toml` deny `unwrap`, `expect`, a bare `panic!`, and the implicit panics of indexing, slicing, and arithmetic, so a failure goes through `gobusgo_core::assert::condition` or `gobusgo_core::assert::unreachable` with a message at the site, as `assert.js` keeps the JavaScript's: a condition assertion writes the operand values into its message, only when it fails, and every assertion panics with one payload, `AssertionError`. `assert::number_text` writes a number as JavaScript's `String` writes it, so a failure's message reads the same from both cores. The release profile aborts on a panic and checks overflow.
- **A failure crosses the web binding as an `AssertionError`.** The binding's panic hook throws its own `AssertionError`, a JavaScript `Error` that `assertionErrorClass()` returns, with the panic's message, and asks wasm-bindgen to make the instance anew before the next call, since the throw leaves the panic unfinished. Every argument crosses as a `JsValue` and is read inside the call, through imports marked `catch`, so an exception JavaScript throws while the binding reads an argument becomes the same failure and goes through the same renewal: a number must be one, where wasm-bindgen's conversion would coerce a string or `null`, and text is read with `String`, as the JavaScript writes it into a message. No export takes a `&str`, which wasm-bindgen 0.2.130 copies into the old instance's memory before the call makes the instance anew. A native app aborts on a failure.
- **The math exists in both cores.** `assert.js` and the four modules of `math/` stay in JavaScript beside their Rust port, since the shell's per-frame motion modules call them on every frame and cross into WebAssembly on none. The conformance suite under `tools/conformance/` runs the shared cases of `test/fixtures/math/` against the JavaScript and through the WebAssembly binding in three browsers, and `cargo test` runs the same cases against `gobusgo-core`, so the two copies stay equal; a change to one is made to the other in the same commit.
- **wasm-bindgen moves in lockstep.** The crate is pinned exactly in `Cargo.toml`, and the command that reads its output in `mise.toml` and as the `Dockerfile`'s `WASM_BINDGEN_VERSION`; the three change together.

## Files

- `Cargo.toml`: the workspace, its shared dependencies, its lints, and its release profile.
- `rust-toolchain.toml`: the one pin of the compiler, its components, and the `wasm32-unknown-unknown` target; the `Dockerfile`'s `RUST_VERSION` changes with it.
- `clippy.toml`: the lints' allowances inside tests.
- `gobusgo-core/`: the logic. `core/gobusgo-core/src/assert.rs` holds the assertions, and `core/gobusgo-core/src/math/` the math, a module for each JavaScript module of `assets/js/core/math/` it ports, whose functions take an options struct where the JavaScript takes an options object or two arguments of one type. `tests/conformance/` runs the shared fixtures' cases, with a reader of the JSON they hold in `core/gobusgo-core/tests/conformance/json.rs`, since the core takes no crate.
- `gobusgo-core-wasm/`: the wasm-bindgen binding, built as a `cdylib` for the web and an `rlib` for its native tests. Each export takes the arguments of the JavaScript function of the same name, an options object read through its properties, and a constant crosses as a function, so `tools/conformance/webassembly_core.mjs` only names them.
- `gobusgo-core-ffi/`: the uniffi binding, built as a `cdylib` for Android, a `staticlib` for iOS, and an `rlib` for its native tests. Its records mirror the core's structs field for field.

## Build

`mix gobusgo.assets.core`, the first step of `mix assets.build` and `mix assets.deploy`, builds `gobusgo-core-wasm` for `wasm32-unknown-unknown` in release and runs `wasm-bindgen --target web` over it, writing `priv/static/assets/core/gobusgo_core.js` and `priv/static/assets/core/gobusgo_core_bg.wasm`. The loader is an ES module whose default initialization fetches the WebAssembly from beside its own address. Measured on 2026-11-13: the module is 37,476 bytes, and the image is 93,841 bytes larger than without the core. Measured on 2026-11-14 with the assertions and the math (GOB-425): the module wasm-bindgen writes, `gobusgo_core_bg.wasm`, is 106,684 bytes, 51,754 gzipped, up from 19,646 and 7,951 with `core_version` alone, and cargo's is 156,819, up from 37,476. `mix gobusgo.assets.core` drops the module's name and producers sections, which take 20,754 bytes of it. Writing a failure's numbers as `String` writes them takes Rust's precision formatting, about 18,900 bytes and 14,800 gzipped of the module.

## Checks

From `core/`, as CI's `core` job runs them:

```sh
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked --release --package gobusgo-core-wasm --target wasm32-unknown-unknown
```

`cargo test` runs the conformance cases of `test/fixtures/math/` that the browser suite runs. `node test/scripts/core_binding_check.mjs`, after `mix gobusgo.assets.core`, calls `coreVersion` through the web loader and compares it with the workspace's version; CI's `assets` job runs it. The conformance suite runs the binding in three browsers, after `mix gobusgo.assets.core`, as `assets/AGENTS.md` ("Checks") describes; CI's `conformance` job runs it.
