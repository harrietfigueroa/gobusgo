defmodule Gobusgo.Gbfs.VehicleStatusRecorder do
  @event_source "/gobusgo/recorder/gbfs/free-bike-status"
  @fetch_deadline_ms 20_000

  @moduledoc """
  Fetches the vehicle file of one GBFS system, records it through
  `Gobusgo.Writer`, announces it through `Gobusgo.Publisher`, and then
  deletes the system's stored files past their age through
  `Gobusgo.Gbfs.VehicleStatusRetention`. This module orchestrates; the
  request lives in `Gobusgo.Gbfs.Client`, the stored form in
  `Gobusgo.Gbfs.RawVehicleStatus`, and the event in
  `Gobusgo.Gbfs.RawVehicleStatus.StoredEvent`.

  ## Results

    * `{:ok, %{kind: :recorded}}`: the file is stored, with the
      `:system_id`, `:destination`, `:request_id`, `:fetched_at` at the
      precision stored, `:version`, `:vehicle_count`, `:event_published`,
      whether the "response stored" event was published, and `:retention`,
      the result of `Gobusgo.Gbfs.VehicleStatusRetention.run/1`. The
      in-process publisher processes the file before the publish returns,
      so the deletion follows the processing.
    * `{:ok, %{kind: :not_published}}`: every version was passed over, as a
      feed that is gone is (GOB-254). Nothing is stored, and a record that
      the feed is not published goes to
      `Gobusgo.Gbfs.VehicleStatusBatch.Records.topic/0`, so the view holds
      no vehicle for the system. It holds the `:system_id`, the
      `:passed_over` versions with their reasons, and `:record_published`.
    * `{:error, {:fetch, failure}}`: a `t:Gobusgo.Gbfs.Client.failure/0`,
      and nothing is stored.
    * `{:error, {:vehicle_count, count}}`: the file holds more than
      `Gobusgo.Gbfs.VehicleStatusBatch.vehicle_count_max/0` vehicles, and
      nothing is stored.
    * `{:error, {:write, reason}}`: the writer did not store the file.

  A call logs nothing itself: every outcome returns to the caller.

  ## Options

    * `:fetch_options`: options for `Gobusgo.Gbfs.Client.fetch/3`, whose
      `:deadline_ms` is #{@fetch_deadline_ms} unless given.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
    * `:retention_options`: options for
      `Gobusgo.Gbfs.VehicleStatusRetention.run/1`, whose `:system_ids` is
      the system's alone.
    * `:request_id`: the UUID version 7 naming this fetch. Defaults to a new
      `Gobusgo.RequestId`.
    * `:event_id`: a zero-arity function returning a new UUID version 7 for
      the event. Defaults to `Gobusgo.RequestId.generate/0`.
    * `:now`: a zero-arity function returning the UTC time a feed is found
      not published at, by default `DateTime.utc_now/0`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Client
  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.RawVehicleStatus.StoredEvent
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleStatusBatch
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusRetention
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @type recorded :: %{
          kind: :recorded,
          system_id: String.t(),
          destination: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          version: String.t(),
          vehicle_count: non_neg_integer(),
          event_published: boolean(),
          retention:
            {:ok, VehicleStatusRetention.counts()} | {:error, VehicleStatusRetention.counts()}
        }
  @type not_published :: %{
          kind: :not_published,
          system_id: String.t(),
          passed_over: [Client.passed_over()],
          record_published: boolean()
        }
  @type error ::
          {:fetch, Client.failure()}
          | {:vehicle_count, pos_integer()}
          | {:write, Writer.error_reason()}

  @doc "The bound on one fetch, in milliseconds, unless the options name another."
  @spec fetch_deadline_ms() :: pos_integer()
  def fetch_deadline_ms, do: @fetch_deadline_ms

  @doc "Fetches the vehicle file of `system`, stores it once, and announces it."
  @spec record(Systems.t(), Keyword.t()) ::
          {:ok, recorded() | not_published()} | {:error, error()}
  def record(%{id: system_id} = system, options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :request_id,
        event_id: &RequestId.generate/0,
        now: &DateTime.utc_now/0,
        fetch_options: [],
        write_options: [],
        publish_options: [],
        retention_options: []
      ])

    Systems.assert_id(system_id)
    request_id = Keyword.get_lazy(options, :request_id, &RequestId.generate/0)
    Assert.condition(RequestId.valid?(request_id), "request_id must be a UUID version 7")
    event_id = Keyword.fetch!(options, :event_id)
    Assert.condition(is_function(event_id, 0), "event_id must be a zero-arity function")

    fetch_options =
      Keyword.merge([deadline_ms: @fetch_deadline_ms], Keyword.fetch!(options, :fetch_options))

    client_system = Map.take(system, [:discovery_urls, :language])

    case Client.fetch(client_system, :vehicle_status, fetch_options) do
      {:ok, %{kind: :fetched} = fetched} ->
        store(%{system_id: system_id, fetched: fetched, request_id: request_id}, options)

      {:ok, %{kind: :not_published, passed_over: passed_over}} ->
        checked_at = Keyword.fetch!(options, :now).()

        publish_not_published(
          %{system_id: system_id, passed_over: passed_over, checked_at: checked_at},
          %{request_id: request_id, publish_options: Keyword.fetch!(options, :publish_options)}
        )

      {:error, failure} ->
        {:error, {:fetch, failure}}
    end
  end

  defp store(%{system_id: system_id, fetched: fetched} = request, options) do
    vehicle_count = length(fetched.vehicles)

    if vehicle_count <= VehicleStatusBatch.vehicle_count_max() do
      stored = RawVehicleStatus.build(request)
      write_request = %{destination: stored.destination, content: stored.content}

      case Writer.write(write_request, Keyword.fetch!(options, :write_options)) do
        :ok ->
          event_id = Keyword.fetch!(options, :event_id).()

          record =
            StoredEvent.record(%{event_id: event_id, source: @event_source, stored: stored})

          published = Publisher.publish([record], Keyword.fetch!(options, :publish_options))

          retention_options =
            Keyword.put(Keyword.fetch!(options, :retention_options), :system_ids, [system_id])

          {:ok,
           %{
             kind: :recorded,
             system_id: system_id,
             destination: stored.destination,
             request_id: stored.request_id,
             fetched_at: stored.fetched_at,
             version: stored.version,
             vehicle_count: vehicle_count,
             event_published: published == :ok,
             retention: VehicleStatusRetention.run(retention_options)
           }}

        {:error, reason} ->
          {:error, {:write, reason}}
      end
    else
      {:error, {:vehicle_count, vehicle_count}}
    end
  end

  defp publish_not_published(found, %{request_id: request_id, publish_options: publish_options}) do
    record =
      Records.build_not_published(%{
        kind: :not_published,
        id: found.system_id,
        fetched_at: DateTime.truncate(found.checked_at, :second),
        request_id: request_id
      })

    published = Publisher.publish([record], publish_options)

    {:ok,
     %{
       kind: :not_published,
       system_id: found.system_id,
       passed_over: found.passed_over,
       record_published: published == :ok
     }}
  end
end
