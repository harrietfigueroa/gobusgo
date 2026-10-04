defmodule Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent do
  alias Gobusgo.OneBusAway.StoredEvent

  @dataset "oba/agencies-with-coverage"
  @topic "oba.agencies-with-coverage.response-stored"

  @moduledoc """
  The "response stored" record of one stored agency discovery response: a
  reference to the stored response, never its content. Everything here is
  pure.

  The record goes to the topic `#{@topic}` under the key `#{@dataset}`, one
  key for the whole dataset, so the events of the dataset keep their order.
  It holds the event of `Gobusgo.OneBusAway.StoredEvent`, whose
  `data.dataset` is `#{@dataset}`.
  """

  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @type decode_error :: StoredEvent.decode_error()

  @type response :: %{
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type decoded :: %{
          event_id: RequestId.t(),
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

  @doc "The name of the agency discovery dataset."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns the record that announces `request.response` as stored. Raises
  `Gobusgo.Assert.AssertionError` when an identifier is not a UUID version 7.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{event_id: event_id, source: source, time: time, response: response}) do
    StoredEvent.record(%{
      topic: @topic,
      dataset: @dataset,
      key: @dataset,
      event_id: event_id,
      source: source,
      time: time,
      response: response,
      data: %{}
    })
  end

  @doc """
  Returns the event identifier and the stored response that `value`, the
  value of a record `record/1` produces, refers to. Fields of `data` outside
  the event are ignored. The first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, decoded} <- StoredEvent.decode(value, @dataset) do
      {:ok, Map.delete(decoded, :data)}
    end
  end
end
