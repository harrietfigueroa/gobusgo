defmodule Gobusgo.Publisher.Kafka do
  @deadline_ms_default 15_000
  @record_bytes_max 1_000_000

  @ack_timeout_ms 10_000
  @linger_count_max 100
  @linger_ms_max 5
  @partition_buffer_limit 256
  @partition_onwire_limit 1
  @produce_retries_max 3
  @produce_retry_backoff_ms 500
  @required_acks_all -1

  @moduledoc """
  A publisher backend that produces records to Kafka topics through a brod
  client started elsewhere, such as by `Gobusgo.Kafka.Client.start/1`.

  A record's `:key` is the Kafka key and chooses the partition by brod's
  `:hash` partitioner, so records of one key stay on one partition in
  publish order. `:headers` become Kafka headers. A tombstone, a record
  with an empty value, is produced with a null value, which a compacted
  topic deletes the key for. Every record is sent
  before the first acknowledgement is awaited, and the call returns once
  every partition leader has acknowledged with all in-sync replicas.

  ## Outcomes

    * `:ok` — every record is acknowledged.
    * `{:error, :record_too_large}` — a record's key, value, and headers
      together exceed #{@record_bytes_max} bytes. Nothing is sent.
    * `{:error, :unknown_topic}` — the broker has no such topic. Topics are
      never created from here.
    * `{:error, :unavailable}` — the client is not connected, or a
      producer stopped before acknowledging.
    * `{:error, :timeout}` — the acknowledgements did not all arrive within
      the deadline. Records sent before it may still be stored.

  ## Options

    * `:client`: the name of the brod client. Defaults to the application
      config key `:client` under `Gobusgo.Publisher.Kafka`.
    * `:deadline_ms`: the bound on the whole call. Defaults to
      #{@deadline_ms_default}.
  """

  @behaviour Gobusgo.Publisher

  alias Gobusgo.Assert

  @impl Gobusgo.Publisher
  def publish(records, options) when is_list(records) and is_list(options) do
    options = Keyword.validate!(options, [:client, deadline_ms: @deadline_ms_default])
    client = Keyword.get_lazy(options, :client, &configured_client/0)
    deadline_ms = Keyword.fetch!(options, :deadline_ms)
    Assert.condition(is_atom(client), "client must be an atom, got: #{inspect(client)}")
    Assert.condition(deadline_ms > 0, "deadline_ms must be positive, got: #{deadline_ms}")

    if Enum.all?(records, &(record_bytes(&1) <= @record_bytes_max)) do
      # The acknowledgements arrive as messages; a task of its own keeps the
      # ones that come after the deadline out of the caller's mailbox.
      task = Task.async(fn -> produce(client, records, deadline_ms) end)

      case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> raise Assert.AssertionError, message: "produce task exited"
      end
    else
      {:error, :record_too_large}
    end
  end

  defp configured_client do
    :gobusgo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:client)
  end

  defp record_bytes(%{key: key, value: value, headers: headers}) do
    header_bytes =
      for {name, text} <- headers, reduce: 0, do: (sum -> sum + byte_size(name) + byte_size(text))

    byte_size(key) + byte_size(value) + header_bytes
  end

  defp produce(client, records, deadline_ms) do
    topics = records |> Enum.map(& &1.topic) |> Enum.uniq()

    with :ok <- start_producers(client, topics),
         {:ok, call_references} <- send_records(client, records) do
      await(call_references, deadline_ms)
    end
  end

  defp start_producers(client, topics) do
    Enum.reduce_while(topics, :ok, fn topic, :ok ->
      result =
        :brod.start_producer(client, topic,
          ack_timeout: @ack_timeout_ms,
          compression: :gzip,
          max_linger_count: @linger_count_max,
          max_linger_ms: @linger_ms_max,
          max_retries: @produce_retries_max,
          partition_buffer_limit: @partition_buffer_limit,
          partition_onwire_limit: @partition_onwire_limit,
          required_acks: @required_acks_all,
          retry_backoff_ms: @produce_retry_backoff_ms
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, error_reason(reason)}}
      end
    end)
  end

  defp send_records(client, records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, call_references} ->
      message = %{value: record.value, headers: record.headers}

      case :brod.produce(client, record.topic, :hash, record.key, message) do
        {:ok, call_reference} -> {:cont, {:ok, [call_reference | call_references]}}
        {:error, reason} -> {:halt, {:error, error_reason(reason)}}
      end
    end)
  end

  defp await(call_references, deadline_ms) do
    Enum.reduce_while(call_references, :ok, fn call_reference, :ok ->
      case :brod.sync_produce_request(call_reference, deadline_ms) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, error_reason(reason)}}
      end
    end)
  end

  defp error_reason(reason) do
    case reason do
      :timeout -> :timeout
      :unknown_topic_or_partition -> :unknown_topic
      :client_down -> :unavailable
      :leader_not_available -> :unavailable
      {:producer_down, _reason} -> :unavailable
      {:producer_not_found, _topic} -> :unavailable
      {:producer_not_found, _topic, _partition} -> :unavailable
      other -> other
    end
  end
end
