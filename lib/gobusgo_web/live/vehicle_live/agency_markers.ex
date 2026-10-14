defmodule GobusgoWeb.VehicleLive.AgencyMarkers do
  @moduledoc """
  The vehicle markers a vehicle page sends, one event per agency, and the
  request each agency's markers came from, which is all a page keeps of
  them.

  It reads the vehicle view and the stop view, and changes nothing: an
  update is returned as the events to send and the requests then shown.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleFilter
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.VehicleLive.Filter
  alias GobusgoWeb.VehicleMarkers

  @typedoc "The request the markers shown of each agency came from, by agency identifier."
  @type request_ids :: %{String.t() => String.t()}

  @typedoc "Every marker of one agency."
  @type event :: %{agency_id: String.t(), markers: [map()]}

  @doc "The current request of every agency that `filter` keeps."
  @spec kept_request_ids(Filter.t()) :: request_ids()
  def kept_request_ids(filter) do
    for {agency_id, request_id} <- VehicleView.current_request_ids(VehicleView),
        Filter.keeps_agency?(filter, agency_id),
        into: %{} do
      {agency_id, request_id}
    end
  end

  @doc "Every agency that has a fetch or whose markers are shown, in identifier order."
  @spec every_agency_id(request_ids()) :: [String.t()]
  def every_agency_id(shown_request_ids) when is_map(shown_request_ids) do
    request_ids = VehicleView.current_request_ids(VehicleView)
    request_ids |> Map.merge(shown_request_ids) |> Map.keys() |> Enum.sort()
  end

  @doc """
  The agencies whose shown markers are out of date: every agency of
  `request_ids` whose request is another than the one shown, then every
  agency shown that `request_ids` does not hold.
  """
  @spec changed_agency_ids(%{shown_request_ids: request_ids(), request_ids: request_ids()}) ::
          [String.t()]
  def changed_agency_ids(%{shown_request_ids: shown_request_ids, request_ids: request_ids})
      when is_map(shown_request_ids) and is_map(request_ids) do
    changed =
      for {agency_id, request_id} <- request_ids,
          Map.get(shown_request_ids, agency_id) != request_id do
        agency_id
      end

    removed =
      for {agency_id, _request_id} <- shown_request_ids, not is_map_key(request_ids, agency_id) do
        agency_id
      end

    Enum.sort(changed) ++ Enum.sort(removed)
  end

  @doc """
  The events that bring the agencies of `agency_ids` up to date, in that
  order, and the requests shown once they are sent. An agency `filter` keeps
  that has a fetch gets the markers of the fetch that the filter keeps. Any
  other agency gets an event with no marker when its markers are shown, and
  none when they are not.
  """
  @spec updates(%{
          filter: Filter.t(),
          agency_ids: [String.t()],
          shown_request_ids: request_ids()
        }) :: %{events: [event()], shown_request_ids: request_ids()}
  def updates(%{filter: filter, agency_ids: agency_ids, shown_request_ids: shown_request_ids})
      when is_list(agency_ids) and is_map(shown_request_ids) do
    updates =
      Enum.reduce(agency_ids, %{events: [], shown_request_ids: shown_request_ids}, fn
        agency_id, updates ->
          case kept_fetch(filter, agency_id) do
            nil -> clear(updates, agency_id)
            fetch -> show(updates, fetch)
          end
      end)

    %{updates | events: Enum.reverse(updates.events)}
  end

  # The fetch is read only for an agency the filter keeps.
  defp kept_fetch(filter, agency_id) do
    case Filter.keeps_agency?(filter, agency_id) do
      false ->
        nil

      true ->
        case VehicleView.current_fetch(VehicleView, agency_id) do
          nil ->
            nil

          %{agency_id: fetch_agency_id} = fetch ->
            Assert.condition(
              fetch_agency_id == agency_id,
              "fetch must be of agency #{inspect(agency_id)}, got: #{inspect(fetch_agency_id)}"
            )

            VehicleFilter.filter_fetch(%{filter: filter, fetch: fetch})
        end
    end
  end

  defp show(updates, kept) do
    event = VehicleMarkers.agency_markers(kept, stop_names(VehicleMarkers.next_stop_ids(kept)))
    %{agency_id: agency_id, markers: markers} = event

    %{
      events: [%{agency_id: agency_id, markers: markers} | updates.events],
      shown_request_ids: Map.put(updates.shown_request_ids, agency_id, kept.request_id)
    }
  end

  defp clear(%{shown_request_ids: shown_request_ids} = updates, agency_id) do
    case is_map_key(shown_request_ids, agency_id) do
      true ->
        %{
          events: [%{agency_id: agency_id, markers: []} | updates.events],
          shown_request_ids: Map.delete(shown_request_ids, agency_id)
        }

      false ->
        updates
    end
  end

  # The name of each of the stops that the stop view holds.
  defp stop_names(stop_ids) do
    for stop_id <- stop_ids, held_stop = StopView.stop(StopView, stop_id), into: %{} do
      {stop_id, Map.fetch!(held_stop.stop, "name")}
    end
  end
end
