defmodule Gobusgo.OneBusAway.RouteScheduleRecorder do
  @event_source "/gobusgo/recorder/oba/schedule-for-route"

  @moduledoc """
  Fetches the schedule of one route on one service date, records a
  successful response that holds one through `Gobusgo.Writer`, and announces
  the stored response through `Gobusgo.Publisher`. This module orchestrates;
  the request lives in `Gobusgo.OneBusAway.RouteSchedules`, the stored form in
  `Gobusgo.OneBusAway.RawRouteScheduleResponse`, and the event in
  `Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEvent`.

  ## Results

    * `{:ok, recorded}`: the response is stored. `recorded` holds the
      `:route_id`, the `:service_date`, the `:destination`, the
      `:request_id`, the `:fetched_at` time at the precision stored, the
      `:data_sha256` of the envelope data, and `:event_published`, whether
      the "response stored" event was published.
    * `{:no_service, %{route_id: ..., service_date: ...}}`: the route has no
      service on the date, which the source answers with a documented code,
      and nothing is stored.
    * `{:error, {:fetch, reason}}`: the request did not yield a successful
      response, and nothing is stored. `reason` is a
      `t:Gobusgo.OneBusAway.RouteSchedules.error/0`.
    * `{:error, {:write, reason}}`: the response was fetched and the writer
      did not store it. `reason` is a `t:Gobusgo.Writer.error_reason/0`.

  Only an HTTP 200 response whose envelope code is 200 and whose payload
  matches the schema is stored; a payload that breaks the schema raises
  `Gobusgo.Assert.AssertionError` and nothing is stored. A write is
  create-only, so an earlier record is never replaced.

  ## Event

  Once the writer has stored the response, one "response stored" event is
  published for it, with the `source` `#{@event_source}`, a new identifier,
  and the fetch time as `time`. A publish that fails leaves the result
  `{:ok, recorded}` with `:event_published` `false`.

  A call logs nothing: every outcome returns to the caller.

  ## Options

    * `:route_id` (required): the route whose schedule is fetched.
    * `:service_date` (required): the `Date` of service asked for.
    * `:fetch_options`: options for `Gobusgo.OneBusAway.RouteSchedules.fetch_response/2`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
    * `:request_id`: the UUID version 7 naming this request. Defaults to a new
      `Gobusgo.RequestId`.
    * `:event_id`: a zero-arity function returning a new UUID version 7 for
      the event. Defaults to `Gobusgo.RequestId.generate/0`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEvent
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @type recorded :: %{
          route_id: String.t(),
          service_date: Date.t(),
          destination: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          event_published: boolean()
        }
  @type no_service :: %{route_id: String.t(), service_date: Date.t()}
  @type error :: {:fetch, RouteSchedules.error()} | {:write, Writer.error_reason()}

  @doc """
  Fetches the schedule of `options[:route_id]` on `options[:service_date]`,
  stores a response that holds one once, and publishes its "response
  stored" event.
  """
  @spec record(Client.settings(), Keyword.t()) ::
          {:ok, recorded()} | {:no_service, no_service()} | {:error, error()}
  def record(%{api_key: api_key} = settings, options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :route_id,
        :service_date,
        :request_id,
        event_id: &RequestId.generate/0,
        fetch_options: [],
        write_options: [],
        publish_options: []
      ])

    route_id = Keyword.fetch!(options, :route_id)
    service_date = Keyword.fetch!(options, :service_date)
    request_id = Keyword.get_lazy(options, :request_id, &RequestId.generate/0)
    Assert.condition(RequestId.valid?(request_id), "request_id must be a UUID version 7")
    event_id = Keyword.fetch!(options, :event_id)
    Assert.condition(is_function(event_id, 0), "event_id must be a zero-arity function")
    request = [route_id: route_id, service_date: service_date]
    fetch_options = Keyword.merge(Keyword.fetch!(options, :fetch_options), request)

    case RouteSchedules.fetch_response(settings, fetch_options) do
      {:ok, %{schedule: :no_service}} ->
        {:no_service, %{route_id: route_id, service_date: service_date}}

      {:ok, response} ->
        stored = RawRouteScheduleResponse.build(%{response: response, request_id: request_id})
        assert_secret_free(stored, api_key)

        response = %{
          route_id: route_id,
          service_date: service_date,
          destination: stored.destination,
          request_id: request_id,
          fetched_at: stored.fetched_at,
          data_sha256: stored.data_sha256
        }

        with :ok <- write(stored, Keyword.fetch!(options, :write_options)) do
          event = publish(response, event_id.(), Keyword.fetch!(options, :publish_options))
          {:ok, Map.put(response, :event_published, event == :ok)}
        end

      {:error, reason} ->
        {:error, {:fetch, reason}}
    end
  end

  defp write(%{destination: destination, content: content}, write_options) do
    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp publish(%{fetched_at: fetched_at} = response, event_id, publish_options) do
    record =
      StoredEvent.record(%{
        event_id: event_id,
        source: @event_source,
        time: fetched_at,
        response: response
      })

    Publisher.publish([record], publish_options)
  end

  defp assert_secret_free(%{destination: destination, content: content}, api_key) do
    Assert.condition(
      :binary.match(destination, api_key) == :nomatch,
      "destination carries the key"
    )

    Assert.condition(:binary.match(content, api_key) == :nomatch, "content carries the key")
  end
end
