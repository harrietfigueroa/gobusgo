defmodule GobusgoWeb.ServiceWorker do
  @archive_name "basemaps-assets"
  @basemap_assets_id_length 16
  @release_length 16

  @moduledoc """
  What the service worker is built with: the release it names its cache
  for, the paths it stores when it installs, and the content identifier of
  the basemap's fonts and sprites, `#{@archive_name}`, which names the cache
  it keeps them in. Everything here is pure; `mix gobusgo.assets.service_worker`
  reads the built files and writes the worker.

  A release is a hash of the files the worker stores when it installs, so a
  build whose stylesheet, script, and map library are unchanged is the same
  release, and any other build is another.
  """

  alias Gobusgo.Assert
  alias Gobusgo.VendorAssets.Lock
  alias GobusgoWeb.MapLibrary

  @lock_path Path.expand("../../assets/vendor.lock.json", __DIR__)
  @external_resource @lock_path

  {:ok, lock} = @lock_path |> File.read!() |> Lock.decode()
  {:ok, %{content_sha256: content_sha256}} = Lock.fetch_archive(lock, @archive_name)
  @basemap_assets_id binary_part(content_sha256, 0, @basemap_assets_id_length)

  # The files the root layout loads, by their logical names in the digest's
  # cache manifest.
  @layout_assets ["assets/css/app.css", "assets/js/app.js"]

  @typedoc """
  How the built assets are named: `{:digested, latest}` with the cache
  manifest's map from a logical name to its digested name, or `:undigested`
  for a build whose files keep their logical names.
  """
  @type digests :: {:digested, %{String.t() => String.t()}} | :undigested

  @doc """
  Returns the paths the worker stores when it installs: the stylesheet and
  the script under the names a page requests them by, and the map library's
  module files. A digest that names no stylesheet or no script raises.
  """
  @spec precache_paths(digests()) :: [String.t(), ...]
  def precache_paths(digests) do
    Enum.map(@layout_assets, &("/" <> asset_name(digests, &1))) ++
      MapLibrary.module_paths(MapLibrary.version())
  end

  defp asset_name(:undigested, logical), do: logical

  defp asset_name({:digested, latest}, logical) when is_map(latest) do
    Assert.condition(
      Map.has_key?(latest, logical),
      "the digest must name #{logical}, got: #{inspect(Map.keys(latest))}"
    )

    Map.fetch!(latest, logical)
  end

  @doc """
  Returns the release of `files`, each `{path, content}`: the first
  #{@release_length} hexadecimal digits of a SHA-256 over every path and
  content, each with its length, so content that moves between files is
  another release.
  """
  @spec release([{String.t(), binary()}, ...]) :: String.t()
  def release([_file | _rest] = files) do
    hash =
      Enum.reduce(files, :crypto.hash_init(:sha256), fn {path, content}, hash ->
        Assert.condition(is_binary(path), "path must be a string, got: #{inspect(path)}")
        Assert.condition(is_binary(content), "content of #{path} must be a binary")
        :crypto.hash_update(hash, length_prefixed(path) <> length_prefixed(content))
      end)

    hash |> :crypto.hash_final() |> Base.encode16(case: :lower) |> binary_part(0, @release_length)
  end

  defp length_prefixed(value), do: <<byte_size(value)::64>> <> value

  @doc "Returns the content identifier of the basemap's fonts and sprites the lock file pins."
  @spec basemap_assets_id() :: String.t()
  def basemap_assets_id, do: @basemap_assets_id

  @doc "Returns the object the worker is built with, under the names its source reads."
  @spec build(%{release: String.t(), precache_paths: [String.t(), ...]}) :: %{
          String.t() => term()
        }
  def build(%{release: release, precache_paths: [_path | _rest] = precache_paths})
      when is_binary(release) do
    %{
      "release" => release,
      "precachePaths" => precache_paths,
      "basemapAssetsId" => @basemap_assets_id
    }
  end
end
