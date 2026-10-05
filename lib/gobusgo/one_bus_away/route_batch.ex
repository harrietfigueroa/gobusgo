defmodule Gobusgo.OneBusAway.RouteBatch do
  @moduledoc """
  Processes one stored response of an agency's routes: the response at a
  destination, read through `Gobusgo.Reader` and published through
  `Gobusgo.Publisher` as one record that holds every route of the agency.
  This module orchestrates and logs; the stored form of the input lives in
  `Gobusgo.OneBusAway.RawRouteResponse` and the published form in
  `Gobusgo.OneBusAway.RouteBatch.Records`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same record again.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the `:agency_id`,
  the `:request_id` and `:fetched_at` of the fetch, and the `:route_count`.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, or `:publish_routes`. Nothing is published
  for a failure at any stage.

  A call that publishes logs once at `info`. A failure returns to the caller
  and is not logged here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RouteBatch.Records
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          agency_id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          route_count: non_neg_integer()
        }

  @doc "Publishes the routes of the response stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    result =
      with {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, parsed} <- parse(destination, content),
           :ok <- publish(Records.build(parsed), Keyword.fetch!(options, :publish_options)) do
        {:ok,
         %{
           destination: destination,
           agency_id: parsed.agency_id,
           request_id: parsed.request_id,
           fetched_at: parsed.fetched_at,
           route_count: length(parsed.routes)
         }}
      end

    with {:ok, published} <- result do
      Logger.info("Route batch published",
        destination: destination,
        request_id: published.request_id,
        agency_id: published.agency_id,
        route_count: published.route_count
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
    case RawRouteResponse.parse(%{destination: destination, content: content}) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, BatchFailure.parse(reason)}
    end
  end

  defp publish(record, publish_options) do
    case Publisher.publish([record], publish_options) do
      :ok -> :ok
      {:error, reason} -> {:error, BatchFailure.publish(:publish_routes, reason)}
    end
  end
end
