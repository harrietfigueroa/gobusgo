defmodule Gobusgo.Kafka.TopicSubscriber do
  @restart_delay_ms_default 10_000
  @value_count_max_default 1_000

  @moduledoc """
  Reads every partition of one Kafka topic from its earliest record, on
  every start, and hands the record values to a subscriber function. It
  joins no consumer group and commits no offset, so each running instance
  reads the whole topic.

  The values of one partition arrive in offset order, at most
  `:value_count_max` per call; the order across partitions is not defined.
  The subscriber is a `{module, function, arguments}` called with
  `arguments` followed by a list of values, and returns `:ok`.

  This process owns a brod topic subscriber and outlives it. When the brod
  subscriber stops (the client is not connected, the topic does not exist,
  the subscriber function exits), this process starts another after
  `:restart_delay_ms`, which reads the topic from its earliest record again.
  The retry has no attempt limit: it is this process's event loop, paced by
  the delay.

  The first stop after a start or after delivered values logs `warning`
  `Kafka topic subscriber stopped`; the stops that follow it in a row log
  nothing.

  ## Options

    * `:name` (required): the name this process registers.
    * `:client` (required): the name of the brod client.
    * `:topic` (required): the topic to read.
    * `:subscriber` (required): the `{module, function, arguments}` to call.
    * `:restart_delay_ms`: defaults to #{@restart_delay_ms_default}.
    * `:value_count_max`: defaults to #{@value_count_max_default}.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert

  defmodule Callback do
    @moduledoc false
    @behaviour :brod_topic_subscriber

    @impl :brod_topic_subscriber
    def init(_topic, state), do: {:ok, [], state}

    @impl :brod_topic_subscriber
    def handle_message(
          _partition,
          {:kafka_message_set, _topic, _set_partition, _offset, messages},
          state
        ) do
      %{owner: owner, subscriber: {module, function, arguments}, value_count_max: count_max} =
        state

      values = for message <- messages, do: elem(message, 3)

      values
      |> Enum.chunk_every(count_max)
      |> Enum.each(fn chunk -> :ok = apply(module, function, arguments ++ [chunk]) end)

      send(owner, :values_delivered)
      {:ok, :ack, state}
    end
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        :client,
        :topic,
        :subscriber,
        restart_delay_ms: @restart_delay_ms_default,
        value_count_max: @value_count_max_default
      ])

    name = Keyword.fetch!(options, :name)
    {module, function, arguments} = Keyword.fetch!(options, :subscriber)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_atom(Keyword.fetch!(options, :client)), "client must be an atom")
    Assert.condition(is_binary(Keyword.fetch!(options, :topic)), "topic must be a string")
    Assert.condition(is_atom(module), "subscriber module must be an atom")
    Assert.condition(is_atom(function), "subscriber function must be an atom")
    Assert.condition(is_list(arguments), "subscriber arguments must be a list")

    Assert.condition(
      Keyword.fetch!(options, :restart_delay_ms) > 0,
      "restart_delay_ms must be positive"
    )

    Assert.condition(
      Keyword.fetch!(options, :value_count_max) > 0,
      "value_count_max must be positive"
    )

    GenServer.start_link(__MODULE__, Map.new(options), name: name)
  end

  def child_spec(options) do
    %{id: Keyword.fetch!(options, :name), start: {__MODULE__, :start_link, [options]}}
  end

  @impl GenServer
  def init(settings) do
    Process.flag(:trap_exit, true)
    {:ok, %{settings: settings, reader: nil, stop_count_in_row: 0}, {:continue, :start_reader}}
  end

  @impl GenServer
  def handle_continue(:start_reader, server), do: {:noreply, start_reader(server)}

  @impl GenServer
  def handle_info(:start_reader, server), do: {:noreply, start_reader(server)}

  def handle_info(:values_delivered, server), do: {:noreply, %{server | stop_count_in_row: 0}}

  def handle_info({:EXIT, reader, reason}, %{reader: reader, settings: settings} = server) do
    if server.stop_count_in_row == 0 do
      Logger.warning("Kafka topic subscriber stopped",
        topic: settings.topic,
        reason: reason_name(reason),
        restart_delay_ms: settings.restart_delay_ms
      )
    end

    Process.send_after(self(), :start_reader, settings.restart_delay_ms)
    {:noreply, %{server | reader: nil, stop_count_in_row: server.stop_count_in_row + 1}}
  end

  # An exit from the process that started this one is a request to stop.
  def handle_info({:EXIT, _other, reason}, server), do: {:stop, reason, server}

  defp start_reader(%{reader: nil, settings: settings} = server) do
    # The client's partition consumers outlive a stopped reader and keep
    # their position. Stopping them makes the new reader start consumers of
    # its own, which begin at the earliest record.
    case :brod_client.stop_consumer(settings.client, settings.topic) do
      :ok -> :ok
      {:error, _not_running} -> :ok
    end

    {:ok, reader} =
      :brod_topic_subscriber.start_link(%{
        client: settings.client,
        topic: settings.topic,
        partitions: :all,
        message_type: :message_set,
        consumer_config: [begin_offset: :earliest, offset_reset_policy: :reset_to_earliest],
        cb_module: Callback,
        init_data: %{
          owner: self(),
          subscriber: settings.subscriber,
          value_count_max: settings.value_count_max
        }
      })

    %{server | reader: reader}
  end

  # The name of an exit reason, without the terms it carries: a reason can
  # hold the record values the subscriber function was called with.
  defp reason_name(reason) do
    case reason do
      name when is_atom(name) -> name
      {name, _detail} when is_atom(name) -> name
      {{name, _detail}, _stack} when is_atom(name) -> name
      _other -> :unrecognized
    end
  end
end
