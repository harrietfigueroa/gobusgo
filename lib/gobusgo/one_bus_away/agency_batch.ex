defmodule Gobusgo.OneBusAway.AgencyBatch do
  @input_count_max 10_000
  @listed_count_max 100_000

  @moduledoc """
  Processes one batch of stored agency discovery responses: every response
  whose fetch time falls in a half-open window, read through `Gobusgo.Reader`
  and published as one output through `Gobusgo.Writer`. This module
  orchestrates and logs; the window rules live in
  `Gobusgo.OneBusAway.AgencyBatch.Window`, the stored form of an input in
  `Gobusgo.OneBusAway.RawAgencyResponse`, and the published form in
  `Gobusgo.OneBusAway.AgencyBatch.Output`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them.

  ## Usage

      request = %{
        window: %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]},
        trigger_id: Gobusgo.RequestId.generate(),
        reprocess: false
      }

      case Gobusgo.OneBusAway.AgencyBatch.process(request, []) do
        {:ok, %{outcome: outcome, destination: destination}} -> {outcome, destination}
        {:error, reason} -> reason
      end

  ## Inputs

  The inputs of a window are the stored responses in the date partitions the
  window touches whose name carries a fetch time inside the window. They are
  read one at a time in destination order. A window holds at most
  #{@input_count_max} inputs, and its partitions at most #{@listed_count_max}
  destinations.

  An input is valid when `Gobusgo.OneBusAway.RawAgencyResponse.parse/1`
  accepts it. An invalid input is skipped and recorded in the output with
  its reason. A destination in a partition whose name carries no fetch time
  is skipped as `:destination_mismatch` without being read.

  ## Results

  `{:ok, result}`, where `result` holds the `:outcome`, the `:batch_id`, the
  `:destination`, and the `:input_count`, `:skipped_count`, and
  `:duplicate_count` of the run. The outcomes:

    * `:published` — one output is stored at `:destination`.
    * `:published_with_skips` — one output is stored, built from the valid
      inputs, and at least one input was skipped.
    * `:no_input` — the window holds no input; nothing is stored and
      `:destination` is `nil`.
    * `:already_published` — the window has an output and `reprocess` is
      false; nothing is read or stored, and `:destination` names the output
      that sorts last.

  `{:error, reason}`, with nothing stored:

    * `:window_open` — the window ends after the current time.
    * `:all_inputs_invalid` — the window holds inputs and none is valid.
    * `:too_many_inputs` — the window or its partitions exceed the bounds.
    * `{:read, reason}` — discovering or reading failed; `reason` is a
      `t:Gobusgo.Reader.error_reason/0`. An input that is gone between
      discovery and reading is `{:read, :not_found}`.
    * `{:write, reason}` — the writer did not store the output; `reason` is
      a `t:Gobusgo.Writer.error_reason/0`.

  A request that breaks its contract raises `Gobusgo.Assert.AssertionError`.

  With `reprocess: true` the check for an existing output is skipped, and the
  run stores its own output beside any earlier one.

  Each call logs its outcome once: `info` when it finishes, `warning` when
  it publishes with skips, `error` when it fails.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2` and
      `Gobusgo.Reader.discover/2`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:clock`: a zero-arity function returning the current UTC `DateTime`.
      It supplies the processing time and decides whether the window ended.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyBatch.Output
  alias Gobusgo.OneBusAway.AgencyBatch.Window
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.Reader
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @type request :: %{window: Window.t(), trigger_id: RequestId.t(), reprocess: boolean()}

  @type outcome :: :published | :published_with_skips | :no_input | :already_published

  @type result :: %{
          outcome: outcome(),
          batch_id: String.t(),
          destination: String.t() | nil,
          input_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          duplicate_count: non_neg_integer()
        }

  @type error ::
          :window_open
          | :all_inputs_invalid
          | :too_many_inputs
          | {:read, Reader.error_reason()}
          | {:write, Writer.error_reason()}

  @page_limit Reader.discovery_limit_max()
  @page_count_max ceil(@listed_count_max / @page_limit)
  @utc_time_zone "Etc/UTC"

  @doc "Inputs allowed in one window."
  @spec input_count_max() :: pos_integer()
  def input_count_max, do: @input_count_max

  @doc "Processes the batch `request.window` defines and publishes at most one output."
  @spec process(request(), Keyword.t()) :: {:ok, result()} | {:error, error()}
  def process(%{window: window, trigger_id: trigger_id, reprocess: reprocess}, options)
      when is_list(options) do
    options =
      Keyword.validate!(options, read_options: [], write_options: [], clock: &DateTime.utc_now/0)

    Window.assert_valid(window)
    Assert.condition(RequestId.valid?(trigger_id), "trigger_id must be a UUID version 7")
    Assert.condition(is_boolean(reprocess), "reprocess must be a boolean")

    context = %{
      window: window,
      batch_id: Window.id(window),
      trigger_id: trigger_id,
      reprocess: reprocess,
      processed_at: now(Keyword.fetch!(options, :clock)),
      read_options: Keyword.fetch!(options, :read_options),
      write_options: Keyword.fetch!(options, :write_options)
    }

    result =
      if Window.closed?(window, context.processed_at) do
        run(context)
      else
        {:error, :window_open}
      end

    log(result, context)
    result
  end

  defp now(clock) do
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")
    %DateTime{time_zone: time_zone} = now = clock.()
    Assert.condition(time_zone == @utc_time_zone, "clock must return UTC, got: #{time_zone}")
    DateTime.truncate(now, :second)
  end

  defp run(%{reprocess: true} = context), do: process_inputs(context)

  defp run(%{reprocess: false} = context) do
    case latest_output(context) do
      {:ok, nil} -> process_inputs(context)
      {:ok, destination} -> {:ok, result(:already_published, destination, context)}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp latest_output(%{batch_id: batch_id, read_options: read_options}) do
    request = %{
      prefix: Output.destination_prefix(batch_id),
      limit: 1,
      order: :descending,
      cursor: nil
    }

    with {:ok, %{destinations: destinations}} <- Reader.discover(request, read_options) do
      {:ok, List.first(destinations)}
    end
  end

  defp process_inputs(context) do
    with {:ok, candidates} <- select(context),
         {:ok, loaded} <- load(candidates, context.read_options) do
      publish(loaded, context)
    end
  end

  # A candidate is `{destination, :named}` when its name carries a fetch time
  # inside the window, and `{destination, :unnamed}` when it carries none.
  defp select(%{window: window, read_options: read_options}) do
    with {:ok, listed} <- list(Window.dates(window), read_options) do
      candidates = Enum.flat_map(listed, &candidate(&1, window))

      if length(candidates) <= @input_count_max do
        {:ok, candidates}
      else
        {:error, :too_many_inputs}
      end
    end
  end

  defp candidate(destination, window) do
    case RawAgencyResponse.fetched_at(destination) do
      {:ok, fetched_at} ->
        if Window.member?(window, fetched_at), do: [{destination, :named}], else: []

      :error ->
        [{destination, :unnamed}]
    end
  end

  # One page budget covers all the partitions of the window, so the listing
  # is bounded whatever the number of dates.
  defp list(dates, read_options) do
    start = {:ok, [], @page_count_max}

    dates
    |> Enum.reduce_while(start, fn date, {:ok, listed, pages_left} ->
      prefix = RawAgencyResponse.partition_prefix(date)

      case list_partition(prefix, pages_left, read_options) do
        {:ok, destinations, pages_left} -> {:cont, {:ok, listed ++ destinations, pages_left}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, listed, _pages_left} -> {:ok, listed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_partition(prefix, pages_left, read_options) do
    start = {:more, nil, [], pages_left}

    1..pages_left//1
    |> Enum.reduce_while(start, fn _page, {:more, cursor, pages, pages_left} ->
      request = %{prefix: prefix, limit: @page_limit, order: :ascending, cursor: cursor}

      case Reader.discover(request, read_options) do
        {:ok, %{destinations: destinations, cursor: nil}} ->
          {:halt, {:done, [destinations | pages], pages_left - 1}}

        {:ok, %{destinations: destinations, cursor: next}} ->
          {:cont, {:more, next, [destinations | pages], pages_left - 1}}

        {:error, reason} ->
          {:halt, {:error, {:read, reason}}}
      end
    end)
    |> case do
      {:done, pages, pages_left} -> {:ok, pages |> Enum.reverse() |> Enum.concat(), pages_left}
      {:more, _cursor, _pages, _pages_left} -> {:error, :too_many_inputs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load(candidates, read_options) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, loaded} ->
      case load_candidate(candidate, read_options) do
        {:error, reason} -> {:halt, {:error, {:read, reason}}}
        entry -> {:cont, {:ok, [entry | loaded]}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_candidate({destination, :unnamed}, _read_options) do
    {:skipped, %{destination: destination, reason: :destination_mismatch}}
  end

  defp load_candidate({destination, :named}, read_options) do
    with {:ok, content} <- Reader.read(destination, read_options) do
      case RawAgencyResponse.parse(%{destination: destination, content: content}) do
        {:ok, input} -> {:valid, input}
        {:error, reason} -> {:skipped, %{destination: destination, reason: reason}}
      end
    end
  end

  defp publish(loaded, context) do
    inputs = for {:valid, input} <- loaded, do: input
    skipped = for {:skipped, entry} <- loaded, do: entry

    case {loaded, inputs} do
      {[], []} -> {:ok, result(:no_input, nil, context)}
      {_loaded, []} -> {:error, :all_inputs_invalid}
      {_loaded, _inputs} -> write(inputs, skipped, context)
    end
  end

  defp write(inputs, skipped, context) do
    %{destination: destination, content: content, duplicate_count: duplicate_count} =
      Output.build(%{
        window: context.window,
        inputs: inputs,
        skipped: skipped,
        processed_at: context.processed_at,
        trigger_id: context.trigger_id
      })

    case Writer.write(%{destination: destination, content: content}, context.write_options) do
      :ok ->
        outcome = if skipped == [], do: :published, else: :published_with_skips

        {:ok,
         %{
           result(outcome, destination, context)
           | input_count: length(inputs),
             skipped_count: length(skipped),
             duplicate_count: duplicate_count
         }}

      {:error, reason} ->
        {:error, {:write, reason}}
    end
  end

  defp result(outcome, destination, %{batch_id: batch_id}) do
    %{
      outcome: outcome,
      batch_id: batch_id,
      destination: destination,
      input_count: 0,
      skipped_count: 0,
      duplicate_count: 0
    }
  end

  defp log({:ok, %{outcome: :published_with_skips} = result}, context) do
    Logger.warning("Agency batch published with skips", properties(result, context))
  end

  defp log({:ok, result}, context) do
    Logger.info("Agency batch finished", properties(result, context))
  end

  defp log({:error, reason}, %{batch_id: batch_id, trigger_id: trigger_id}) do
    Logger.error("Agency batch failed",
      batch_id: batch_id,
      trigger_id: trigger_id,
      reason: inspect(reason)
    )
  end

  defp properties(result, %{trigger_id: trigger_id}) do
    [
      outcome: result.outcome,
      batch_id: result.batch_id,
      trigger_id: trigger_id,
      destination: result.destination,
      input_count: result.input_count,
      skipped_count: result.skipped_count,
      duplicate_count: result.duplicate_count
    ]
  end
end
