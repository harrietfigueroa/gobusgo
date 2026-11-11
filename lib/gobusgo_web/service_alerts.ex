defmodule GobusgoWeb.ServiceAlerts do
  @ms_per_day 24 * 60 * 60 * 1_000
  @upcoming_day_count 7
  @upcoming_window_ms @upcoming_day_count * @ms_per_day
  @alert_count_max 100
  @dom_id_prefix "service-alert-"

  @moduledoc """
  The service alerts a map page shows, from the situations of
  `Gobusgo.OneBusAway.Situations` that the situation views hold: those of
  the trips each agency's vehicles serve, and those of the stops riders
  have open. Everything here is pure; the time is an argument.

  An alert is kept when it affects a route the page's filter keeps; one
  that names no route is left out. A situation that several fetches hold is
  read once, as the newest of them holds it.

    * Current: an alert with no active window, or with a window that has
      begun and not ended at the time given. Ordered by creation, the
      newest first.
    * Upcoming: any other alert whose next window starts within
      #{@upcoming_day_count} days, with that start. Ordered by start, the
      soonest first. An alert past its last window, or further off, is left
      out.

  Each list holds at most #{@alert_count_max} alerts. The routes of the
  current alerts that are kept give the popups their lines, so every line a
  popup shows has its alert in the current list.
  """

  alias GobusgoWeb.StopMarkers

  @typedoc """
  One alert as a page shows it. `starts_at` is the start of an upcoming
  alert's next window, and `nil` for a current one. `route_names` names the
  kept routes it affects, in identifier order, each by the name the route
  view gives it or by its identifier.
  """
  @type alert :: %{
          id: String.t(),
          dom_id: String.t(),
          summary: String.t(),
          description: String.t() | nil,
          url: String.t() | nil,
          starts_at: DateTime.t() | nil,
          route_names: [String.t()]
        }

  @typedoc """
  A current alert as a popup of a route shows it. `stop_ids` are the stops
  at which it affects the route, in identifier order, and empty for an
  alert that affects the route as a whole.
  """
  @type route_line :: %{id: String.t(), summary: String.t(), stop_ids: [String.t()]}

  @type t :: %{
          current: [alert()],
          upcoming: [alert()],
          routes: %{String.t() => [route_line()]}
        }

  @doc "How far ahead an upcoming alert is shown, in days."
  @spec upcoming_day_count() :: pos_integer()
  def upcoming_day_count, do: @upcoming_day_count

  @doc """
  Returns the alerts of `situation_fetches`, the fetches of the situation
  views, that affect `kept_route_ids`, the routes the page's filter keeps
  or `:every`, at `now`. `route_names` names the routes by identifier.
  """
  @spec alerts(%{
          situation_fetches: [map()],
          kept_route_ids: :every | [String.t()],
          route_names: %{String.t() => String.t()},
          now: DateTime.t()
        }) :: t()
  def alerts(%{
        situation_fetches: situation_fetches,
        kept_route_ids: kept_route_ids,
        route_names: route_names,
        now: %DateTime{} = now
      }) do
    now_ms = DateTime.to_unix(now, :millisecond)

    kept =
      for situation <- latest_situations(situation_fetches),
          route_ids = kept_affected_route_ids(situation, kept_route_ids),
          route_ids != [] do
        {situation, route_ids}
      end

    {current, later} =
      Enum.split_with(kept, fn {situation, _route_ids} -> current?(situation, now_ms) end)

    current =
      current
      |> Enum.sort_by(fn {situation, _route_ids} ->
        {-(situation.creation_time_ms || 0), situation.id}
      end)
      |> Enum.take(@alert_count_max)

    upcoming =
      for {situation, route_ids} <- later,
          starts_ms = next_start_ms(situation, now_ms),
          starts_ms != nil,
          starts_ms <= now_ms + @upcoming_window_ms do
        {situation, route_ids, starts_ms}
      end
      |> Enum.sort_by(fn {situation, _route_ids, starts_ms} -> {starts_ms, situation.id} end)
      |> Enum.take(@alert_count_max)

    %{
      current:
        Enum.map(current, fn {situation, route_ids} ->
          alert(situation, route_ids, nil, route_names)
        end),
      upcoming:
        Enum.map(upcoming, fn {situation, route_ids, starts_ms} ->
          alert(situation, route_ids, DateTime.from_unix!(starts_ms, :millisecond), route_names)
        end),
      routes: route_lines(current)
    }
  end

  @doc """
  Returns the alerts of `situation_fetches` that affect a route of
  `route_ids` or a stop of `stop_ids`, at `now`, as whole situations: the
  current ones, newest first, then the upcoming ones, soonest first, with
  each upcoming alert's start in `starts_at`. The lists are not bounded. An
  alert that names an agency and no route or stop matches nothing, as on a
  page.
  """
  @spec matching(%{
          situation_fetches: [map()],
          route_ids: [String.t()],
          stop_ids: [String.t()],
          now: DateTime.t()
        }) :: [
          %{
            situation: map(),
            status: :current | :upcoming,
            starts_at: DateTime.t() | nil
          }
        ]
  def matching(%{
        situation_fetches: situation_fetches,
        route_ids: route_ids,
        stop_ids: stop_ids,
        now: %DateTime{} = now
      }) do
    now_ms = DateTime.to_unix(now, :millisecond)

    kept =
      for situation <- latest_situations(situation_fetches),
          names_route_or_stop?(situation, %{route_ids: route_ids, stop_ids: stop_ids}) do
        situation
      end

    {current, later} = Enum.split_with(kept, &current?(&1, now_ms))

    current =
      current
      |> Enum.sort_by(&{-(&1.creation_time_ms || 0), &1.id})
      |> Enum.map(&%{situation: &1, status: :current, starts_at: nil})

    upcoming =
      for situation <- later,
          starts_ms = next_start_ms(situation, now_ms),
          starts_ms != nil,
          starts_ms <= now_ms + @upcoming_window_ms do
        {situation, starts_ms}
      end
      |> Enum.sort_by(fn {situation, starts_ms} -> {starts_ms, situation.id} end)
      |> Enum.map(fn {situation, starts_ms} ->
        %{
          situation: situation,
          status: :upcoming,
          starts_at: DateTime.from_unix!(starts_ms, :millisecond)
        }
      end)

    current ++ upcoming
  end

  @doc """
  Returns the names the route view gives the routes of `route_fetches`, as
  `alerts/1` takes them.
  """
  @spec route_names([map()]) :: %{String.t() => String.t()}
  def route_names(route_fetches) when is_list(route_fetches) do
    StopMarkers.route_names(route_fetches)
  end

  @doc """
  The identifier of the element that shows the alert `id`: the same for the
  same alert, and only of characters an element identifier takes, whatever
  the source's identifier holds.
  """
  @spec dom_id(String.t()) :: String.t()
  def dom_id(id) when is_binary(id), do: @dom_id_prefix <> Base.url_encode64(id, padding: false)

  # The newest fetch's version of each situation.
  defp latest_situations(situation_fetches) do
    situation_fetches
    |> Enum.sort_by(& &1.fetched_at, DateTime)
    |> Enum.flat_map(& &1.situations)
    |> Enum.reduce(%{}, fn situation, by_id -> Map.put(by_id, situation.id, situation) end)
    |> Map.values()
  end

  defp kept_affected_route_ids(situation, kept_route_ids) do
    affected =
      for %{route_id: route_id} <- situation.affects, route_id != nil, uniq: true, do: route_id

    affected
    |> Enum.filter(&kept_route?(&1, kept_route_ids))
    |> Enum.sort()
  end

  defp names_route_or_stop?(situation, %{route_ids: route_ids, stop_ids: stop_ids}) do
    Enum.any?(situation.affects, fn %{route_id: route_id, stop_id: stop_id} ->
      names_route = route_id != nil and route_id in route_ids
      names_stop = stop_id != nil and stop_id in stop_ids
      names_route or names_stop
    end)
  end

  defp kept_route?(_route_id, :every), do: true
  defp kept_route?(route_id, kept_route_ids), do: route_id in kept_route_ids

  defp current?(%{active_windows: []}, _now_ms), do: true

  defp current?(%{active_windows: windows}, now_ms) do
    Enum.any?(windows, fn window ->
      begun = window.from_ms == nil or window.from_ms <= now_ms
      begun and (window.to_ms == nil or now_ms < window.to_ms)
    end)
  end

  defp next_start_ms(%{active_windows: windows}, now_ms) do
    starts = for %{from_ms: from_ms} <- windows, from_ms != nil, from_ms > now_ms, do: from_ms

    case starts do
      [] -> nil
      starts -> Enum.min(starts)
    end
  end

  defp alert(situation, route_ids, starts_at, route_names) do
    %{
      id: situation.id,
      dom_id: dom_id(situation.id),
      summary: situation.summary,
      description: situation.description,
      url: situation.url,
      starts_at: starts_at,
      route_names: Enum.map(route_ids, &Map.get(route_names, &1, &1))
    }
  end

  # Each kept route's current alerts, in the order of the current list.
  defp route_lines(current) do
    lines =
      for {situation, route_ids} <- current, route_id <- route_ids do
        {route_id,
         %{id: situation.id, summary: situation.summary, stop_ids: stop_ids(situation, route_id)}}
      end

    Enum.group_by(lines, &elem(&1, 0), &elem(&1, 1))
  end

  # An alert that affects the route as a whole anywhere affects it at every
  # stop, which no list of stops says.
  defp stop_ids(situation, route_id) do
    stop_ids = for %{route_id: ^route_id, stop_id: stop_id} <- situation.affects, do: stop_id

    if Enum.member?(stop_ids, nil) do
      []
    else
      stop_ids |> Enum.uniq() |> Enum.sort()
    end
  end
end
