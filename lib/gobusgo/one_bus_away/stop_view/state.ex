defmodule Gobusgo.OneBusAway.StopView.State do
  @moduledoc """
  The rules of the stop view: which stops are held, and which fetch each
  one's values come from. Everything here is pure.

  A fetch is the stops of one route, whole in one record, and
  `Gobusgo.OneBusAway.FetchView.State` decides which fetch is a route's
  current one. A fetch that becomes its route's current one is applied:

    * Every stop it holds, parent stops included, is listed by the route.
      A stop takes the fetch's values unless the values it has come from a
      later fetch of another route.
    * A stop the route's fetch before listed and this one does not is no
      longer listed by the route. A stop no route lists is removed.

  So a stop is held for as long as the current fetch of some route lists it,
  with the values of the latest fetch that supplied it.

  At most `stop_count_max` stops are held. A fetch that would hold more is
  refused whole and leaves the state as it was, its route's current fetch
  included.

  The state keeps, per route, the identifiers of the stops its current fetch
  lists and, per stop, the routes that list it and the fetch time of its
  values. The values themselves are the caller's to hold.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.RequestId

  @typedoc "A stop with the fetch its values come from."
  @type held_stop :: %{
          id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          stop: StopRecords.stop()
        }

  @typedoc "What applying a fetch changed: the stops to hold, and the identifiers of those removed."
  @type change :: %{held_stops: [held_stop()], removed_ids: [String.t()]}

  @type t :: %{
          fetches: FetchView.State.t(),
          route_stop_ids: %{String.t() => [String.t()]},
          stops: %{String.t() => %{fetched_at: DateTime.t(), route_ids: MapSet.t(String.t())}},
          stop_count_max: pos_integer()
        }

  @typedoc """
    * `{:switched, change}` — the fetch is now its route's current fetch.
    * `:ignored` — the fetch changed nothing.
    * `:refused` — the fetch would hold more stops than the bound.
  """
  @type outcome :: {:switched, change()} | :ignored | :refused

  @doc "A view that holds no stop, for at most `route_count_max` routes and `stop_count_max` stops."
  @spec new(%{route_count_max: pos_integer(), stop_count_max: pos_integer()}) :: t()
  def new(%{route_count_max: route_count_max, stop_count_max: stop_count_max})
      when is_integer(stop_count_max) do
    Assert.condition(
      stop_count_max >= 1,
      "stop_count_max must be positive, got: #{stop_count_max}"
    )

    %{
      fetches: FetchView.State.new(route_count_max),
      route_stop_ids: %{},
      stops: %{},
      stop_count_max: stop_count_max
    }
  end

  @doc "The number of stops held."
  @spec stop_count(t()) :: non_neg_integer()
  def stop_count(%{stops: stops}), do: map_size(stops)

  @doc "Applies one fetch, as `StopRecords.decode/1` returns it, and says what became of it."
  @spec put(t(), StopRecords.decoded()) :: {t(), outcome()}
  def put(%{fetches: fetches, stop_count_max: stop_count_max} = state, %{id: route_id} = fetch) do
    case FetchView.State.put(fetches, fetch) do
      {fetches, :switched} ->
        fetch_stops = fetch.stops ++ fetch.parent_stops
        listed_ids = Enum.map(fetch_stops, & &1["id"])
        dropped_ids = Map.get(state.route_stop_ids, route_id, []) -- listed_ids
        {stops, removed_ids} = drop(state.stops, dropped_ids, route_id)
        {stops, held_stops} = list(stops, fetch_stops, fetch)

        if map_size(stops) <= stop_count_max do
          route_stop_ids = Map.put(state.route_stop_ids, route_id, listed_ids)
          state = %{state | fetches: fetches, route_stop_ids: route_stop_ids, stops: stops}
          {state, {:switched, %{held_stops: held_stops, removed_ids: removed_ids}}}
        else
          {state, :refused}
        end

      {_fetches, :ignored} ->
        {state, :ignored}
    end
  end

  # The route no longer lists the stops of `dropped_ids`; those no route
  # lists leave.
  defp drop(stops, dropped_ids, route_id) do
    Enum.reduce(dropped_ids, {stops, []}, fn id, {stops, removed_ids} ->
      %{route_ids: route_ids} = stop = Map.fetch!(stops, id)
      route_ids = MapSet.delete(route_ids, route_id)

      if MapSet.size(route_ids) >= 1 do
        {Map.put(stops, id, %{stop | route_ids: route_ids}), removed_ids}
      else
        {Map.delete(stops, id), [id | removed_ids]}
      end
    end)
  end

  # The route lists every stop of the fetch; a stop takes the fetch's values
  # unless its own are from a later fetch.
  defp list(stops, fetch_stops, %{id: route_id, request_id: request_id, fetched_at: fetched_at}) do
    {stops, held_stops} =
      Enum.reduce(fetch_stops, {stops, []}, fn %{"id" => id} = stop, {stops, held_stops} ->
        held_stop = %{id: id, request_id: request_id, fetched_at: fetched_at, stop: stop}

        case Map.fetch(stops, id) do
          {:ok, %{fetched_at: current_fetched_at, route_ids: route_ids} = current} ->
            route_ids = MapSet.put(route_ids, route_id)

            if DateTime.before?(fetched_at, current_fetched_at) do
              {Map.put(stops, id, %{current | route_ids: route_ids}), held_stops}
            else
              entry = %{fetched_at: fetched_at, route_ids: route_ids}
              {Map.put(stops, id, entry), [held_stop | held_stops]}
            end

          :error ->
            entry = %{fetched_at: fetched_at, route_ids: MapSet.new([route_id])}
            {Map.put(stops, id, entry), [held_stop | held_stops]}
        end
      end)

    {stops, Enum.reverse(held_stops)}
  end
end
