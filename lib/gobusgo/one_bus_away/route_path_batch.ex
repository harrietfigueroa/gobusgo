defmodule Gobusgo.OneBusAway.RoutePathBatch do
  @moduledoc """
  Processes one stored response of a route's stops and paths: the response
  at a destination, read through `Gobusgo.Reader` and published through
  `Gobusgo.Publisher` as two records in one call: one that holds the
  route's paths, then one that holds its stops. This module orchestrates and
  logs; the stored form of the input lives in
  `Gobusgo.OneBusAway.RawRoutePathResponse` and the published forms in
  `Gobusgo.OneBusAway.RoutePathBatch.Records` and
  `Gobusgo.OneBusAway.RoutePathBatch.StopRecords`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same records again.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the `:route_id`,
  the `:request_id` and `:fetched_at` of the fetch, the `:polyline_count` of
  the whole route, and the `:stop_count` of its stops and their parent stops
  together.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, or `:publish_route_path`. Nothing is
  published for a failure at `:read` or `:parse`. After a failure at
  `:publish_route_path` either record may be published, as the publisher
  contract says of a failed call.

  A call that publishes logs once at `debug`: a refresh publishes the
  records of every route. A failure returns to the caller and is not logged
  here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RoutePathBatch.Records
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          route_id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          polyline_count: non_neg_integer(),
          stop_count: non_neg_integer()
        }

  @doc "Publishes the paths and the stops of the response stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    result =
      with {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, parsed} <- parse(destination, content),
           records = [Records.build(parsed), StopRecords.build(parsed)],
           :ok <- publish(records, Keyword.fetch!(options, :publish_options)) do
        {:ok,
         %{
           destination: destination,
           route_id: parsed.route_id,
           request_id: parsed.request_id,
           fetched_at: parsed.fetched_at,
           polyline_count: length(parsed.route_path.polylines),
           stop_count: length(parsed.route_path.stops) + length(parsed.route_path.parent_stops)
         }}
      end

    with {:ok, published} <- result do
      Logger.debug("Route path batch published",
        destination: destination,
        request_id: published.request_id,
        route_id: published.route_id,
        polyline_count: published.polyline_count,
        stop_count: published.stop_count
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
    case RawRoutePathResponse.parse(%{destination: destination, content: content}) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, BatchFailure.parse(reason)}
    end
  end

  defp publish(records, publish_options) do
    case Publisher.publish(records, publish_options) do
      :ok -> :ok
      {:error, reason} -> {:error, BatchFailure.publish(:publish_route_path, reason)}
    end
  end
end
