defmodule Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEvent do
  alias Gobusgo.OneBusAway.StoredEvent

  @dataset "oba/schedule-for-route"
  @topic "oba.schedules.response-stored"

  @moduledoc """
  The "response stored" record of one stored `schedule-for-route` response:
  a reference to the stored response, never its content. Everything here is
  pure.

  The record goes to the topic `#{@topic}` under the key
  `#{@dataset}/<route id>`, one key per route, so the events of one route
  keep their order. It holds the event of `Gobusgo.OneBusAway.StoredEvent`,
  whose `data.dataset` is `#{@dataset}`, whose `data.routeId` is the route
  the request asked for, and whose `data.serviceDate` is the service date,
  as `YYYY-MM-DD`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @type decode_error :: StoredEvent.decode_error()

  @type response :: %{
          route_id: String.t(),
          service_date: Date.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type decoded :: %{
          event_id: RequestId.t(),
          route_id: String.t(),
          service_date: Date.t(),
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

  @doc "The name of the schedule dataset."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns the record that announces `request.response` as stored. Raises
  `Gobusgo.Assert.AssertionError` when an identifier is not a UUID version 7
  or the route identifier is empty.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{event_id: event_id, source: source, time: time, response: response}) do
    %{route_id: route_id, service_date: service_date} = response
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(is_struct(service_date, Date), "service date must be a Date")

    StoredEvent.record(%{
      topic: @topic,
      dataset: @dataset,
      key: @dataset <> "/" <> route_id,
      event_id: event_id,
      source: source,
      time: time,
      response: Map.delete(response, :service_date),
      data: %{"routeId" => route_id, "serviceDate" => Date.to_iso8601(service_date)}
    })
  end

  @doc """
  Returns the event identifier, the route, the service date, and the stored
  response that `value`, the value of a record `record/1` produces, refers
  to. The first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{data: data} = decoded} <- StoredEvent.decode(value, @dataset) do
      case data do
        %{"routeId" => route_id, "serviceDate" => text}
        when is_binary(route_id) and route_id != "" and is_binary(text) ->
          decoded_with(decoded, route_id, text)

        _other ->
          {:error, :schema_mismatch}
      end
    end
  end

  defp decoded_with(decoded, route_id, text) do
    case Date.from_iso8601(text) do
      {:ok, service_date} ->
        decoded = Map.delete(decoded, :data)
        {:ok, Map.merge(decoded, %{route_id: route_id, service_date: service_date})}

      {:error, _reason} ->
        {:error, :schema_mismatch}
    end
  end
end
