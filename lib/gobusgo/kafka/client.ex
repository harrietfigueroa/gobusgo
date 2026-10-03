defmodule Gobusgo.Kafka.Client do
  @connect_timeout_ms 5_000
  @reconnect_cool_down_seconds 1
  @request_timeout_ms 10_000
  @restart_delay_seconds 10

  @moduledoc """
  The brod client the application's Kafka modules share: one named
  connection manager for a list of bootstrap endpoints.

  `start/1` registers the client with brod's own supervisor and returns
  before a broker answers. While no broker is reachable the client stops and
  brod starts it again every #{@restart_delay_seconds} seconds, and every
  call that names it returns an error as a value, so an unreachable broker
  never stops the caller of `start/1`.

  The client creates no topic and starts no producer on its own; a producer
  is started for a topic by the module that publishes to it.
  """

  alias Gobusgo.Assert

  @type endpoint :: {String.t(), :inet.port_number()}

  @doc """
  Starts the client named `client` for `endpoints`. Starting a client that
  is already running is `:ok`.
  """
  @spec start(%{client: atom(), endpoints: [endpoint(), ...]}) :: :ok
  def start(%{client: client, endpoints: [_first | _rest] = endpoints}) when is_atom(client) do
    result =
      :brod.start_client(endpoints, client,
        allow_topic_auto_creation: false,
        auto_start_producers: false,
        connect_timeout: @connect_timeout_ms,
        reconnect_cool_down_seconds: @reconnect_cool_down_seconds,
        request_timeout: @request_timeout_ms,
        restart_delay_seconds: @restart_delay_seconds
      )

    Assert.condition(result == :ok, "brod did not start the client: #{inspect(result)}")
    :ok
  end
end
