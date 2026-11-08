defmodule Gobusgo.OneBusAway.RouteScheduleView.State do
  @service_date_count_max 3

  @moduledoc """
  The rules of the route schedule view: which fetch is current for each
  route and service date, and which dates of each route were attempted.
  Everything here is pure.

  A fetch is a route's schedule on one service date, whole in one record.
  Each route keeps the current fetch of its latest #{@service_date_count_max}
  service dates. The schedule source fetches by the UTC date, which is the
  local date or the one after it, so the dates before, of, and after the UTC
  date hold the local service date, the one before it for its trips that
  run past midnight, and the next one, fetched before it starts (decided in
  GOB-240). A fetch of a later date than all of them makes the earliest
  leave, and a fetch of an earlier date than all of them is ignored.

  For one route and one date, a fetch is ignored when it is the current one
  or is older than it, so records published again change nothing and an old
  fetch never replaces a newer one. A fetch with the same fetch time as the
  current one and another request identifier replaces it.

  An attempt is a date of a route that the schedule source asked for and
  need not ask for again: its response was recorded, or the route has no
  service that date. A route keeps the attempts of its latest
  #{@service_date_count_max} attempted dates, by the same rule as its
  fetches.

  At most `route_count_max` routes have a fetch, and at most as many have an
  attempt; the fetch or the attempt of a route beyond that is ignored.

  The state keeps the request identifier and the fetch time of each current
  fetch, which is all its rules read.
  """

  alias Gobusgo.Assert
  alias Gobusgo.RequestId

  @typedoc "What a fetch has to carry for the rules; a view holds the rest."
  @type fetch :: %{
          required(:id) => String.t(),
          required(:service_date) => Date.t(),
          required(:request_id) => RequestId.t(),
          required(:fetched_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @type header :: %{request_id: RequestId.t(), fetched_at: DateTime.t()}

  @type t :: %{
          routes: %{String.t() => %{Date.t() => header()}},
          attempts: %{String.t() => MapSet.t(Date.t())},
          route_count_max: pos_integer()
        }

  @typedoc """
    * `{:switched, removed_dates}` — the fetch is now the current fetch of
      its route and date, and the route's fetches of `removed_dates` left.
    * `:ignored` — the fetch changed nothing.
  """
  @type outcome :: {:switched, [Date.t()]} | :ignored

  @doc "The number of service dates each route keeps."
  @spec service_date_count_max() :: pos_integer()
  def service_date_count_max, do: @service_date_count_max

  @doc "A view with no fetch and no attempt, for at most `route_count_max` routes."
  @spec new(pos_integer()) :: t()
  def new(route_count_max) when is_integer(route_count_max) do
    Assert.condition(
      route_count_max >= 1,
      "route_count_max must be positive, got: #{route_count_max}"
    )

    %{routes: %{}, attempts: %{}, route_count_max: route_count_max}
  end

  @doc "The service dates of every route that has a fetch, each route's in date order."
  @spec service_dates(t()) :: %{String.t() => [Date.t()]}
  def service_dates(%{routes: routes}) do
    Map.new(routes, fn {route_id, dates} -> {route_id, dates |> Map.keys() |> Enum.sort(Date)} end)
  end

  @doc "The attempted dates of every route that has one, each route's in date order."
  @spec attempts(t()) :: %{String.t() => [Date.t()]}
  def attempts(%{attempts: attempts}) do
    Map.new(attempts, fn {route_id, dates} -> {route_id, Enum.sort(dates, Date)} end)
  end

  @doc """
  Notes that `service_date` of `route_id` was attempted, and returns the
  dates of the route whose attempts left for it.
  """
  @spec attempt(t(), %{route_id: String.t(), service_date: Date.t()}) :: {t(), [Date.t()]}
  def attempt(%{attempts: attempts} = state, %{route_id: route_id, service_date: %Date{} = date})
      when is_binary(route_id) do
    case Map.fetch(attempts, route_id) do
      {:ok, dates} ->
        {kept, removed} = keep_latest(MapSet.put(dates, date))
        {%{state | attempts: Map.put(attempts, route_id, MapSet.new(kept))}, removed}

      :error ->
        if map_size(attempts) < state.route_count_max do
          {%{state | attempts: Map.put(attempts, route_id, MapSet.new([date]))}, []}
        else
          {state, []}
        end
    end
  end

  @doc "Applies one fetch and says what became of it."
  @spec put(t(), fetch()) :: {t(), outcome()}
  def put(%{routes: routes} = state, %{id: route_id} = fetch) when is_binary(route_id) do
    %{service_date: %Date{} = service_date, request_id: request_id} = fetch
    %{fetched_at: %DateTime{} = fetched_at} = fetch

    case Map.fetch(routes, route_id) do
      {:ok, dates} ->
        put_date(state, %{route_id: route_id, dates: dates, fetch: fetch})

      :error ->
        if map_size(routes) < state.route_count_max do
          header = %{request_id: request_id, fetched_at: fetched_at}
          dates = %{service_date => header}
          {%{state | routes: Map.put(routes, route_id, dates)}, {:switched, []}}
        else
          {state, :ignored}
        end
    end
  end

  defp put_date(state, %{route_id: route_id, dates: dates, fetch: fetch}) do
    %{service_date: service_date, request_id: request_id, fetched_at: fetched_at} = fetch
    header = %{request_id: request_id, fetched_at: fetched_at}

    {accepted, removed_dates} =
      case Map.fetch(dates, service_date) do
        {:ok, current} ->
          {not superseded?(current, header), []}

        :error ->
          {_kept, leaving} =
            dates |> Map.keys() |> MapSet.new() |> MapSet.put(service_date) |> keep_latest()

          {service_date not in leaving, leaving}
      end

    if accepted do
      dates = dates |> Map.drop(removed_dates) |> Map.put(service_date, header)
      Assert.condition(map_size(dates) <= @service_date_count_max, "too many service dates")
      {%{state | routes: Map.put(state.routes, route_id, dates)}, {:switched, removed_dates}}
    else
      {state, :ignored}
    end
  end

  # Splits `dates` into the latest that a route keeps and the earlier ones
  # that leave, each in date order.
  defp keep_latest(dates) do
    sorted = Enum.sort(dates, Date)
    leaving_count = max(length(sorted) - @service_date_count_max, 0)
    {leaving, kept} = Enum.split(sorted, leaving_count)
    {kept, leaving}
  end

  defp superseded?(%{request_id: request_id}, %{request_id: request_id}), do: true

  defp superseded?(%{fetched_at: current_fetched_at}, %{fetched_at: fetched_at}) do
    DateTime.before?(fetched_at, current_fetched_at)
  end
end
