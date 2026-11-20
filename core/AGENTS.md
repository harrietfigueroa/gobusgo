# Rust core

`core/` is the Cargo workspace GOB-419 ports the logic of `assets/js/core/` into, so the web page and the native iOS and Android apps run one library. It holds three crates: `gobusgo-core`, the logic itself, and its two bindings, `gobusgo-core-wasm` for the web and `gobusgo-core-ffi` for Swift and Kotlin. Each crate exports one placeholder function, `core_version`, the version of the core a binding was built from.

## Rules

- **Pure, synchronous, no IO.** `gobusgo-core` takes values and returns values: it reads no file, clock, or network, holds no handle, and starts no work that finishes later. A query is a `start` and `resume` pair that a platform's driver calls with the files it fetched, as `assets/js/core/AGENTS.md` describes for the JavaScript.
- **No third-party crate in the core.** A platform's driver expands the gzip files with the zlib or `DecompressionStream` it already ships and hands the core the expanded bytes. The bindings take one crate each, wasm-bindgen and uniffi, the only way to reach each platform.
- **A binding holds no logic.** Each export converts its arguments and result across its binding and calls `gobusgo-core`.
- **A programmer error crashes with a message.** The workspace's lints in `Cargo.toml` deny `unwrap`, `expect`, a bare `panic!`, and the implicit panics of indexing, slicing, and arithmetic, so a failure goes through `assert!` or `unreachable!` with a message at the site. The release profile aborts on a panic and checks overflow.
- **wasm-bindgen moves in lockstep.** The crate is pinned exactly in `Cargo.toml`, and the command that reads its output in `mise.toml` and as the `Dockerfile`'s `WASM_BINDGEN_VERSION`; the three change together.

## Files

- `Cargo.toml`: the workspace, its shared dependencies, its lints, and its release profile.
- `rust-toolchain.toml`: the one pin of the compiler, its components, and the `wasm32-unknown-unknown` target; the `Dockerfile`'s `RUST_VERSION` changes with it.
- `clippy.toml`: the lints' allowances inside tests.
- `gobusgo-core/`: the logic.
- `gobusgo-core-wasm/`: the wasm-bindgen binding, built as a `cdylib` for the web and an `rlib` for its native tests.
- `gobusgo-core-ffi/`: the uniffi binding, built as a `cdylib` for Android, a `staticlib` for iOS, and an `rlib` for its native tests.

## Build

`mix gobusgo.assets.core`, the first step of `mix assets.build` and `mix assets.deploy`, builds `gobusgo-core-wasm` for `wasm32-unknown-unknown` in release and runs `wasm-bindgen --target web` over it, writing `priv/static/assets/core/gobusgo_core.js` and `priv/static/assets/core/gobusgo_core_bg.wasm`. The loader is an ES module whose default initialization fetches the WebAssembly from beside its own address. Measured on 2026-11-13: the module is 37,476 bytes, and the image is 93,841 bytes larger than without the core.

## Checks

From `core/`, as CI's `core` job runs them:

```sh
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked --release --package gobusgo-core-wasm --target wasm32-unknown-unknown
```

`node test/scripts/core_binding_check.mjs`, after `mix gobusgo.assets.core`, calls `coreVersion` through the web loader and compares it with the workspace's version; CI's `assets` job runs it.
