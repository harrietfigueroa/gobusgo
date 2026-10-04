defmodule Mix.Tasks.Gobusgo.Vendor.Fetch do
  @shortdoc "Downloads the vendored front-end packages the lock file pins"

  @moduledoc """
  Downloads the files of the vendored front-end packages at the versions
  `assets/vendor.lock.json` pins, into `assets/vendor`, which git ignores.

      mix gobusgo.vendor.fetch

  A package whose files are present with the pinned content is left as it
  is. A tarball or a file that does not hash to the lock's value is refused,
  and the task exits with a failure. `mix assets.setup` runs this task. It
  takes no arguments and does not start the application.
  """

  use Mix.Task

  alias Gobusgo.VendorAssets

  @impl Mix.Task
  def run([]) do
    {:ok, _started} = Application.ensure_all_started(:req)

    case VendorAssets.fetch(VendorAssets.paths(), []) do
      {:ok, fetched} ->
        for %{name: name, version: version, status: status} <- fetched do
          Mix.shell().info("#{name} #{version}: #{status}")
        end

      {:error, reason} ->
        Mix.raise("vendored packages not fetched: #{inspect(reason)}")
    end
  end

  def run(_arguments) do
    Mix.raise("mix gobusgo.vendor.fetch takes no arguments")
  end
end
