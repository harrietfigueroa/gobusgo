defmodule Gobusgo.Pace.Observation do
  @moduledoc """
  The learning step of one fetch: the reports of its vehicles go through
  `Gobusgo.Pace.Learning` into a table, against the vehicles and trip paths
  already held. The rules are in this one function, so a process learning as
  fetches arrive and a task learning from stored fetches add the same cells
  from the same reports. Everything here is pure except the `:path_source`
  function it is given, which reads a path.

  The state is `table`, a `Gobusgo.Pace.Table`; `vehicles`, each vehicle's
  last placed report; `paths`, the trip paths held; and `path_error`, the
  first error a path read raised in the step, or `nil`. A step never holds
  more than `:vehicle_count_max` vehicles or `:path_count_max` paths: a
  vehicle that a report finds stale is forgotten and all of them at the
  bound, and all the paths at the bound. A step reads at most
  `:path_build_count_max` paths with `:path_source`, and a report whose path
  is neither held nor read places its vehicle nowhere.
  """

  @vehicle_count_max_default 20_000
  @path_count_max_default 2_500

  alias Gobusgo.Pace.Learning
  alias Gobusgo.Pace.Table

  @type state :: %{
          table: Table.t(),
          vehicles: %{{String.t(), String.t()} => Learning.placed()},
          paths: %{{String.t(), non_neg_integer()} => Learning.path()},
          path_error: %{message: String.t(), stack: String.t()} | nil
        }

  @type options :: %{
          required(:path_source) => (map(), map() -> {:ok, Learning.path()} | :unavailable),
          required(:views) => map(),
          required(:vehicle_count_max) => pos_integer(),
          required(:path_count_max) => pos_integer(),
          required(:path_build_count_max) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc "The default bound of the vehicles a step holds."
  @spec vehicle_count_max_default() :: pos_integer()
  def vehicle_count_max_default, do: @vehicle_count_max_default

  @doc "The default bound of the trip paths a step holds."
  @spec path_count_max_default() :: pos_integer()
  def path_count_max_default, do: @path_count_max_default

  @doc "A state with `table` and nothing held."
  @spec new(Table.t()) :: state()
  def new(%{cells: _cells} = table) do
    %{table: table, vehicles: %{}, paths: %{}, path_error: nil}
  end

  @doc """
  The state after the `input.reports` of one fetch, as
  `Gobusgo.Pace.Learning.reports/1` returns them, are learned from.
  """
  @spec learn(%{state: state(), reports: [Learning.report()], options: options()}) :: state()
  def learn(%{state: state, reports: [], options: _options}), do: state

  def learn(%{state: state, reports: reports, options: options}) do
    batch = Map.put(state, :builds_left, options.path_build_count_max)
    batch = Enum.reduce(reports, batch, &learn_report(&1, &2, options))
    newest_ms = Enum.max(Enum.map(reports, & &1.at_ms))
    vehicles = forget_stale(batch.vehicles, newest_ms, options.vehicle_count_max)

    %{table: batch.table, vehicles: vehicles, paths: batch.paths, path_error: batch.path_error}
  end

  defp learn_report(report, batch, options) do
    previous = Map.get(batch.vehicles, report.vehicle_key)

    is_repeat =
      previous != nil and previous.at_ms == report.at_ms and previous.trip_key == report.trip_key

    if is_repeat do
      batch
    else
      {path, batch} = path_of(report, batch, options)

      %{placed: placed, cells: cells} =
        Learning.advance(%{previous: previous, report: report, path: path})

      %{
        batch
        | table: Table.add(batch.table, cells),
          vehicles: put_placed(batch.vehicles, report.vehicle_key, placed)
      }
    end
  end

  defp put_placed(vehicles, vehicle_key, nil), do: Map.delete(vehicles, vehicle_key)
  defp put_placed(vehicles, vehicle_key, placed), do: Map.put(vehicles, vehicle_key, placed)

  defp path_of(%{trip_key: trip_key} = report, batch, options) do
    case batch.paths do
      %{^trip_key => path} ->
        {path, batch}

      %{} when batch.builds_left > 0 ->
        batch = %{batch | builds_left: batch.builds_left - 1}
        read_path(report, batch, options)

      %{} ->
        {nil, batch}
    end
  end

  defp read_path(
         %{trip_key: {trip_id, service_date_ms} = trip_key, route_id: route_id},
         batch,
         options
       ) do
    trip = %{route_id: route_id, trip_id: trip_id, service_date_ms: service_date_ms}

    case options.path_source.(trip, options.views) do
      {:ok, path} ->
        paths = hold_path(batch.paths, trip_key, path, options.path_count_max)
        {path, %{batch | paths: paths}}

      :unavailable ->
        {nil, batch}
    end
  rescue
    exception ->
      error = %{
        message: Exception.message(exception),
        stack: Exception.format_stacktrace(__STACKTRACE__)
      }

      {nil, %{batch | path_error: batch.path_error || error}}
  end

  defp hold_path(paths, trip_key, path, path_count_max) do
    if map_size(paths) < path_count_max do
      Map.put(paths, trip_key, path)
    else
      %{trip_key => path}
    end
  end

  defp forget_stale(vehicles, newest_ms, vehicle_count_max) do
    fresh = Map.filter(vehicles, fn {_key, placed} -> not Learning.stale?(placed, newest_ms) end)

    if map_size(fresh) <= vehicle_count_max do
      fresh
    else
      %{}
    end
  end
end
