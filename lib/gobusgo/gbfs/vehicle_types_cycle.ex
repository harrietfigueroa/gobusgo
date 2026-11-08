defmodule Gobusgo.Gbfs.VehicleTypesCycle do
  @budget_ms_default 50_000
  @deadline_ms 55_000
  @interval_ms 60_000
  @request_deadline_ms_default 15_000
  @request_ms_min 250
  @system_count_max 16

  @moduledoc """
  One cycle of `vehicle_types` fetches: fetches the types that are due, for
  each GBFS system and each version of it that publishes them, and
  publishes each fetch to the vehicle type view. The scheduler of `spec/1`
  runs one cycle every #{@interval_ms} ms.

  An item is one system at one version among
  #{inspect(Gobusgo.Gbfs.Files.vehicle_types_versions())}, each fetched with
  `versions: [version]`, since a type identifier names a type within its
  version alone and the vehicles of either version need the types of their
  own. An item's identifier is `Gobusgo.Gbfs.VehicleTypeRecords.id/1`, and
  `Gobusgo.OneBusAway.RouteSchedule` gives it a slot of its own, a minute of
  the UTC day: an item is due when the view has no attempt of it, and when
  its slot has come since its last attempt, so a view that starts empty is
  filled by the first cycle and each item then refreshes once a day, as the
  file's `ttl` of a day asks.

  A cycle fetches the due items one after another, systems in identifier
  order and versions newest first, each bounded by `:request_deadline_ms`
  and by what is left of `:budget_ms`, and starts none with less than
  #{@request_ms_min} ms left. A fetch is not retried within a cycle.

    * A fetched file is published as one record of
      `Gobusgo.Gbfs.VehicleTypeRecords` to the view.
    * A file that is not published, the version's discovery file or its
      `vehicle_types` answering 404 or the file not listed, is a known
      outcome: GBFS allows an optional file to be absent, and the feed can
      end. It is noted as an attempt in the view, so the item waits for its
      slot, and the view keeps whatever types it holds of that version.
    * A failed fetch, and a fetch whose record is not published, are noted
      nowhere, so the item is due again at the next cycle.

  The cycle stores no raw response.

  ## Results

    * `{:ok, counts}`: at least one item is fetched or not published, or
      nothing failed. `counts` holds `:due_count`, `:fetched_count`,
      `:not_published_count`, `:failed_count`, and `:skipped_count`, the due
      items the budget did not reach.
    * `{:error, :nothing_fetched}`: items are due, at least one failed, and
      none is fetched or not published.

  Each call logs once: `debug` `GBFS vehicle types cycle found nothing due`,
  `info` `GBFS vehicle types cycle finished` when every due item is fetched,
  `warning` `GBFS vehicle types cycle finished degraded` when some item is
  not, and `error` `GBFS vehicle types cycle failed` when the cycle returns
  an error, each with the counts and `failures`, the count of failed items
  by cause.

  ## Options

    * `:systems`: at most #{@system_count_max} systems, as
      `Gobusgo.Gbfs.Systems.all/0` gives them, which is the default.
    * `:view`: the fetch view. Defaults to `Gobusgo.Gbfs.VehicleTypeView`.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
    * `:request_deadline_ms`: the bound on one fetch. Defaults to
      #{@request_deadline_ms_default}.
    * `:budget_ms`: defaults to #{@budget_ms_default}.
    * `:fetch_options`: further options of `Gobusgo.Gbfs.Client.fetch/3`.
    * `:publish_options`: the options of `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Client
  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleTypeRecords
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Scheduler

  @type counts :: %{
          due_count: non_neg_integer(),
          fetched_count: non_neg_integer(),
          not_published_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer()
        }

  @doc """
  The spec of the scheduler that runs one cycle with `options` every
  #{@interval_ms} ms, with a deadline of #{@deadline_ms} ms.
  """
  @spec spec(Keyword.t()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    spec = %{
      name: Gobusgo.Gbfs.VehicleTypesScheduler,
      run: fn -> run(options) end,
      cadence: %{policy: {:fixed, @interval_ms}, signals: &no_signals/0},
      deadline_ms: @deadline_ms
    }

    Assert.condition(
      Keyword.get(options, :budget_ms, @budget_ms_default) < @deadline_ms,
      "the budget must end before the run's deadline of #{@deadline_ms} ms"
    )

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}

  @doc "Fetches the vehicle types that are due, as far as the budget reaches."
  @spec run(Keyword.t()) :: {:ok, counts()} | {:error, :nothing_fetched}
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options,
        systems: Systems.all(),
        view: Gobusgo.Gbfs.VehicleTypeView,
        clock: &DateTime.utc_now/0,
        request_deadline_ms: @request_deadline_ms_default,
        budget_ms: @budget_ms_default,
        fetch_options: [],
        publish_options: []
      )

    for key <- [:request_deadline_ms, :budget_ms] do
      value = Keyword.fetch!(options, key)
      Assert.condition(value > 0, "#{key} must be positive, got: #{value}")
    end

    systems = Keyword.fetch!(options, :systems)
    system_count = length(systems)

    Assert.condition(
      system_count <= @system_count_max,
      "at most #{@system_count_max} systems, got: #{system_count}"
    )

    due = due_items(systems, options)
    outcomes = fetch_each(due, options)
    Assert.condition(length(outcomes) == length(due), "every due item must have an outcome")

    counts = counts(outcomes)
    log(counts, failures(outcomes))
    nothing_fetched = counts.fetched_count + counts.not_published_count == 0

    if counts.failed_count >= 1 and nothing_fetched do
      {:error, :nothing_fetched}
    else
      {:ok, counts}
    end
  end

  defp due_items(systems, options) do
    now = Keyword.fetch!(options, :clock).()
    attempts = FetchView.attempt_times(Keyword.fetch!(options, :view))

    for system <- systems,
        version <- Files.vehicle_types_versions(),
        is_map_key(system.discovery_urls, version),
        id = VehicleTypeRecords.id(%{system_id: system.id, version: version}),
        RouteSchedule.due?(%{id: id, fetched_at: Map.get(attempts, id), now: now}) do
      %{id: id, system: system, version: version}
    end
  end

  defp fetch_each(items, options) do
    budget_end_ms = System.monotonic_time(:millisecond) + Keyword.fetch!(options, :budget_ms)
    request_deadline_ms = Keyword.fetch!(options, :request_deadline_ms)

    for item <- items do
      left_ms = budget_end_ms - System.monotonic_time(:millisecond)

      if left_ms >= @request_ms_min do
        fetch(item, min(left_ms, request_deadline_ms), options)
      else
        :skipped
      end
    end
  end

  defp fetch(%{id: id, system: system, version: version}, deadline_ms, options) do
    clock = Keyword.fetch!(options, :clock)

    fetch_options =
      Keyword.merge(
        Keyword.fetch!(options, :fetch_options),
        versions: [version],
        deadline_ms: deadline_ms,
        clock: clock
      )

    case Client.fetch(system, :vehicle_types, fetch_options) do
      {:ok, %{kind: :fetched} = fetched} ->
        publish(%{system_id: system.id, version: version, fetched: fetched}, options)

      {:ok, %{kind: :not_published}} ->
        attempt = %{id: id, fetched_at: clock.()}
        :ok = FetchView.note_attempt(Keyword.fetch!(options, :view), attempt)
        :not_published

      {:error, %{cause: :deadline_exceeded}} ->
        {:failed, "deadline_exceeded"}

      {:error, %{cause: cause, file: file}} ->
        {:failed, "#{file}:#{cause_name(cause)}"}
    end
  end

  defp publish(%{system_id: system_id, version: version, fetched: fetched}, options) do
    record =
      VehicleTypeRecords.build(%{
        system_id: system_id,
        version: version,
        request_id: RequestId.generate(),
        fetched_at: fetched.fetched_at,
        vehicle_types: fetched.vehicle_types
      })

    case Publisher.publish([record], Keyword.fetch!(options, :publish_options)) do
      :ok -> :fetched
      {:error, reason} -> {:failed, "publish:#{reason}"}
    end
  end

  # The name of a cause without the terms it carries, so the causes of a
  # cycle group into few keys.
  defp cause_name(name) when is_atom(name), do: name
  defp cause_name({name, _detail}) when is_atom(name), do: name

  defp counts(outcomes) do
    failed_count = Enum.count(outcomes, &match?({:failed, _cause}, &1))

    %{
      due_count: length(outcomes),
      fetched_count: Enum.count(outcomes, &(&1 == :fetched)),
      not_published_count: Enum.count(outcomes, &(&1 == :not_published)),
      failed_count: failed_count,
      skipped_count: Enum.count(outcomes, &(&1 == :skipped))
    }
  end

  defp failures(outcomes) do
    for({:failed, cause} <- outcomes, do: cause) |> Enum.frequencies()
  end

  defp log(counts, failures) do
    properties = Map.to_list(counts) ++ [failures: inspect(failures)]
    nothing_fetched = counts.fetched_count + counts.not_published_count == 0
    failed = counts.failed_count >= 1 and nothing_fetched

    cond do
      counts.due_count == 0 ->
        Logger.debug("GBFS vehicle types cycle found nothing due", properties)

      counts.fetched_count == counts.due_count ->
        Logger.info("GBFS vehicle types cycle finished", properties)

      failed ->
        Logger.error("GBFS vehicle types cycle failed", properties)

      true ->
        Logger.warning("GBFS vehicle types cycle finished degraded", properties)
    end
  end
end
