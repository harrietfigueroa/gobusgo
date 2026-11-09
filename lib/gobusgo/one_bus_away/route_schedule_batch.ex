defmodule Gobusgo.OneBusAway.RouteScheduleBatch do
  @moduledoc """
  Processes one stored response of a route's schedule on one service date:
  the response at a destination, read through `Gobusgo.Reader` and published
  through `Gobusgo.Publisher` as one record. This module orchestrates and
  logs; the stored form of the input lives in
  `Gobusgo.OneBusAway.RawRouteScheduleResponse` and the published form in
  `Gobusgo.OneBusAway.RouteScheduleBatch.Records`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same record again.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the `:route_id`,
  the `:service_date`, the `:request_id` and `:fetched_at` of the fetch, and
  the `:trip_count` and `:stop_time_count` of the schedule.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, or `:publish_route_schedule`. Nothing is
  published for a failure at `:read` or `:parse`.

  A call that publishes logs once at `debug`: a daily fetch publishes the
  record of every route. A failure returns to the caller and is not logged
  here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          route_id: String.t(),
          service_date: Date.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          trip_count: non_neg_integer(),
          stop_time_count: non_neg_integer()
        }

  @doc "Publishes the schedule of the response stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    with {:ok, content} <- read_stored(destination, options) do
      process_content(%{destination: destination, content: content}, options)
    end
  end

  @doc """
  Reads the response stored at `destination`, as `process/2` reads it, so a
  caller can read many responses at once and process fewer at a time with
  `process_content/2`.
  """
  @spec read_stored(String.t(), Keyword.t()) :: {:ok, binary()} | {:error, BatchFailure.t()}
  def read_stored(destination, options) when is_binary(destination) and is_list(options) do
    read(destination, Keyword.get(options, :read_options, []))
  end

  @doc """
  Publishes the schedule of `stored.content`, the response `read_stored/2`
  read from `stored.destination`, as `process/2` does once it has read it.
  """
  @spec process_content(%{destination: String.t(), content: binary()}, Keyword.t()) ::
          {:ok, result()} | {:error, BatchFailure.t()}
  def process_content(%{destination: destination, content: content}, options)
      when is_binary(destination) and is_binary(content) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    result =
      with {:ok, parsed} <- parse(destination, content),
           record = Records.build(parsed),
           :ok <- publish(record, Keyword.fetch!(options, :publish_options)) do
        trips = parsed.schedule.trips

        {:ok,
         %{
           destination: destination,
           route_id: parsed.route_id,
           service_date: parsed.service_date,
           request_id: parsed.request_id,
           fetched_at: parsed.fetched_at,
           trip_count: length(trips),
           stop_time_count: Enum.sum_by(trips, &length(&1.stop_times))
         }}
      end

    with {:ok, published} <- result do
      Logger.debug("Route schedule batch published",
        destination: destination,
        request_id: published.request_id,
        route_id: published.route_id,
        service_date: Date.to_iso8601(published.service_date),
        trip_count: published.trip_count,
        stop_time_count: published.stop_time_count
      )
    end

    result
  end

  defp read(destination, read_options) do
    case Reader.read(destination, read_options) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, BatchFailure.read(reason)}
    end
  end

  defp parse(destination, content) do
    case RawRouteScheduleResponse.parse(%{destination: destination, content: content}) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, BatchFailure.parse(reason)}
    end
  end

  defp publish(record, publish_options) do
    case Publisher.publish([record], publish_options) do
      :ok -> :ok
      {:error, reason} -> {:error, BatchFailure.publish(:publish_route_schedule, reason)}
    end
  end
end
