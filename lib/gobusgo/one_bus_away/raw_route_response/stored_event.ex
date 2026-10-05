defmodule Gobusgo.OneBusAway.RawRouteResponse.StoredEvent do
  alias Gobusgo.OneBusAway.StoredEvent

  @dataset "oba/routes-for-agency"
  @topic "oba.routes.response-stored"

  @moduledoc """
  The "response stored" record of one stored `routes-for-agency` response:
  a reference to the stored response, never its content. Everything here is
  pure.

  The record goes to the topic `#{@topic}` under the key
  `#{@dataset}/<agency id>`, one key per agency, so the events of one agency
  keep their order. It holds the event of `Gobusgo.OneBusAway.StoredEvent`,
  whose `data.dataset` is `#{@dataset}` and whose `data.agencyId` is the
  agency the request asked for.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @type decode_error :: StoredEvent.decode_error()

  @type response :: %{
          agency_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type decoded :: %{
          event_id: RequestId.t(),
          agency_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type request :: %{
          event_id: RequestId.t(),
          source: String.t(),
          time: DateTime.t(),
          response: response()
        }

  @doc "The topic the record goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The name of the route dataset."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns the record that announces `request.response` as stored. Raises
  `Gobusgo.Assert.AssertionError` when an identifier is not a UUID version 7
  or the agency identifier is empty.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{event_id: event_id, source: source, time: time, response: response}) do
    %{agency_id: agency_id} = response
    Assert.condition(is_binary(agency_id), "agency identifier must be a string")
    Assert.condition(agency_id != "", "agency identifier must be non-empty")

    StoredEvent.record(%{
      topic: @topic,
      dataset: @dataset,
      key: @dataset <> "/" <> agency_id,
      event_id: event_id,
      source: source,
      time: time,
      response: response,
      data: %{"agencyId" => agency_id}
    })
  end

  @doc """
  Returns the event identifier, the agency, and the stored response that
  `value`, the value of a record `record/1` produces, refers to. The first
  rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{data: data} = decoded} <- StoredEvent.decode(value, @dataset) do
      case data do
        %{"agencyId" => agency_id} when is_binary(agency_id) and agency_id != "" ->
          {:ok, decoded |> Map.delete(:data) |> Map.put(:agency_id, agency_id)}

        _other ->
          {:error, :schema_mismatch}
      end
    end
  end
end
