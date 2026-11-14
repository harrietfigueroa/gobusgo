defmodule Mix.Tasks.Gobusgo.Assets.Core do
  @shortdoc "Builds the core's WebAssembly module into the built assets"

  @moduledoc """
  Builds the WebAssembly binding of the core under `core/` and writes the
  module with its JavaScript loader into the built assets.

      mix gobusgo.assets.core

  It runs `cargo build` for the `wasm32-unknown-unknown` target in release,
  then `wasm-bindgen` over the module. Both executables have to be on the
  `PATH`: rustup installs the toolchain `core/rust-toolchain.toml` pins, and
  mise the `wasm-bindgen` version `mise.toml` pins. `mix assets.build` and
  `mix assets.deploy` run this task. It takes no arguments, does not start the
  application, and exits with a failure when either command fails.
  """

  use Mix.Task

  @workspace_dir "core"
  @crate "gobusgo-core-wasm"
  @target "wasm32-unknown-unknown"
  @module_path "core/target/wasm32-unknown-unknown/release/gobusgo_core_wasm.wasm"
  @built_dir "priv/static/assets/core"
  @out_name "gobusgo_core"

  @impl Mix.Task
  def run([]) do
    run_command(
      "cargo",
      [
        "build",
        "--locked",
        "--release",
        "--package",
        @crate,
        "--target",
        @target
      ],
      cd: @workspace_dir
    )

    # `--target web` writes an ES module a browser loads without a bundler,
    # whose default initialization fetches the WebAssembly from beside the
    # module's own address.
    # https://rustwasm.github.io/docs/wasm-bindgen/reference/deployment.html — checked 2026-11-13
    run_command(
      "wasm-bindgen",
      [
        "--target",
        "web",
        "--no-typescript",
        "--out-dir",
        @built_dir,
        "--out-name",
        @out_name,
        @module_path
      ],
      []
    )
  end

  def run(_arguments) do
    Mix.raise("mix gobusgo.assets.core takes no arguments")
  end

  defp run_command(executable, arguments, options) do
    case System.find_executable(executable) do
      nil ->
        Mix.raise("mix gobusgo.assets.core needs #{executable} on the PATH")

      path ->
        command_options =
          Keyword.merge([stderr_to_stdout: true, into: IO.stream(:stdio, :line)], options)

        case System.cmd(path, arguments, command_options) do
          {_output, 0} -> :ok
          {_output, status} -> Mix.raise("#{executable} exited with status #{status}")
        end
    end
  end
end
