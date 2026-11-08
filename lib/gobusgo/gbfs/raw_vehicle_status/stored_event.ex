defmodule Gobusgo.Gbfs.RawVehicleStatus.StoredEvent do
  alias Gobusgo.OneBusAway.StoredEvent

  @dataset "gbfs/free-bike-status"
  @topic "gbfs.free-bike-status.response-stored"

  @moduledoc """
  The "response stored" record of one stored GBFS vehicle file: a reference
  to the stored file, never its content. Everything here is pure.

  The record goes to the topic `#{@topic}` under the key
  `#{@dataset}/<system id>`, one key per system, so the events of one
  system keep their order. It holds the "response stored" event the
  OneBusAway datasets share, `Gobusgo.OneBusAway.StoredEvent`, whose
  `data.dataset` is `#{@dataset}`, whose `data.dataSha256` is the hash of
  the file as stored, and whose `data.systemId` and `data.version` are the
  system and the GBFS version that answered.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @type decode_error :: StoredEvent.decode_error()

  @type decoded :: %{
          event_id: RequestId.t(),
          system_id: String.t(),
          version: Files.version(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @doc "The topic the record goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The name of the dataset."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns the record that announces `stored`, as
  `Gobusgo.Gbfs.RawVehicleStatus.build/1` returns it, as stored by the
  producer `source`. Raises `Gobusgo.Assert.AssertionError` when an
  identifier is not a UUID version 7.
  """
  @spec record(%{event_id: RequestId.t(), source: String.t(), stored: RawVehicleStatus.t()}) ::
          Publisher.topic_record()
  def record(%{event_id: event_id, source: source, stored: stored}) do
    %{system_id: system_id, version: version, fetched_at: fetched_at} = stored
    Systems.assert_id(system_id)
    Assert.condition(version in Files.versions(), "version must be known")

    StoredEvent.record(%{
      topic: @topic,
      dataset: @dataset,
      key: @dataset <> "/" <> system_id,
      event_id: event_id,
      source: source,
      time: fetched_at,
      response: %{
        destination: stored.destination,
        fetched_at: fetched_at,
        data_sha256: stored.body_sha256,
        request_id: stored.request_id
      },
      data: %{"systemId" => system_id, "version" => version}
    })
  end

  @doc """
  Returns the event identifier, the system, the version, and the stored
  file that `value`, the value of a record `record/1` produces, refers to.
  The first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{data: data} = decoded} <- StoredEvent.decode(value, @dataset) do
      case data do
        %{"systemId" => system_id, "version" => version} ->
          if Systems.id?(system_id) and version in Files.versions() do
            {:ok,
             decoded
             |> Map.delete(:data)
             |> Map.merge(%{system_id: system_id, version: version})}
          else
            {:error, :schema_mismatch}
          end

        _other ->
          {:error, :schema_mismatch}
      end
    end
  end
end
