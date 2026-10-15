defmodule Gobusgo.OneBusAway.ArrivalBatch.SituationRecords do
  alias Gobusgo.CloudEvent
  alias Gobusgo.OneBusAway.SituationRecords

  @source %{
    type_name: CloudEvent.type(%{name: "stop.situations.processed", version: 1}),
    source: "/gobusgo/processor/oba/arrivals-and-departures-for-stop",
    key_prefix: "arrivals/",
    id_field: "stopId"
  }

  @moduledoc """
  The published form of the situations one `arrivals-and-departures-for-stop`
  response references, the service alerts of the stop's routes and trips,
  those of a route at the stop included: one record of
  `Gobusgo.OneBusAway.SituationRecords` per fetch, under the key
  `#{@source.key_prefix}<stop id>`, of the `type` `#{@source.type_name}`,
  with the stop in `data.#{@source.id_field}`. Everything here is pure.
  """

  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.Publisher

  @doc "Returns the record that publishes the situations of `parsed`."
  @spec build(RawArrivalResponse.parsed()) :: Publisher.topic_record()
  def build(%{stop_id: stop_id} = parsed) do
    SituationRecords.build(@source, Map.put(parsed, :id, stop_id))
  end

  @doc "Returns the fetch `value`, a record `build/1` produces, holds; see `Gobusgo.OneBusAway.SituationRecords.decode/2`."
  @spec decode(binary()) ::
          {:ok, SituationRecords.fetch()} | {:error, SituationRecords.decode_error()}
  def decode(value) when is_binary(value), do: SituationRecords.decode(@source, value)
end
