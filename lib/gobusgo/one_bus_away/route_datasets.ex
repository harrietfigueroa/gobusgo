defmodule Gobusgo.OneBusAway.RouteDatasets do
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch

  @dataset "oba/routes"
  @topic RawRouteResponse.StoredEvent.topic()

  @moduledoc """
  The two route datasets as the one dataset a consumer of their shared
  "response stored" topic serves: the routes of an agency and the stops and
  paths of a route. It is both the event module and the processor module
  `Gobusgo.OneBusAway.ResponseTrigger` and
  `Gobusgo.OneBusAway.ResponseConsumer` take, and hands each event and each
  stored response to the dataset it belongs to.

  Both datasets announce their stored responses on `#{@topic}`. An event
  belongs to the dataset whose event module decodes it, and a stored
  response to the dataset whose destinations start with its prefix.
  """

  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.StoredEvent

  @datasets [
    %{
      event: RawRouteResponse.StoredEvent,
      processor: RouteBatch,
      prefix: RawRouteResponse.destination_prefix() <> "/"
    },
    %{
      event: RawRoutePathResponse.StoredEvent,
      processor: RoutePathBatch,
      prefix: RawRoutePathResponse.destination_prefix() <> "/"
    }
  ]

  # Both event modules name one topic, which is what lets one consumer
  # serve them.
  for %{event: event} <- @datasets do
    if event.topic() != @topic do
      raise "#{inspect(event)} announces on #{event.topic()}, another topic than #{@topic}"
    end
  end

  @doc "The topic both datasets announce their stored responses on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The name the two datasets share in logs and dead letters."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns what `value` holds, as the event module of the dataset it belongs
  to decodes it. A value neither dataset decodes returns the reason the
  last one gave.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, StoredEvent.decode_error()}
  def decode(value) when is_binary(value) do
    Enum.reduce_while(@datasets, {:error, :schema_mismatch}, fn %{event: event}, _previous ->
      case event.decode(value) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  @doc """
  Processes the response stored at `destination` with the processor of the
  dataset it belongs to. A destination of neither dataset is a permanent
  failure at the stage `:parse`, with the reason `:destination_mismatch`.
  """
  @spec process(String.t(), Keyword.t()) :: {:ok, map()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    case Enum.find(@datasets, &String.starts_with?(destination, &1.prefix)) do
      %{processor: processor} -> processor.process(destination, options)
      nil -> {:error, BatchFailure.parse(:destination_mismatch)}
    end
  end
end
