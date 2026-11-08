defmodule GobusgoWeb.VehicleLive.OpenStops do
  @auto_open_count_max 5
  @favorite_count_max 6

  @moduledoc """
  The stops a vehicle page has open: their registration in the demand
  registry, which is what has the arrival source fetch them, and the
  arrivals the page sends for each.

  A page opens a stop for each popup that opens by itself, at most
  #{@auto_open_count_max}, for each rider's favorite, at most
  #{@favorite_count_max}, for each popup a rider opens, and for the stop
  the panel sheet's details view shows.
  `open_count_max/0`, their sum, is the bound on the stops one page holds
  open, so the favorites and the popups that open by themselves always have
  room.

  A page keeps, per open stop, a hash of what it last sent for it and no
  arrival; `nil` stands for a stop it has sent nothing for.

  The calling process holds the registrations. An update is returned as the
  events to send and the hashes then kept.
  """

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.StopArrivals

  @arrival_view Gobusgo.OneBusAway.ArrivalView

  @typedoc "The hash of what was last sent for each open stop, by stop identifier."
  @type t :: %{String.t() => non_neg_integer() | nil}

  @doc "The most popups whose stops open by themselves on one page."
  @spec auto_open_count_max() :: pos_integer()
  def auto_open_count_max, do: @auto_open_count_max

  @doc "The most stops a rider keeps as favorites."
  @spec favorite_count_max() :: pos_integer()
  def favorite_count_max, do: @favorite_count_max

  @doc "The most stops one page has open in the demand registry."
  @spec open_count_max() :: pos_integer()
  def open_count_max, do: @auto_open_count_max + @favorite_count_max

  @doc """
  Registers the stop as open for the calling process: `:refused` for a stop
  the stop view does not hold, and `:busy` when the registry has no place
  for it or does not answer.
  """
  @spec open(String.t()) :: :ok | :refused | :busy
  def open(stop_id) when is_binary(stop_id) do
    case StopView.stop(StopView, stop_id) do
      nil ->
        :refused

      _held_stop ->
        case registration(stop_id) do
          :ok -> :ok
          {:error, _bound_exceeded} -> :busy
          :registry_unavailable -> :busy
        end
    end
  end

  @doc "Ends the calling process's registration of the stop."
  @spec release(String.t()) :: :ok
  def release(stop_id) when is_binary(stop_id) do
    Demand.release(Demand, DemandKey.arrivals(stop_id))
  catch
    # A registry that is down holds no registration to release.
    :exit, _reason -> :ok
  end

  @doc """
  Registers every stop of `open_stops` for the calling process and returns
  the stops the registry refuses, in identifier order. A registry that does
  not answer refuses nothing.
  """
  @spec register(t()) :: [String.t()]
  def register(open_stops) when is_map(open_stops) do
    for stop_id <- Enum.sort(Map.keys(open_stops)),
        match?({:error, _bound_exceeded}, registration(stop_id)) do
      stop_id
    end
  end

  @doc """
  The events for the stops of `stop_ids`, each an open stop, in that order,
  and the hashes kept once they are sent. A stop gets an event when what the
  page shows for it differs from what was last sent.
  """
  @spec updates(%{open_stops: t(), stop_ids: [String.t()]}) ::
          %{events: [StopArrivals.t()], open_stops: t()}
  def updates(%{open_stops: open_stops, stop_ids: stop_ids})
      when is_map(open_stops) and is_list(stop_ids) do
    updates =
      Enum.reduce(stop_ids, %{events: [], open_stops: open_stops}, fn stop_id, updates ->
        shown = stop_arrivals(stop_id)
        version = :erlang.phash2(shown)

        case updates.open_stops do
          %{^stop_id => ^version} ->
            updates

          open_stops ->
            %{
              events: [shown | updates.events],
              open_stops: Map.put(open_stops, stop_id, version)
            }
        end
      end)

    %{updates | events: Enum.reverse(updates.events)}
  end

  # A registry that is down or does not answer in time exits the call.
  defp registration(stop_id) do
    Demand.register(Demand, DemandKey.arrivals(stop_id))
  catch
    :exit, _reason -> :registry_unavailable
  end

  defp stop_arrivals(stop_id) do
    case FetchView.current_fetch(@arrival_view, stop_id) do
      nil ->
        StopArrivals.waiting(stop_id)

      fetch ->
        vehicles =
          for vehicle_id <- StopArrivals.vehicle_ids(fetch),
              vehicle = VehicleView.vehicle(VehicleView, vehicle_id),
              into: %{} do
            {vehicle_id, vehicle}
          end

        StopArrivals.arrivals(%{fetch: fetch, vehicles: vehicles, now: DateTime.utc_now()})
    end
  end
end
