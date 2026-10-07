defmodule Gobusgo.OneBusAway.ArrivalSchedule do
  @refresh_age_ms 300_000

  @moduledoc """
  Which open stops are due for a fetch of their arrivals. Everything here is
  pure.

  A stop is due when it has no fetch, and when its fetch is at least
  #{div(@refresh_age_ms, 60_000)} minutes old (decided in GOB-158). The
  stops with no fetch come first, in identifier order, since a rider is
  looking at nothing; then the others, the oldest fetch first.
  """

  @doc "The age at which a stop's fetch is due again, in milliseconds."
  @spec refresh_age_ms() :: pos_integer()
  def refresh_age_ms, do: @refresh_age_ms

  @doc """
  Returns the stops of `stop_ids` that are due at `now`, in the order to
  fetch them. `fetch_times` holds the fetch time of each stop that has a
  fetch.
  """
  @spec due(%{
          stop_ids: [String.t()],
          fetch_times: %{String.t() => DateTime.t()},
          now: DateTime.t()
        }) :: [String.t()]
  def due(%{stop_ids: stop_ids, fetch_times: fetch_times, now: %DateTime{} = now})
      when is_list(stop_ids) and is_map(fetch_times) do
    {fetched, unfetched} = Enum.split_with(Enum.uniq(stop_ids), &is_map_key(fetch_times, &1))

    stale =
      fetched
      |> Enum.map(&{Map.fetch!(fetch_times, &1), &1})
      |> Enum.filter(fn {fetched_at, _stop_id} ->
        DateTime.diff(now, fetched_at, :millisecond) >= @refresh_age_ms
      end)
      |> Enum.sort_by(fn {fetched_at, stop_id} ->
        {DateTime.to_unix(fetched_at, :microsecond), stop_id}
      end)
      |> Enum.map(fn {_fetched_at, stop_id} -> stop_id end)

    Enum.sort(unfetched) ++ stale
  end
end
