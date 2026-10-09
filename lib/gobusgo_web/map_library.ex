defmodule GobusgoWeb.MapLibrary do
  @package_name "maplibre-gl"
  @entry_file "maplibre-gl.mjs"
  @built_path "/assets/vendor"

  @moduledoc """
  Where a page loads the map library, `#{@package_name}`, from. The library's
  files are served from a directory that names the library's version, so the
  address of a file never holds another version's content. Everything here
  is pure.

  The version is the one the lock file of the vendored packages pins, read
  when this module is compiled.
  """

  alias Gobusgo.Assert
  alias Gobusgo.VendorAssets.Lock

  @lock_path Path.expand("../../assets/vendor.lock.json", __DIR__)
  @external_resource @lock_path

  {:ok, lock} = @lock_path |> File.read!() |> Lock.decode()
  {:ok, %{version: version}} = Lock.fetch_package(lock, @package_name)
  @version version

  @doc "Returns the version of the library in use."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Returns the name of the directory that holds the library's files at
  `version`, inside the directory of the built vendored files.
  """
  @spec directory(String.t()) :: String.t()
  def directory(version) do
    Assert.condition(
      Lock.valid_version?(version),
      "version must be a version number, got: #{inspect(version)}"
    )

    "#{@package_name}-#{version}"
  end

  @doc "Returns the address of the file a page imports to load the library at `version`."
  @spec url(String.t()) :: String.t()
  def url(version), do: "#{@built_path}/#{directory(version)}/#{@entry_file}"
end
