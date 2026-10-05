defmodule Gobusgo.OneBusAway.RouteBackfill do
  @agency_count_max 64
  @attempt_count_max_default 3
  @failure_streak_max_default 10
  @request_deadline_ms_default 30_000
  @request_interval_ms_default 1_000
  @route_count_max_default 5_000

  @moduledoc """
  One backfill of the route data: records the routes of every agency through
  `Gobusgo.OneBusAway.RouteRecorder`, then the stops and paths of every route
  those agencies list through `Gobusgo.OneBusAway.RoutePathRecorder`, one
  request after another at a fixed pace. Each response is stored and
  announced the way a scheduled fetch is, whether or not it is due.

  The agencies are the ones named in `:agency_ids`, or those the server
  lists in `agencies-with-coverage` when none is named. The routes of an
  agency are read back from the response the backfill stored for it. Agencies
  come first, then routes, each in identifier order.

  `run/2` runs in the calling process and starts none. It starts one request
  every `:request_interval_ms`, the request for the agencies and every
  repeated request included.

  ## Bounds

    * At most #{@agency_count_max} agencies; more raise.
    * At most `:route_count_max` routes; the routes beyond are skipped.
    * Each request has `:request_deadline_ms`.
    * A request the server answers with 429, or that the request gate gives
      no permit, is tried again, at most `:attempt_count_max` times in all.
      The request gate holds every request back for the pause the server
      names.
    * After `:failure_streak_max` failed items in a row the backfill stops
      and skips the items left.

  ## Results

  `{:ok, summary}`, where `summary` holds `:agency_count`, `:route_count`,
  the routes the recorded agencies list, `:recorded_count`, `:failed_count`,
  `:skipped_count`, `:unannounced_count`, the responses stored whose
  "response stored" event was not published, `:retried_count`, the repeated
  requests, `:failures`, the count of failed items by cause, and `:stopped`,
  whether the failure streak ended the backfill.

  `{:error, {:agencies, reason}}` when no agency is named and the request
  for them fails; `reason` is a `t:Gobusgo.OneBusAway.Agencies.error/0`.

  A call logs nothing: the summary returns to the caller.

  ## Options

    * `:agency_ids`: the agencies, or `nil` to ask the server. Defaults to
      `nil`.
    * `:route_count_max`: defaults to #{@route_count_max_default}.
    * `:request_interval_ms`: defaults to #{@request_interval_ms_default}.
    * `:request_deadline_ms`: defaults to #{@request_deadline_ms_default}.
    * `:attempt_count_max`: defaults to #{@attempt_count_max_default}.
    * `:failure_streak_max`: defaults to #{@failure_streak_max_default}.
    * `:sleep`: waits the given milliseconds between requests. Defaults to
      `Process.sleep/1`.
    * `:fetch_options`: options for the requesters.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Agencies
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RoutePathRecorder
  alias Gobusgo.OneBusAway.RouteRecorder
  alias Gobusgo.Reader

  @type summary :: %{
          agency_count: non_neg_integer(),
          route_count: non_neg_integer(),
          recorded_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          unannounced_count: non_neg_integer(),
          retried_count: non_neg_integer(),
          failures: %{String.t() => pos_integer()},
          stopped: boolean()
        }

  @typedoc "What a backfill carries from one request to the next."
  @type progress :: %{
          next_start_ms: integer(),
          failure_streak: non_neg_integer(),
          stopped: boolean(),
          retried_count: non_neg_integer(),
          outcomes: [:recorded | :unannounced | :skipped | {:failed, String.t()}]
        }

  # The Puget Sound server answers 429 when it limits a key, a status its
  # documentation does not name (https://developer.onebusaway.org/api/where —
  # checked 2026-10-05). `:rate_limited` is the request gate giving no permit.
  @rate_limited_causes [{:http_status, 429}, :rate_limited]

  @doc "Records the routes of every agency and the stops and paths of every route once."
  @spec run(Client.settings(), Keyword.t()) ::
          {:ok, summary()} | {:error, {:agencies, Agencies.error()}}
  def run(%{api_key: api_key} = settings, options) when is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options,
        agency_ids: nil,
        route_count_max: @route_count_max_default,
        request_interval_ms: @request_interval_ms_default,
        request_deadline_ms: @request_deadline_ms_default,
        attempt_count_max: @attempt_count_max_default,
        failure_streak_max: @failure_streak_max_default,
        sleep: &Process.sleep/1,
        fetch_options: [],
        write_options: [],
        read_options: [],
        publish_options: []
      )

    for key <- [:route_count_max, :request_deadline_ms, :attempt_count_max, :failure_streak_max] do
      value = Keyword.fetch!(options, key)
      Assert.condition(value >= 1, "#{key} must be positive, got: #{value}")
    end

    interval_ms = Keyword.fetch!(options, :request_interval_ms)
    Assert.condition(interval_ms >= 0, "request_interval_ms must be zero or more")

    progress = %{
      next_start_ms: System.monotonic_time(:millisecond),
      failure_streak: 0,
      stopped: false,
      retried_count: 0,
      outcomes: []
    }

    context = %{settings: settings, options: options}

    with {:ok, agency_ids, progress} <- agency_ids(progress, context) do
      {:ok, backfill(progress, agency_ids, context)}
    end
  end

  @doc "Returns `summary` as the lines a person reads: one count a line. Pure."
  @spec report(summary()) :: String.t()
  def report(summary) do
    failures =
      case Enum.sort(summary.failures) do
        [] -> "none"
        failures -> Enum.map_join(failures, ", ", fn {cause, count} -> "#{cause} #{count}" end)
      end

    """
    Route backfill #{if summary.stopped, do: "stopped after failures in a row", else: "finished"}
      agencies:            #{summary.agency_count}
      routes:              #{summary.route_count}
      recorded:            #{summary.recorded_count}
      failed:              #{summary.failed_count}
      skipped:             #{summary.skipped_count}
      stored, unannounced: #{summary.unannounced_count}
      repeated requests:   #{summary.retried_count}
      failures by cause:   #{failures}\
    """
  end

  defp agency_ids(progress, %{settings: settings, options: options}) do
    case Keyword.fetch!(options, :agency_ids) do
      nil ->
        progress = wait(progress, options)

        case Agencies.fetch_response(settings, fetch_options(options)) do
          {:ok, %{agencies: agencies}} -> {:ok, Enum.map(agencies, & &1.id), progress}
          {:error, reason} -> {:error, {:agencies, reason}}
        end

      agency_ids when is_list(agency_ids) ->
        {:ok, agency_ids, progress}
    end
  end

  defp backfill(progress, agency_ids, %{options: options} = context) do
    agency_ids = agency_ids |> Enum.uniq() |> Enum.sort()
    agency_count = length(agency_ids)

    Assert.condition(
      agency_count <= @agency_count_max,
      "a backfill takes at most #{@agency_count_max} agencies, got: #{agency_count}"
    )

    {route_id_lists, progress} =
      Enum.map_reduce(agency_ids, progress, fn agency_id, progress ->
        attempt(progress, {:routes, agency_id}, context)
      end)

    route_ids = route_id_lists |> List.flatten() |> Enum.uniq() |> Enum.sort()
    {taken, beyond} = Enum.split(route_ids, Keyword.fetch!(options, :route_count_max))

    progress =
      Enum.reduce(taken, progress, fn route_id, progress ->
        {[], progress} = attempt(progress, {:route_path, route_id}, context)
        progress
      end)

    outcomes = progress.outcomes ++ List.duplicate(:skipped, length(beyond))

    Assert.condition(
      length(outcomes) == agency_count + length(route_ids),
      "every agency and every route must have an outcome"
    )

    summary(outcomes, %{
      agency_count: agency_count,
      route_count: length(route_ids),
      retried_count: progress.retried_count,
      stopped: progress.stopped
    })
  end

  # Records one item, trying a held-back request again, and returns the
  # routes it found: those of a recorded agency, and none otherwise.
  defp attempt(%{stopped: true} = progress, _item, _context) do
    {[], %{progress | outcomes: progress.outcomes ++ [:skipped]}}
  end

  defp attempt(progress, item, %{options: options} = context) do
    attempt_count_max = Keyword.fetch!(options, :attempt_count_max)

    {result, progress} =
      Enum.reduce_while(1..attempt_count_max, {nil, progress}, fn attempt_count, {_, progress} ->
        progress = wait(progress, options)

        case record(item, context) do
          {:failed, _cause, :rate_limited} = result when attempt_count < attempt_count_max ->
            {:cont, {result, %{progress | retried_count: progress.retried_count + 1}}}

          result ->
            {:halt, {result, progress}}
        end
      end)

    settle(progress, result, options)
  end

  defp settle(progress, {:failed, cause, _kind}, options) do
    failure_streak = progress.failure_streak + 1

    progress = %{
      progress
      | failure_streak: failure_streak,
        stopped: failure_streak >= Keyword.fetch!(options, :failure_streak_max),
        outcomes: progress.outcomes ++ [{:failed, cause}]
    }

    {[], progress}
  end

  defp settle(progress, {outcome, route_ids}, _options)
       when outcome in [:recorded, :unannounced] do
    {route_ids, %{progress | failure_streak: 0, outcomes: progress.outcomes ++ [outcome]}}
  end

  # Starts requests `request_interval_ms` apart, counted from one start to
  # the next.
  defp wait(%{next_start_ms: next_start_ms} = progress, options) do
    wait_ms = next_start_ms - System.monotonic_time(:millisecond)
    if wait_ms > 0, do: Keyword.fetch!(options, :sleep).(wait_ms)
    interval_ms = Keyword.fetch!(options, :request_interval_ms)
    %{progress | next_start_ms: System.monotonic_time(:millisecond) + interval_ms}
  end

  defp fetch_options(options) do
    Keyword.merge(
      [max_retries: 0, deadline_ms: Keyword.fetch!(options, :request_deadline_ms)],
      Keyword.fetch!(options, :fetch_options)
    )
  end

  defp record({kind, id} = item, %{settings: settings, options: options}) do
    record_options = [
      fetch_options: fetch_options(options),
      write_options: Keyword.fetch!(options, :write_options),
      publish_options: Keyword.fetch!(options, :publish_options)
    ]

    result =
      try do
        case kind do
          :routes -> RouteRecorder.record(settings, [agency_id: id] ++ record_options)
          :route_path -> RoutePathRecorder.record(settings, [route_id: id] ++ record_options)
        end
      rescue
        Assert.AssertionError -> {:error, :contract_violation}
      end

    case result do
      {:ok, %{event_published: published} = recorded} ->
        outcome = if published, do: :recorded, else: :unannounced
        found(outcome, item, recorded, options)

      {:error, :contract_violation} ->
        {:failed, "contract_violation", :other}

      {:error, {stage, reason}} ->
        kind = if reason in @rate_limited_causes, do: :rate_limited, else: :other
        {:failed, cause(stage, reason), kind}
    end
  end

  defp found(outcome, {:route_path, _route_id}, _recorded, _options), do: {outcome, []}

  defp found(outcome, {:routes, _agency_id}, %{destination: destination}, options) do
    with {:ok, content} <- Reader.read(destination, Keyword.fetch!(options, :read_options)),
         {:ok, %{routes: routes}} <-
           RawRouteResponse.parse(%{destination: destination, content: content}) do
      {outcome, Enum.map(routes, & &1.id)}
    else
      {:error, reason} -> {:failed, cause(:read_back, reason), :other}
    end
  end

  # The name of a failure without the terms it carries, so the causes of a
  # backfill group into few keys.
  defp cause(stage, reason) do
    name =
      case reason do
        name when is_atom(name) -> name
        {name, _detail} when is_atom(name) -> name
      end

    "#{stage}:#{name}"
  end

  defp summary(outcomes, counts) do
    recorded_count = Enum.count(outcomes, &(&1 in [:recorded, :unannounced]))
    skipped_count = Enum.count(outcomes, &(&1 == :skipped))

    Map.merge(counts, %{
      recorded_count: recorded_count,
      failed_count: length(outcomes) - recorded_count - skipped_count,
      skipped_count: skipped_count,
      unannounced_count: Enum.count(outcomes, &(&1 == :unannounced)),
      failures: for({:failed, cause} <- outcomes, do: cause) |> Enum.frequencies()
    })
  end
end
