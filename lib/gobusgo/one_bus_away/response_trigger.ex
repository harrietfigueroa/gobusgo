defmodule Gobusgo.OneBusAway.ResponseTrigger do
  @attempt_deadline_ms_default 10_000
  @dead_letter_attempt_count_max 3

  @moduledoc """
  Handles one consumed "response stored" record of one dataset: processes
  the stored response the event names with the dataset's processor, retries
  in place, and dead-letters the record when it gives up. This module
  orchestrates and logs; the retry rules live in
  `Gobusgo.OneBusAway.ResponseTrigger.Policy` and the dead-letter record in
  `Gobusgo.DeadLetter`.

  A dataset is two modules. The event module has `dataset/0`, the name of
  the dataset, and `decode/1`, which returns the `:event_id`, the
  `:destination`, and the `:request_id` of a "response stored" value or the
  reason it is none. The processor module has `process/2`, which takes the
  destination and returns `{:ok, result}` or
  `{:error, failure}` with a `t:Gobusgo.OneBusAway.BatchFailure.t/0`.

  `handle/2` runs in the calling process and returns once the outcome of the
  record is final. Each attempt runs as a task under the given task
  supervisor and is killed at its deadline, so a crashed or stalled attempt
  comes back as an outcome.

  ## Results

    * `:processed` — the processor published the stored response.
    * `:dead_lettered` — the record is on its dead-letter topic, key and
      value as consumed.
    * `{:error, {:dead_letter_unpublished, reason}}` — the consumer gave up
      on the record and #{@dead_letter_attempt_count_max} tries to publish
      its dead-letter record failed; `reason` is the last
      `t:Gobusgo.Publisher.error_reason/0`. The record is neither processed
      nor dead-lettered.

  A record whose value is not a "response stored" event of the dataset is
  dead-lettered without an attempt.

  Each call logs at most once: nothing when the first attempt processes the
  response, `warning` when a later attempt does, `error` when the record is
  dead-lettered, and `error` when its dead-letter record is not published.
  Every line carries the `dataset`.

  ## Options

    * `:event` (required): the dataset's event module.
    * `:processor` (required): the dataset's processor module.
    * `:consumer_group` (required): the name of the consumer group, for the
      dead-letter record.
    * `:task_supervisor` (required): the `Task.Supervisor` the attempts run
      under.
    * `:attempt_deadline_ms`: the bound on one attempt. Defaults to
      #{@attempt_deadline_ms_default}.
    * `:retry_delay_ms_base`: the window of the first retry delay. Defaults
      to `Gobusgo.OneBusAway.ResponseTrigger.Policy.retry_delay_ms_base/0`.
    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`, for the
      processed records and the dead-letter record alike.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.DeadLetter
  alias Gobusgo.OneBusAway.ResponseTrigger.Policy
  alias Gobusgo.Publisher

  @type result ::
          :processed
          | :dead_lettered
          | {:error, {:dead_letter_unpublished, Publisher.error_reason()}}

  @doc "Processes the stored response that `consumed` names, or dead-letters `consumed`."
  @spec handle(DeadLetter.consumed(), Keyword.t()) :: result()
  def handle(%{value: value} = consumed, options) when is_binary(value) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :event,
        :processor,
        :consumer_group,
        :task_supervisor,
        attempt_deadline_ms: @attempt_deadline_ms_default,
        retry_delay_ms_base: Policy.retry_delay_ms_base(),
        read_options: [],
        publish_options: [],
        clock: &DateTime.utc_now/0
      ])

    deadline_ms = Keyword.fetch!(options, :attempt_deadline_ms)
    event_module = Keyword.fetch!(options, :event)
    Assert.condition(is_atom(event_module), "event must be a module")
    Assert.condition(is_atom(Keyword.fetch!(options, :processor)), "processor must be a module")

    Assert.condition(
      is_binary(Keyword.fetch!(options, :consumer_group)),
      "consumer_group is required"
    )

    Assert.condition(deadline_ms > 0, "attempt_deadline_ms must be positive, got: #{deadline_ms}")

    first_attempt_at = Keyword.fetch!(options, :clock).()

    case event_module.decode(value) do
      {:ok, event} ->
        case attempt(event, options) do
          {:finished, attempt_count} ->
            log_processed(%{consumed: consumed, event: event}, attempt_count, options)
            :processed

          {:dead_letter, failure, last_attempt_at} ->
            times = %{first_attempt_at: first_attempt_at, last_attempt_at: last_attempt_at}

            dead_letter(
              %{consumed: consumed, event: event, failure: failure, times: times},
              options
            )
        end

      {:error, reason} ->
        times = %{first_attempt_at: first_attempt_at, last_attempt_at: first_attempt_at}
        failure = Policy.rejection(reason)
        dead_letter(%{consumed: consumed, event: nil, failure: failure, times: times}, options)
    end
  end

  defp attempt(%{destination: destination}, options) do
    clock = Keyword.fetch!(options, :clock)
    delay_ms_base = Keyword.fetch!(options, :retry_delay_ms_base)

    decision =
      Enum.reduce_while(1..Policy.attempt_count_max(), nil, fn attempt_count, nil ->
        last_attempt_at = clock.()
        outcome = run(destination, options)

        case Policy.next(%{attempt_count: attempt_count, outcome: outcome}) do
          :finished ->
            {:halt, {:finished, attempt_count}}

          {:dead_letter, failure} ->
            {:halt, {:dead_letter, failure, last_attempt_at}}

          :retry ->
            sleep(%{attempt_count: attempt_count, delay_ms_base: delay_ms_base})
            {:cont, nil}
        end
      end)

    Assert.condition(decision != nil, "the last attempt must end in a decision")
    decision
  end

  defp run(destination, options) do
    process_options = Keyword.take(options, [:read_options, :publish_options])
    processor = Keyword.fetch!(options, :processor)

    task =
      options
      |> Keyword.fetch!(:task_supervisor)
      |> Task.Supervisor.async_nolink(fn -> processor.process(destination, process_options) end)

    deadline_ms = Keyword.fetch!(options, :attempt_deadline_ms)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      nil -> :deadline_exceeded
      {:exit, _reason} -> :crashed
    end
  end

  defp dead_letter(%{consumed: consumed, failure: failure, times: times} = given_up, options) do
    record =
      DeadLetter.record(%{
        consumed: consumed,
        consumer_group: Keyword.fetch!(options, :consumer_group),
        failure: failure,
        first_attempt_at: times.first_attempt_at,
        last_attempt_at: times.last_attempt_at
      })

    case publish_dead_letter(record, options) do
      :ok ->
        log_given_up("Response trigger dead-lettered", given_up, dataset(options))
        :dead_lettered

      {:error, reason} ->
        log_given_up(
          "Response trigger dead letter not published",
          given_up,
          dataset(options) ++ [reason: inspect(reason)]
        )

        {:error, {:dead_letter_unpublished, reason}}
    end
  end

  defp publish_dead_letter(record, options) do
    publish_options = Keyword.fetch!(options, :publish_options)
    delay_ms_base = Keyword.fetch!(options, :retry_delay_ms_base)

    Enum.reduce_while(1..@dead_letter_attempt_count_max, nil, fn attempt_count, _previous ->
      case Publisher.publish([record], publish_options) do
        :ok ->
          {:halt, :ok}

        {:error, reason} when attempt_count < @dead_letter_attempt_count_max ->
          sleep(%{attempt_count: attempt_count, delay_ms_base: delay_ms_base})
          {:cont, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sleep(%{attempt_count: attempt_count, delay_ms_base: delay_ms_base}) do
    delay_ms =
      Policy.retry_delay_ms(%{
        attempt_count: attempt_count,
        delay_ms_base: delay_ms_base,
        jitter: :rand.uniform()
      })

    Process.sleep(delay_ms)
  end

  defp dataset(options), do: [dataset: Keyword.fetch!(options, :event).dataset()]

  defp log_processed(_handled, 1, _options), do: :ok

  defp log_processed(%{consumed: consumed, event: event}, attempt_count, options) do
    Logger.warning(
      "Response trigger processed after retries",
      dataset(options) ++
        [attempt_count: attempt_count] ++ position(consumed) ++ event_properties(event)
    )
  end

  defp log_given_up(message, %{consumed: consumed, event: event, failure: failure}, properties) do
    Logger.error(
      message,
      [
        error_code: failure.error_code,
        attempt_count: failure.attempt_count,
        retries_exhausted: failure.retries_exhausted
      ] ++ properties ++ position(consumed) ++ event_properties(event)
    )
  end

  defp position(%{topic: topic, partition: partition, offset: offset}) do
    [topic: topic, partition: partition, offset: offset]
  end

  defp event_properties(nil), do: []

  defp event_properties(%{event_id: event_id, destination: destination, request_id: request_id}) do
    [event_id: event_id, destination: destination, request_id: request_id]
  end
end
