defmodule Gobusgo.OneBusAway.ScheduleDates do
  @moduledoc """
  Which service dates of a route's schedule are due for a fetch. Everything
  here is pure.

  The dates are reckoned by the UTC date of `now`, which is the local date
  of the Puget Sound agencies or the day after it, so the source needs no
  time zone. A route wants the day before the UTC date, the UTC date, and
  the day after it: those hold the local service date, the one before it
  for its trips past midnight, and the next one, ready before it starts
  (decided in GOB-240).

  The day before and the UTC date are due at once, which fills a view after
  a start. The day after is due once the route's slot of the UTC day has
  come, the slot `Gobusgo.OneBusAway.RouteSchedule` gives the route, so the
  next day's fetches spread over the day. A date the route already knows,
  held or attempted, is never due.
  """

  alias Gobusgo.OneBusAway.RouteSchedule

  @doc """
  Returns the dates of `route_id` that are due at `now`, the earliest first,
  given `known_dates`, the dates the route holds or has attempted.
  """
  @spec due(%{route_id: String.t(), known_dates: [Date.t()], now: DateTime.t()}) :: [Date.t()]
  def due(%{route_id: route_id, known_dates: known_dates, now: %DateTime{} = now})
      when is_binary(route_id) and is_list(known_dates) do
    today = DateTime.to_date(now)
    slot_today = DateTime.to_date(RouteSchedule.slot_at(route_id, now)) == today
    wanted = [Date.add(today, -1), today] ++ next_date(today, slot_today)
    Enum.reject(wanted, &(&1 in known_dates))
  end

  defp next_date(today, true), do: [Date.add(today, 1)]
  defp next_date(_today, false), do: []
end
