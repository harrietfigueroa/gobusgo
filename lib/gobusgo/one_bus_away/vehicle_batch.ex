defmodule Gobusgo.OneBusAway.VehicleBatch do
  @moduledoc """
  Processes one stored `vehicles-for-agency` response: the response at a
  destination, read through `Gobusgo.Reader` and published through
  `Gobusgo.Publisher` as one record per vehicle, one tombstone per vehicle
  that has expired, one manifest record, and one record that holds the
  situations the response references. This module orchestrates and logs;
  the stored form of the input lives in
  `Gobusgo.OneBusAway.RawVehicleResponse`, the published form in
  `Gobusgo.OneBusAway.VehicleBatch.Records` and
  `Gobusgo.OneBusAway.VehicleBatch.SituationRecords`, and the rule that
  decides which vehicles have expired in
  `Gobusgo.OneBusAway.VehicleView.State`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same vehicle and manifest records again.

  ## Order

  The vehicle records are published first, in calls of at most
  `Gobusgo.Publisher.record_count_max/0` records, each call returning once
  its records are acknowledged. The tombstones follow in the same way: one
  for each vehicle the vehicle view names as expired at this fetch, absent
  from it and last seen longer ago than the grace period. The manifest
  record is published after every earlier call returned `:ok`, so a manifest
  exists only for a fetch whose vehicle records and tombstones are all
  stored. The situations record goes in the manifest's call, so a failure
  there can leave either published. A response without vehicles publishes
  the manifest and the situations record alone.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the `:agency_id`,
  the `:request_id` and `:fetched_at` of the fetch, the `:vehicle_count`, the
  `:tombstone_count`, the `:situation_count`, and the
  `:situation_rejected_count` of the situations
  `Gobusgo.OneBusAway.Situations` rejects.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, `:publish_vehicles`, `:publish_tombstones`,
  or `:publish_manifest`. No manifest is published for a failure at any
  stage.

  A call that publishes logs once at `debug`, and once more at `warning` as
  `Situations rejected` when it rejected a situation, which the source's
  contract does not account for. A failure returns to the caller and is not
  logged here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
    * `:view`: the vehicle view that names the expired vehicles. Defaults to
      `Gobusgo.OneBusAway.VehicleView`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleBatch.SituationRecords
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          agency_id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          vehicle_count: non_neg_integer(),
          tombstone_count: non_neg_integer(),
          situation_count: non_neg_integer(),
          situation_rejected_count: non_neg_integer()
        }

  @doc """
  Publishes the vehicles, the tombstones, and the manifest of the response
  stored at `destination`.
  """
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [], view: VehicleView)
    publish_options = Keyword.fetch!(options, :publish_options)
    view = Keyword.fetch!(options, :view)
    Assert.condition(is_atom(view), "view must be an atom, got: #{inspect(view)}")

    result =
      with {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, fetch} <- parse(destination, content),
           %{vehicles: vehicles, manifest: manifest} = Records.build(fetch),
           tombstones = tombstones(fetch, view),
           :ok <- publish(:publish_vehicles, vehicles, publish_options),
           :ok <- publish(:publish_tombstones, tombstones, publish_options),
           situations = SituationRecords.build(fetch),
           :ok <- publish(:publish_manifest, [manifest, situations], publish_options) do
        {:ok,
         %{
           destination: destination,
           agency_id: fetch.agency_id,
           request_id: fetch.request_id,
           fetched_at: fetch.fetched_at,
           vehicle_count: length(vehicles),
           tombstone_count: length(tombstones),
           situation_count: length(fetch.situations),
           situation_rejected_count: fetch.situation_rejected_count
         }}
      end

    with {:ok, published} <- result do
      Logger.debug("Vehicle batch published",
        destination: destination,
        agency_id: published.agency_id,
        request_id: published.request_id,
        vehicle_count: published.vehicle_count,
        tombstone_count: published.tombstone_count,
        situation_count: published.situation_count
      )

      log_rejected_situations(published)
    end

    result
  end

  defp log_rejected_situations(%{situation_rejected_count: 0}), do: :ok

  defp log_rejected_situations(published) do
    Logger.warning("Situations rejected",
      destination: published.destination,
      rejected_count: published.situation_rejected_count
    )
  end

  defp read(destination, read_options) do
    case Reader.read(destination, read_options) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, BatchFailure.read(reason)}
    end
  end

  defp parse(destination, content) do
    case RawVehicleResponse.parse(%{destination: destination, content: content}) do
      {:ok, fetch} -> {:ok, fetch}
      {:error, reason} -> {:error, BatchFailure.parse(reason)}
    end
  end

  defp tombstones(%{agency_id: agency_id, fetched_at: fetched_at, vehicles: vehicles}, view) do
    expired_vehicle_ids =
      VehicleView.expired_vehicle_ids(view, %{
        agency_id: agency_id,
        fetched_at: fetched_at,
        vehicle_ids: Enum.map(vehicles, & &1.id)
      })

    Records.tombstones(%{agency_id: agency_id, vehicle_ids: expired_vehicle_ids})
  end

  defp publish(stage, records, publish_options) do
    records
    |> Enum.chunk_every(Publisher.record_count_max())
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Publisher.publish(chunk, publish_options) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, BatchFailure.publish(stage, reason)}}
      end
    end)
  end
end
