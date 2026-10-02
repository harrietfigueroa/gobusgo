defmodule Gobusgo.OneBusAway.AgencyRecorder do
  @event_source "/gobusgo/recorder/oba/agencies-with-coverage"

  @moduledoc """
  Fetches agency discovery, records the successful response through
  `Gobusgo.Writer`, and announces the stored response through
  `Gobusgo.Publisher`. This module orchestrates and logs; the request lives
  in `Gobusgo.OneBusAway.Agencies`, the stored form in
  `Gobusgo.OneBusAway.RawAgencyResponse`, the event in
  `Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent`, and the storage and
  the delivery behind the writer and the publisher.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.AgencyRecorder.record(settings, []) do
        {:ok, recorded} -> recorded.destination
        {:error, {:fetch, reason}} -> reason
        {:error, {:write, reason}} -> reason
      end

  ## Results

    * `{:ok, recorded}`: the response is stored. `recorded` holds the
      `:destination`, the `:request_id`, the `:fetched_at` time at the
      precision stored, and the `:data_sha256` of the envelope data.
    * `{:error, {:fetch, reason}}`: the request did not yield a successful
      response, and nothing is stored. `reason` is a
      `t:Gobusgo.OneBusAway.Agencies.error/0`.
    * `{:error, {:write, reason}}`: the response was fetched and the writer
      did not store it. `reason` is a `t:Gobusgo.Writer.error_reason/0`.

  Only an HTTP 200 response whose envelope code is 200 and whose payload
  matches the documented schema is stored; a payload that breaks the schema
  raises `Gobusgo.Assert.AssertionError` and nothing is stored. A write is
  create-only, so an earlier record is never replaced.

  ## Event

  Once the writer has stored the response, one "response stored" event is
  published for it, with the `source` `#{@event_source}`, a new identifier,
  and the fetch time as `time`. Nothing is published for a response that is
  not stored. A publish that fails leaves the result `{:ok, recorded}`: the
  response is stored, and no event names it.

  Each call logs its outcome once: `info` when the response is recorded and
  its event published, `warning` when the response is recorded and its event
  is not published, `error` with the failed `stage` when the response is not
  recorded.

  ## Options

    * `:fetch_options`: options for `Gobusgo.OneBusAway.Agencies.fetch_response/2`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
    * `:request_id`: the UUID version 7 naming this request. Defaults to a new
      `Gobusgo.RequestId`.
    * `:event_id`: a zero-arity function returning a new UUID version 7 for
      the event. Defaults to `Gobusgo.RequestId.generate/0`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Agencies
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @type recorded :: %{
          destination: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t()
        }
  @type error :: {:fetch, Agencies.error()} | {:write, Writer.error_reason()}

  @doc """
  Fetches every agency with coverage, stores the response once, and
  publishes its "response stored" event.
  """
  @spec record(Client.settings(), Keyword.t()) :: {:ok, recorded()} | {:error, error()}
  def record(%{api_key: api_key} = settings, options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :request_id,
        event_id: &RequestId.generate/0,
        fetch_options: [],
        write_options: [],
        publish_options: []
      ])

    request_id = Keyword.get_lazy(options, :request_id, &RequestId.generate/0)
    Assert.condition(RequestId.valid?(request_id), "request_id must be a UUID version 7")
    event_id = Keyword.fetch!(options, :event_id)
    Assert.condition(is_function(event_id, 0), "event_id must be a zero-arity function")

    case Agencies.fetch_response(settings, Keyword.fetch!(options, :fetch_options)) do
      {:ok, response} ->
        stored = RawAgencyResponse.build(%{response: response, request_id: request_id})
        assert_secret_free(stored, api_key)

        with {:ok, recorded} <- write(stored, request_id, Keyword.fetch!(options, :write_options)) do
          event = publish(recorded, event_id.(), Keyword.fetch!(options, :publish_options))
          log_recorded(recorded, event, byte_size(stored.content))
          {:ok, recorded}
        end

      {:error, reason} ->
        fail(%{stage: :fetch, reason: reason, request_id: request_id})
    end
  end

  defp write(%{destination: destination, content: content} = stored, request_id, write_options) do
    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok ->
        {:ok,
         %{
           destination: destination,
           request_id: request_id,
           fetched_at: stored.fetched_at,
           data_sha256: stored.data_sha256
         }}

      {:error, reason} ->
        fail(%{stage: :write, reason: reason, request_id: request_id})
    end
  end

  defp publish(%{fetched_at: fetched_at} = recorded, event_id, publish_options) do
    record =
      StoredEvent.record(%{
        event_id: event_id,
        source: @event_source,
        time: fetched_at,
        response: recorded
      })

    Publisher.publish([record], publish_options)
  end

  defp log_recorded(recorded, :ok, content_bytes) do
    Logger.info("OneBusAway agency response recorded",
      destination: recorded.destination,
      request_id: recorded.request_id,
      data_sha256: recorded.data_sha256,
      content_bytes: content_bytes
    )
  end

  defp log_recorded(recorded, {:error, reason}, content_bytes) do
    Logger.warning("OneBusAway agency response recorded without its event",
      destination: recorded.destination,
      request_id: recorded.request_id,
      data_sha256: recorded.data_sha256,
      content_bytes: content_bytes,
      reason: inspect(reason)
    )
  end

  defp fail(%{stage: stage, reason: reason, request_id: request_id}) do
    Logger.error("OneBusAway agency response not recorded",
      stage: stage,
      reason: inspect(reason),
      request_id: request_id
    )

    {:error, {stage, reason}}
  end

  defp assert_secret_free(%{destination: destination, content: content}, api_key) do
    Assert.condition(
      :binary.match(destination, api_key) == :nomatch,
      "destination carries the key"
    )

    Assert.condition(:binary.match(content, api_key) == :nomatch, "content carries the key")
  end
end
