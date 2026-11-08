defmodule Gobusgo.Gbfs.VehicleTiles.Build do
  @moduledoc """
  One publication of a GBFS system's shared vehicles to the browser: the
  files of `Gobusgo.Gbfs.VehicleTileSet` for the system's current entry in
  the shared vehicle view, written through `Gobusgo.Writer`, then the index
  made current in `Gobusgo.Gbfs.VehicleTiles`. This module orchestrates;
  the files are built in `Gobusgo.Gbfs.VehicleTileSet`.

  The tiles and the whole-city file are written before the index, and the
  index is made current only once every file is written, so a current index
  never names a missing file. A destination that already exists holds the
  same content, since its name holds the content's hash, and counts as
  written. A system whose entry is a feed that is not published, or that
  has no entry, has its index dropped, so a page stops drawing it.

  `Gobusgo.Gbfs.VehicleStatusRetention` deletes the files with the fetch
  they belong to.

  ## Results and logs

    * `{:ok, %{kind: :published}}`, with the `:index` made current, the
      `:tile_count`, and the `:vehicle_count`. Logged at `debug`.
    * `{:ok, %{kind: :cleared}}`: the system's index is dropped.
    * `{:error, %{failed_count: count}}`: `count` files were not written,
      and the index current before stays current. Logged at `error` as
      `Shared vehicle tiles not written`, since a page then draws an older
      fetch until its age hides it.

  ## Options

    * `:server` (required): the `Gobusgo.Gbfs.VehicleTiles` process.
    * `:view`: the `Gobusgo.Gbfs.VehicleStatusView`, by default
      `Gobusgo.Gbfs.VehicleStatusView`.
    * `:type_view`: the fetch view of the vehicle types, by default
      `Gobusgo.Gbfs.VehicleTypeView`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
  """

  require Logger

  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.Gbfs.VehicleTiles
  alias Gobusgo.Gbfs.VehicleTileSet
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.Writer

  @type published :: %{
          kind: :published,
          index: VehicleTiles.index(),
          tile_count: non_neg_integer(),
          vehicle_count: non_neg_integer()
        }

  @doc "Publishes the current entry of `system_id` in the view."
  @spec run(String.t(), Keyword.t()) ::
          {:ok, published() | %{kind: :cleared}} | {:error, %{failed_count: pos_integer()}}
  def run(system_id, options) when is_list(options) do
    Systems.assert_id(system_id)

    options =
      Keyword.validate!(options, [
        :server,
        view: VehicleStatusView,
        type_view: Gobusgo.Gbfs.VehicleTypeView,
        write_options: []
      ])

    server = Keyword.fetch!(options, :server)

    case VehicleStatusView.current(Keyword.fetch!(options, :view), system_id) do
      %{kind: :fetched} = fetched ->
        type_fetches = FetchView.current(Keyword.fetch!(options, :type_view))
        set = VehicleTileSet.build(%{fetched: fetched, type_fetches: type_fetches})
        publish(%{server: server, set: set, fetched: fetched, options: options})

      _not_published_or_none ->
        :ok = VehicleTiles.clear(server, system_id)
        {:ok, %{kind: :cleared}}
    end
  end

  defp publish(%{server: server, set: set, fetched: fetched, options: options}) do
    write_options = Keyword.fetch!(options, :write_options)
    # The index is written only once every file it names is.
    failed_count =
      case Enum.count(set.files, &(not written?(&1, write_options))) do
        0 -> Enum.count([set.index], &(not written?(&1, write_options)))
        files_failed_count -> files_failed_count
      end

    case failed_count do
      0 ->
        index = %{
          system_id: fetched.id,
          destination: set.index.destination,
          fetched_at: fetched.fetched_at,
          vehicle_count: set.vehicle_count
        }

        :ok = VehicleTiles.record(server, index)

        Logger.debug("Shared vehicle tiles written",
          system_id: fetched.id,
          request_id: fetched.request_id,
          tile_count: set.tile_count,
          vehicle_count: set.vehicle_count
        )

        {:ok,
         %{
           kind: :published,
           index: index,
           tile_count: set.tile_count,
           vehicle_count: set.vehicle_count
         }}

      failed_count ->
        Logger.error("Shared vehicle tiles not written",
          system_id: fetched.id,
          request_id: fetched.request_id,
          failed_count: failed_count
        )

        {:error, %{failed_count: failed_count}}
    end
  end

  defp written?(%{destination: destination, content: content}, write_options) do
    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok -> true
      {:error, :already_exists} -> true
      {:error, _reason} -> false
    end
  end
end
