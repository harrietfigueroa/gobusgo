defmodule Gobusgo.OneBusAway.RawArrivalResponse.StoredEvent do
  alias Gobusgo.OneBusAway.StoredEvent

  @dataset "oba/arrivals-and-departures-for-stop"
  @topic "oba.arrivals.response-stored"

  @moduledoc """
  The "response stored" record of one stored `arrivals-and-departures-for-stop` response:
  a reference to the stored response, never its content. Everything here is
  pure.

  The record goes to the topic `#{@topic}` under the key
  `#{@dataset}/<stop id>`, one key per stop, so the events of one stop
  keep their order. It holds the event of `Gobusgo.OneBusAway.StoredEvent`,
  whose `data.dataset` is `#{@dataset}` and whose `data.stopId` is the
  stop the request asked for.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @type decode_error :: StoredEvent.decode_error()

  @type response :: %{
          stop_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type decoded :: %{
          event_id: RequestId.t(),
          stop_id: String.t(),
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

  @doc "The name of the arrivals dataset."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns the record that announces `request.response` as stored. Raises
  `Gobusgo.Assert.AssertionError` when an identifier is not a UUID version 7
  or the stop identifier is empty.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{event_id: event_id, source: source, time: time, response: response}) do
    %{stop_id: stop_id} = response
    Assert.condition(is_binary(stop_id), "stop identifier must be a string")
    Assert.condition(stop_id != "", "stop identifier must be non-empty")

    StoredEvent.record(%{
      topic: @topic,
      dataset: @dataset,
      key: @dataset <> "/" <> stop_id,
      event_id: event_id,
      source: source,
      time: time,
      response: response,
      data: %{"stopId" => stop_id}
    })
  end

  @doc """
  Returns the event identifier, the stop, and the stored response that
  `value`, the value of a record `record/1` produces, refers to. The first
  rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{data: data} = decoded} <- StoredEvent.decode(value, @dataset) do
      case data do
        %{"stopId" => stop_id} when is_binary(stop_id) and stop_id != "" ->
          {:ok, decoded |> Map.delete(:data) |> Map.put(:stop_id, stop_id)}

        _other ->
          {:error, :schema_mismatch}
      end
    end
  end
end
