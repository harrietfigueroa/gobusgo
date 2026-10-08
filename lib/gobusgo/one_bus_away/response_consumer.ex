defmodule Gobusgo.OneBusAway.ResponseConsumer do
  @moduledoc """
  Processes the stored response each "response stored" event of one dataset
  names, in the calling process. This module decodes and hands over; the
  event and the processing live in the dataset's modules.

  A dataset is `%{event: module, processor: module}`. The event module has
  `dataset/0`, the name of the dataset, and `decode/1`, which returns the
  `:event_id`, the `:destination`, and the `:request_id` of a "response
  stored" value or the reason it is none. The processor module has
  `process/2`, which takes the destination and returns `{:ok, result}` or
  `{:error, failure}` with a `t:Gobusgo.OneBusAway.BatchFailure.t/0`.

  `consume/3` takes record values, the bytes the event module's `record/1`
  builds, and processes them in order. A value that is not a "response
  stored" event of the dataset is skipped. A stored response that fails to
  process is left failed and the next value is taken, and a later fetch
  brings readers up to date.

  Each call logs `error` once per stored response that fails to process,
  and `warning` once with the count of skipped values, each with the
  `dataset`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Publisher

  @type dataset :: %{event: module(), processor: module()}

  @doc """
  Processes the stored response of every event in `values`, at most
  `Gobusgo.Publisher.record_count_max/0` record values. `process_options`
  are the options of the processor's `process/2`.
  """
  @spec consume(dataset(), Keyword.t(), [binary()]) :: :ok
  def consume(%{event: event, processor: processor}, process_options, values)
      when is_atom(event) and is_atom(processor) and is_list(process_options) and is_list(values) do
    count = length(values)

    Assert.condition(
      count <= Publisher.record_count_max(),
      "values must hold at most #{Publisher.record_count_max()} records, got: #{count}"
    )

    invalid_count =
      Enum.reduce(values, 0, fn value, invalid_count ->
        case event.decode(value) do
          {:ok, %{destination: destination}} ->
            process(%{event: event, processor: processor}, destination, process_options)
            invalid_count

          {:error, _reason} ->
            invalid_count + 1
        end
      end)

    if invalid_count >= 1 do
      Logger.warning("Response consumer skipped invalid events",
        dataset: event.dataset(),
        invalid_count: invalid_count
      )
    end

    :ok
  end

  defp process(%{event: event, processor: processor}, destination, process_options) do
    case processor.process(destination, process_options) do
      {:ok, _result} ->
        :ok

      {:error, %{class: class} = failure} when class in [:permanent, :transient] ->
        Logger.error("Response consumer failed",
          dataset: event.dataset(),
          destination: destination,
          stage: failure.stage,
          error_code: failure.error_code,
          class: class
        )
    end
  end
end
