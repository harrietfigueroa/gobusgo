defmodule Gobusgo.OneBusAway.ArrivalSchedule do
  @moduledoc """
  Which open stops are due for a fetch of their arrivals. Everything here is
  pure.

  A stop is due when it has no fetch, and when its fetch is at least as old
  as the refresh age the caller gives. The stops with no fetch come first,
  in identifier order, since a rider is looking at nothing; then the others,
  the oldest fetch first.
  """

  alias Gobusgo.Assert

  @doc """
  Returns the stops of `stop_ids` that are due at `now`, in the order to
  fetch them. `fetch_times` holds the fetch time of each stop that has a
  fetch, and `refresh_age_ms` is the age at which a fetch is due again, a
  positive integer of milliseconds.
  """
  @spec due(%{
          stop_ids: [String.t()],
          fetch_times: %{String.t() => DateTime.t()},
          now: DateTime.t(),
          refresh_age_ms: pos_integer()
        }) :: [String.t()]
  def due(%{
        stop_ids: stop_ids,
        fetch_times: fetch_times,
        now: %DateTime{} = now,
        refresh_age_ms: refresh_age_ms
      })
      when is_list(stop_ids) and is_map(fetch_times) do
    Assert.condition(
      is_integer(refresh_age_ms),
      "refresh_age_ms must be an integer, got: #{inspect(refresh_age_ms)}"
    )

    Assert.condition(
      refresh_age_ms >= 1,
      "refresh_age_ms must be positive, got: #{refresh_age_ms}"
    )

    {fetched, unfetched} = Enum.split_with(Enum.uniq(stop_ids), &is_map_key(fetch_times, &1))

    stale =
      fetched
      |> Enum.map(&{Map.fetch!(fetch_times, &1), &1})
      |> Enum.filter(fn {fetched_at, _stop_id} ->
        DateTime.diff(now, fetched_at, :millisecond) >= refresh_age_ms
      end)
      |> Enum.sort_by(fn {fetched_at, stop_id} ->
        {DateTime.to_unix(fetched_at, :microsecond), stop_id}
      end)
      |> Enum.map(fn {_fetched_at, stop_id} -> stop_id end)

    Enum.sort(unfetched) ++ stale
  end
end
