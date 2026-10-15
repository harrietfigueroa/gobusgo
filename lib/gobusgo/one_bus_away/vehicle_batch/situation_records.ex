defmodule Gobusgo.OneBusAway.VehicleBatch.SituationRecords do
  alias Gobusgo.CloudEvent
  alias Gobusgo.OneBusAway.SituationRecords

  @source %{
    type_name: CloudEvent.type(%{name: "agency.situations.processed", version: 1}),
    source: "/gobusgo/processor/oba/vehicles-for-agency",
    key_prefix: "vehicles/",
    id_field: "agencyId"
  }

  @moduledoc """
  The published form of the situations one `vehicles-for-agency` response
  references, the service alerts of the trips its vehicles serve: one
  record of `Gobusgo.OneBusAway.SituationRecords` per fetch, under the key
  `#{@source.key_prefix}<agency id>`, of the `type` `#{@source.type_name}`,
  with the agency in `data.#{@source.id_field}`. Everything here is pure.
  """

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.Publisher

  @doc "Returns the record that publishes the situations of `fetch`."
  @spec build(Records.fetch()) :: Publisher.topic_record()
  def build(%{agency_id: agency_id} = fetch) do
    SituationRecords.build(@source, Map.put(fetch, :id, agency_id))
  end

  @doc "Returns the fetch `value`, a record `build/1` produces, holds; see `Gobusgo.OneBusAway.SituationRecords.decode/2`."
  @spec decode(binary()) ::
          {:ok, SituationRecords.fetch()} | {:error, SituationRecords.decode_error()}
  def decode(value) when is_binary(value), do: SituationRecords.decode(@source, value)
end
