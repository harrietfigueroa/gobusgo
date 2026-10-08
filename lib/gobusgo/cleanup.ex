defmodule Gobusgo.Cleanup do
  @delete_count_max_default 20_000
  @page_count_max 100

  @moduledoc """
  One run of the cleanup of stored content: for each rule of
  `Gobusgo.Retention` it discovers the dataset's content through
  `Gobusgo.Reader`, the oldest day first, and deletes what the rule calls
  expired through `Gobusgo.Deleter`, until it reaches content the rule
  keeps.

  A run is bounded. It tries at most `delete_count_max` deletions, by
  default #{@delete_count_max_default}, and reads at most #{@page_count_max}
  pages of destinations. Past either bound it deletes nothing more and only
  looks whether the datasets left hold expired content, which the summary
  reports as `backlog`.

  A deletion that fails is counted and the run goes on. Content that is
  gone by the time it is deleted is no failure. A dataset whose discovery
  fails is counted and the run goes on with the next.

  A run logs one line: `Stored content cleanup finished` at `info`,
  `Stored content cleanup finished degraded` at `warning` when a deletion or
  a discovery failed, and `Stored content cleanup failed` at `error` when
  the discovery of every dataset failed, with the summary's counts.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Deleter
  alias Gobusgo.Reader
  alias Gobusgo.Retention

  @typedoc """
  What one run did. `deleted_count` is the content deleted, `failed_count`
  the deletions that failed, `unrecognized_count` the destinations met whose
  day no rule could read, `discovery_failed_count` the datasets whose
  discovery failed, and `backlog` whether expired content is left behind
  the run's bounds.
  """
  @type summary :: %{
          deleted_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          unrecognized_count: non_neg_integer(),
          discovery_failed_count: non_neg_integer(),
          backlog: boolean()
        }

  @doc """
  Runs the cleanup under `rules`. `options[:today]` is the UTC date the
  rules judge by, today's by default, `options[:delete_count_max]` replaces
  the default above, and `options[:read_options]` and
  `options[:delete_options]` are the options of `Gobusgo.Reader.discover/2`
  and `Gobusgo.Deleter.delete/2`. Returns `{:error, :nothing_examined}` when
  the discovery of every dataset failed.
  """
  @spec run([Retention.rule(), ...], Keyword.t()) ::
          {:ok, summary()} | {:error, :nothing_examined}
  def run([_first | _rest] = rules, options \\ []) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :today,
        delete_count_max: @delete_count_max_default,
        read_options: [],
        delete_options: []
      ])

    Enum.each(rules, &Retention.assert_rule/1)
    today = Keyword.get_lazy(options, :today, &Date.utc_today/0)
    delete_count_max = Keyword.fetch!(options, :delete_count_max)
    Assert.condition(match?(%Date{}, today), "today must be a date, got: #{inspect(today)}")
    Assert.condition(is_integer(delete_count_max), "delete_count_max must be an integer")
    Assert.condition(delete_count_max >= 1, "delete_count_max must be positive")

    context = %{
      today: today,
      read_options: Keyword.fetch!(options, :read_options),
      delete_options: Keyword.fetch!(options, :delete_options)
    }

    run = %{
      deleted_count: 0,
      failed_count: 0,
      unrecognized_count: 0,
      discovery_failed_count: 0,
      backlog: false,
      attempts_left: delete_count_max,
      pages_left: @page_count_max
    }

    run = Enum.reduce(rules, run, &clean_dataset(&1, &2, context))
    summary = Map.drop(run, [:attempts_left, :pages_left])
    finish(summary, length(rules))
  end

  defp finish(%{discovery_failed_count: rule_count} = summary, rule_count) do
    Logger.error("Stored content cleanup failed", Map.to_list(summary))
    {:error, :nothing_examined}
  end

  defp finish(%{failed_count: 0, discovery_failed_count: 0} = summary, _rule_count) do
    Logger.info("Stored content cleanup finished", Map.to_list(summary))
    {:ok, summary}
  end

  defp finish(summary, _rule_count) do
    Logger.warning("Stored content cleanup finished degraded", Map.to_list(summary))
    {:ok, summary}
  end

  # Reads the dataset's pages, the oldest day first, until a page ends the
  # dataset or the run is at a bound. The page count bounds the loop.
  defp clean_dataset(rule, run, context) do
    {_cursor, run} =
      Enum.reduce_while(1..@page_count_max, {nil, run}, fn _page_index, {cursor, run} ->
        case clean_page(rule, cursor, run, context) do
          {:more, cursor, run} -> {:cont, {cursor, run}}
          {:done, run} -> {:halt, {cursor, run}}
        end
      end)

    run
  end

  # A run at a bound deletes nothing: it reads one destination, the oldest
  # the dataset has left, to learn whether expired content stays behind.
  defp clean_page(
         rule,
         cursor,
         %{attempts_left: attempts_left, pages_left: pages_left} = run,
         context
       )
       when attempts_left == 0 or pages_left == 0 do
    case discover(rule, cursor, 1, context) do
      {:ok, %{destinations: [destination]}} ->
        {:done, %{run | backlog: run.backlog or status(rule, destination, context) == :expired}}

      {:ok, %{destinations: []}} ->
        {:done, run}

      {:error, _reason} ->
        {:done, %{run | discovery_failed_count: run.discovery_failed_count + 1}}
    end
  end

  defp clean_page(rule, cursor, run, context) do
    limit = min(Reader.discovery_limit_max(), run.attempts_left)

    case discover(rule, cursor, limit, context) do
      {:ok, %{destinations: destinations, cursor: next}} ->
        run = %{run | pages_left: run.pages_left - 1}

        case clean_destinations(rule, destinations, run, context) do
          {:kept, run} -> {:done, run}
          {:all, run} when next == nil -> {:done, run}
          {:all, run} -> {:more, next, run}
        end

      {:error, _reason} ->
        {:done, %{run | discovery_failed_count: run.discovery_failed_count + 1}}
    end
  end

  # Deletes the expired destinations of one page, in order, and stops at the
  # first one the rule keeps: every later destination is of that day or a
  # later one.
  defp clean_destinations(rule, destinations, run, context) do
    Enum.reduce_while(destinations, {:all, run}, fn destination, {:all, run} ->
      case status(rule, destination, context) do
        :kept -> {:halt, {:kept, run}}
        :unrecognized -> {:cont, {:all, %{run | unrecognized_count: run.unrecognized_count + 1}}}
        :expired -> {:cont, {:all, delete(rule, destination, run, context)}}
      end
    end)
  end

  defp delete(rule, destination, run, context) do
    request = %{destination: destination, within: Retention.within(rule)}
    run = %{run | attempts_left: run.attempts_left - 1}

    case Deleter.delete(request, context.delete_options) do
      :ok -> %{run | deleted_count: run.deleted_count + 1}
      {:error, :not_found} -> run
      {:error, _reason} -> %{run | failed_count: run.failed_count + 1}
    end
  end

  defp discover(rule, cursor, limit, context) do
    Reader.discover(
      %{
        prefix: Retention.partitions_prefix(rule),
        limit: limit,
        order: :ascending,
        cursor: cursor
      },
      context.read_options
    )
  end

  defp status(rule, destination, %{today: today}) do
    Retention.status(%{rule: rule, destination: destination, today: today})
  end
end
