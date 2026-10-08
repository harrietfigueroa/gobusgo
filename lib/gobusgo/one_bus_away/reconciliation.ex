defmodule Gobusgo.OneBusAway.Reconciliation do
  @file_count_max 10_000
  @listed_count_max 100_000
  @source "/gobusgo/reconciliation/oba/agencies-with-coverage"

  @moduledoc """
  Publishes a "response stored" event again for every stored response of a
  dataset fetched inside a time range, so each one is processed again. This
  module orchestrates and logs; the range rules live in
  `Gobusgo.OneBusAway.Reconciliation.TimeRange` and the event in
  `Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent`.

  `republish/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. Nothing calls it on a
  schedule.

  ## Usage

      request = %{
        dataset: "oba/agencies-with-coverage",
        range: %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}
      }

      case Gobusgo.OneBusAway.Reconciliation.republish(request, []) do
        {:ok, %{published_count: published_count}} -> published_count
        {:error, reason} -> reason
      end

  ## Selection

  The stored responses of a range are those in the date partitions the range
  touches whose name carries a fetch time inside the half-open range. They
  are read one at a time in destination order. A range holds at most
  #{@file_count_max} stored responses, and its partitions at most
  #{@listed_count_max} destinations.

  A stored response that `Gobusgo.OneBusAway.RawAgencyResponse.parse/1`
  rejects is skipped with its reason and gets no event. A destination in a
  partition whose name carries no fetch time is skipped as
  `:destination_mismatch` without being read.

  ## Events

  Each event has the `source` `#{@source}`, a new identifier, and the fetch
  time of its stored response as `time`. Events are published in destination
  order, at most `Gobusgo.Publisher.record_count_max/0` per call.

  ## Results

  `{:ok, result}`, where `result` holds the `:published_count` and
  `:skipped`, a list of `%{destination: destination, reason: reason}`. A
  range whose stored responses have been deleted is a range that holds
  none: the result has a `:published_count` of 0 and no skip.

  `{:error, reason}`:

    * `:unknown_dataset` — the dataset is not `oba/agencies-with-coverage`;
      nothing is read.
    * `:too_many_files` — the range or its partitions exceed the bounds;
      nothing is published.
    * `{:read, reason}` — discovering or reading failed; `reason` is a
      `t:Gobusgo.Reader.error_reason/0` and nothing is published. A stored
      response that is gone between discovery and reading is
      `{:read, :not_found}`.
    * `{:publish, reason}` — a publish call failed; `reason` is a
      `t:Gobusgo.Publisher.error_reason/0`. Events of earlier calls are
      published.

  A request that breaks its contract raises `Gobusgo.Assert.AssertionError`.

  Each call logs its outcome once: `info` when it finishes, `warning` when
  it finishes with skips, `error` when it fails.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2` and
      `Gobusgo.Reader.discover/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
    * `:event_id`: a zero-arity function returning a new UUID version 7,
      called once per event. Defaults to `Gobusgo.RequestId.generate/0`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent
  alias Gobusgo.OneBusAway.Reconciliation.TimeRange
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type request :: %{dataset: String.t(), range: TimeRange.t()}

  @type skipped :: %{destination: String.t(), reason: RawAgencyResponse.parse_error()}

  @type result :: %{published_count: non_neg_integer(), skipped: [skipped()]}

  @type error ::
          :unknown_dataset
          | :too_many_files
          | {:read, Reader.error_reason()}
          | {:publish, Publisher.error_reason()}

  @page_limit Reader.discovery_limit_max()
  @page_count_max ceil(@listed_count_max / @page_limit)

  @doc "Stored responses allowed in one range."
  @spec file_count_max() :: pos_integer()
  def file_count_max, do: @file_count_max

  @doc """
  Publishes one "response stored" event for every stored response of
  `request.dataset` fetched inside `request.range`.
  """
  @spec republish(request(), Keyword.t()) :: {:ok, result()} | {:error, error()}
  def republish(%{dataset: dataset, range: range} = request, options)
      when is_binary(dataset) and is_list(options) do
    options =
      Keyword.validate!(options,
        read_options: [],
        publish_options: [],
        event_id: &RequestId.generate/0
      )

    TimeRange.assert_valid(range)
    event_id = Keyword.fetch!(options, :event_id)
    Assert.condition(is_function(event_id, 0), "event_id must be a zero-arity function")

    context = %{
      range: range,
      event_id: event_id,
      read_options: Keyword.fetch!(options, :read_options),
      publish_options: Keyword.fetch!(options, :publish_options)
    }

    result =
      if dataset == StoredEvent.dataset() do
        run(context)
      else
        {:error, :unknown_dataset}
      end

    log(result, request)
    result
  end

  defp run(context) do
    with {:ok, candidates} <- select(context),
         {:ok, loaded} <- load(candidates, context) do
      publish(loaded, context.publish_options)
    end
  end

  # A candidate is `{destination, :named}` when its name carries a fetch time
  # inside the range, and `{destination, :unnamed}` when it carries none.
  defp select(%{range: range, read_options: read_options}) do
    with {:ok, listed} <- list(TimeRange.dates(range), read_options) do
      candidates = Enum.flat_map(listed, &candidate(&1, range))

      if length(candidates) <= @file_count_max do
        {:ok, candidates}
      else
        {:error, :too_many_files}
      end
    end
  end

  defp candidate(destination, range) do
    case RawAgencyResponse.fetched_at(destination) do
      {:ok, fetched_at} ->
        if TimeRange.member?(range, fetched_at), do: [{destination, :named}], else: []

      :error ->
        [{destination, :unnamed}]
    end
  end

  # One page budget covers all the partitions of the range, so the listing
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
      {:more, _cursor, _pages, _pages_left} -> {:error, :too_many_files}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load(candidates, context) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, loaded} ->
      case load_candidate(candidate, context) do
        {:error, reason} -> {:halt, {:error, {:read, reason}}}
        entry -> {:cont, {:ok, [entry | loaded]}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_candidate({destination, :unnamed}, _context) do
    {:skipped, %{destination: destination, reason: :destination_mismatch}}
  end

  defp load_candidate({destination, :named}, %{read_options: read_options, event_id: event_id}) do
    with {:ok, content} <- Reader.read(destination, read_options) do
      case RawAgencyResponse.parse(%{destination: destination, content: content}) do
        {:ok, %{fetched_at: fetched_at} = response} ->
          {:event,
           StoredEvent.record(%{
             event_id: event_id.(),
             source: @source,
             time: fetched_at,
             response: response
           })}

        {:error, reason} ->
          {:skipped, %{destination: destination, reason: reason}}
      end
    end
  end

  defp publish(loaded, publish_options) do
    records = for {:event, record} <- loaded, do: record
    skipped = for {:skipped, entry} <- loaded, do: entry

    records
    |> Enum.chunk_every(Publisher.record_count_max())
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Publisher.publish(chunk, publish_options) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:publish, reason}}}
      end
    end)
    |> case do
      :ok -> {:ok, %{published_count: length(records), skipped: skipped}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log({:ok, %{skipped: []} = result}, request) do
    Logger.info("Reconciliation finished", properties(result, request))
  end

  defp log({:ok, result}, request) do
    Logger.warning("Reconciliation finished with skips", properties(result, request))
  end

  defp log({:error, reason}, request) do
    Logger.error("Reconciliation failed", [reason: inspect(reason)] ++ properties(request))
  end

  defp properties(result, request) do
    [published_count: result.published_count, skipped_count: length(result.skipped)] ++
      properties(request)
  end

  defp properties(%{dataset: dataset, range: %{start_at: start_at, end_at: end_at}}) do
    [
      dataset: dataset,
      range_start: DateTime.to_iso8601(start_at, :extended),
      range_end: DateTime.to_iso8601(end_at, :extended)
    ]
  end
end
