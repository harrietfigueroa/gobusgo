defmodule Gobusgo.OneBusAway.RouteScheduleView do
  @moduledoc """
  The current schedule of each route on its latest service dates, held in
  memory for readers. This module owns the process and the table; the rules
  that decide which fetch is current live in
  `Gobusgo.OneBusAway.RouteScheduleView.State`.

  A view is a process registered under a name and a table of the same name.
  `apply_records/2` hands it record values, each one route's schedule on one
  service date as `Gobusgo.OneBusAway.RouteScheduleBatch.Records` builds
  it; `schedule/3`, `service_dates/2`, and `counts/1` read the table and
  never wait on the process. The table holds each route's fetch of one date
  as one entry, its schedule in the form `Gobusgo.OneBusAway.CompactSchedule`
  packs, so a reader sees a whole schedule or the one before it.

  A record of another type is passed over and not counted. Any other value
  that is not a record is skipped. Each call logs `debug` when a current
  fetch changed and `warning` with the count of skipped values.

  A view starts empty. It holds nothing across a restart.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.OneBusAway.RouteScheduleView.State
  alias Gobusgo.Publisher

  @call_timeout_ms 5_000

  @typedoc "What the view holds, for verification."
  @type counts :: %{
          route_count: non_neg_integer(),
          schedule_count: non_neg_integer(),
          trip_count: non_neg_integer(),
          stop_time_count: non_neg_integer()
        }

  @doc """
  Starts a view registered under `options[:name]`, holding the schedules of
  at most `options[:route_count_max]` routes.
  """
  @spec start_link(name: atom(), route_count_max: pos_integer()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :route_count_max])
    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    server = %{name: name, route_count_max: Keyword.fetch!(options, :route_count_max)}
    GenServer.start_link(__MODULE__, server, name: name)
  end

  @doc "The specification of a view as a supervisor's child, with the view's name as its identifier."
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(options) when is_list(options) do
    %{id: Keyword.fetch!(options, :name), start: {__MODULE__, :start_link, [options]}}
  end

  @doc """
  Returns the current fetch of `route_id` on `service_date` in `view`, as
  `Gobusgo.OneBusAway.RouteScheduleBatch.Records.decode/1` returns it, or
  `nil` for a route and date the view does not hold and while the view is
  not running.
  """
  @spec schedule(atom(), String.t(), Date.t()) :: Records.decoded() | nil
  def schedule(view, route_id, %Date{} = service_date)
      when is_atom(view) and is_binary(route_id) do
    key = {route_id, service_date}

    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, key) do
          [{^key, fetch}] -> fetch
          [] -> nil
        end
    end
  end

  @doc """
  Returns the service dates `view` holds a schedule of `route_id` for, in
  date order. Returns `[]` while the view is not running.
  """
  @spec service_dates(atom(), String.t()) :: [Date.t()]
  def service_dates(view, route_id) when is_atom(view) and is_binary(route_id) do
    case :ets.whereis(view) do
      :undefined ->
        []

      table ->
        table
        |> :ets.select([{{{route_id, :"$1"}, :_}, [], [:"$1"]}])
        |> Enum.sort(Date)
    end
  end

  @doc """
  Returns the count of routes `view` holds a schedule of, of schedules, and
  of the trips and stop times they hold together. Every count is `0` while
  the view is not running.
  """
  @spec counts(atom()) :: counts()
  def counts(view) when is_atom(view) do
    schedules =
      case :ets.whereis(view) do
        :undefined -> []
        table -> :ets.select(table, [{{{:"$1", :_}, %{schedule: :"$2"}}, [], [{{:"$1", :"$2"}}]}])
      end

    %{
      route_count:
        schedules |> Enum.uniq_by(fn {route_id, _schedule} -> route_id end) |> length(),
      schedule_count: length(schedules),
      trip_count: Enum.sum_by(schedules, fn {_route_id, schedule} -> length(schedule.trips) end),
      stop_time_count:
        Enum.sum_by(schedules, fn {_route_id, schedule} -> schedule.stop_time_count end)
    }
  end

  @doc """
  Applies `values`, at most `Gobusgo.Publisher.record_count_max/0` record
  values, to `view` in order, and returns once the table reflects them.
  Exits when the view does not answer within #{@call_timeout_ms} ms.
  """
  @spec apply_records(atom(), [binary()]) :: :ok
  def apply_records(view, values) when is_atom(view) and is_list(values) do
    count = length(values)

    Assert.condition(
      count <= Publisher.record_count_max(),
      "values must hold at most #{Publisher.record_count_max()} records, got: #{count}"
    )

    GenServer.call(view, {:apply_records, values}, @call_timeout_ms)
  end

  @impl GenServer
  def init(%{name: name, route_count_max: route_count_max} = server) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, server |> Map.put(:table, table) |> Map.put(:state, State.new(route_count_max))}
  end

  @impl GenServer
  def handle_call({:apply_records, values}, _from, %{name: name} = server) do
    counts = %{switched: 0, invalid: 0}
    {state, counts} = Enum.reduce(values, {server.state, counts}, &apply_value(&1, &2, server))

    if counts.switched >= 1 do
      Logger.debug("Route schedule view switched",
        view: inspect(name),
        schedule_count: counts.switched
      )
    end

    if counts.invalid >= 1 do
      Logger.warning("Route schedule view skipped invalid records",
        view: inspect(name),
        invalid_count: counts.invalid
      )
    end

    {:reply, :ok, %{server | state: state}}
  end

  # The fetch is written before the dates that leave are deleted, so a
  # reader of the route finds a schedule throughout.
  defp apply_value(value, {state, counts}, %{table: table}) do
    case Records.decode(value) do
      {:ok, %{id: route_id, service_date: service_date} = fetch} ->
        case State.put(state, fetch) do
          {state, {:switched, removed_dates}} ->
            true = :ets.insert(table, {{route_id, service_date}, fetch})
            Enum.each(removed_dates, &:ets.delete(table, {route_id, &1}))
            {state, %{counts | switched: counts.switched + 1}}

          {state, :ignored} ->
            {state, counts}
        end

      {:error, :unsupported_type} ->
        {state, counts}

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end
end
