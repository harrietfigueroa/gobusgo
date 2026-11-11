defmodule Gobusgo.Test.AppEnv do
  @moduledoc """
  Sets a setting of the `:gobusgo` application for the running test and
  restores it when the test exits. The setting is global, so a test that
  calls this does not run concurrently with others. Restoration runs after
  every `on_exit` callback registered later, so a callback that restarts a
  process reads the test's value.
  """

  @application :gobusgo

  @doc "Sets `key` to `value` until the test exits."
  def put(key, value) when is_atom(key) do
    case Application.fetch_env(@application, key) do
      {:ok, configured} ->
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(@application, key, configured) end)

      :error ->
        ExUnit.Callbacks.on_exit(fn -> Application.delete_env(@application, key) end)
    end

    Application.put_env(@application, key, value)
  end

  @doc """
  Points the local reader and the basemap setting at `dir`, so a process
  that discovers what is stored and a page that reads the basemap manifest
  see only what the test wrote there.
  """
  def isolate_data(dir) when is_binary(dir) do
    put(Gobusgo.Reader.LocalFile, base_dir: dir)
    put(:basemap, dir: dir)
  end
end
