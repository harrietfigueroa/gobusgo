defmodule Gobusgo.OneBusAway.ResponseTrigger.KafkaConsumer do
  @processor_count 4
  @demand_max 1
  @receive_interval_ms 1_000
  @fetch_wait_ms_max 100
  @session_timeout_seconds 30
  @rebalance_timeout_seconds 30

  @moduledoc """
  The Broadway pipeline that consumes "response stored" records from Kafka
  as one consumer group and hands each to
  `Gobusgo.OneBusAway.ResponseTrigger.handle/2`.

  Kafka delivers at least once. The records of one partition go to one of
  #{@processor_count} processors in offset order, and a processor asks for
  #{@demand_max} record at a time, so pending records wait in Kafka.

  A record is acknowledged once it is processed or dead-lettered, and its
  offset is committed after every earlier offset of its partition is
  acknowledged. When the dead-letter record of a record cannot be published,
  the processor that holds it is killed with the record unacknowledged: the
  partition's committed offset stays before that record, and Kafka delivers
  it again from there when the group next assigns the partition, such as
  after a restart.

  A group without a committed offset starts from the earliest record. The
  pipeline polls its partitions every #{@receive_interval_ms} ms.

  ## Options

    * `:name` (required): the name the pipeline registers.
    * `:producer` (required): the Broadway producer as `{module, options}`;
      `producer/1` builds the Kafka one.
    * `:event`, `:processor`, `:consumer_group`, `:task_supervisor`
      (required), and
      `:attempt_deadline_ms`, `:retry_delay_ms_base`, `:read_options`,
      `:publish_options`: the options of
      `Gobusgo.OneBusAway.ResponseTrigger.handle/2`.
  """

  use Broadway

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.ResponseTrigger

  @doc """
  The Broadway producer that consumes `topic` from the brokers at
  `endpoints` as a member of `consumer_group`.
  """
  @spec producer(%{
          endpoints: [{String.t(), :inet.port_number()}, ...],
          consumer_group: String.t(),
          topic: String.t()
        }) :: {module(), Keyword.t()}
  def producer(%{endpoints: endpoints, consumer_group: consumer_group, topic: topic}) do
    options = [
      hosts: endpoints,
      group_id: consumer_group,
      topics: [topic],
      receive_interval: @receive_interval_ms,
      offset_commit_on_ack: true,
      begin_offset: :assigned,
      # The library's default is :latest, which skips the records that are
      # pending when a group first starts or has lost its offsets.
      offset_reset_policy: :earliest,
      group_config: [
        session_timeout_seconds: @session_timeout_seconds,
        rebalance_timeout_seconds: @rebalance_timeout_seconds
      ],
      # A poll fetches the assigned partitions one after another, and an
      # empty partition holds its fetch open for this long.
      fetch_config: [max_wait_time: @fetch_wait_ms_max],
      client_config: [allow_topic_auto_creation: false]
    ]

    {BroadwayKafka.Producer, options}
  end

  @doc "Starts the pipeline. See the module documentation for `options`."
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    {name, options} = Keyword.pop!(options, :name)
    {{producer_module, producer_options}, handle_options} = Keyword.pop!(options, :producer)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")

    Broadway.start_link(__MODULE__,
      name: name,
      context: %{handle_options: handle_options},
      producer: [module: {producer_module, producer_options}, concurrency: 1],
      processors: [default: [concurrency: @processor_count, max_demand: @demand_max]]
    )
  end

  @impl Broadway
  def handle_message(_processor, %Broadway.Message{} = message, %{handle_options: handle_options}) do
    %{topic: topic, partition: partition, offset: offset, key: key, headers: headers} =
      message.metadata

    consumed = %{
      topic: topic,
      partition: partition,
      offset: offset,
      key: key,
      value: message.data,
      headers: headers
    }

    case ResponseTrigger.handle(consumed, handle_options) do
      :processed ->
        message

      :dead_lettered ->
        message

      {:error, {:dead_letter_unpublished, _reason}} ->
        # Broadway acknowledges a message whose handler returns, raises, or
        # exits; only a killed processor leaves the offset uncommitted.
        Process.exit(self(), :kill)
        Process.sleep(:infinity)
    end
  end
end
