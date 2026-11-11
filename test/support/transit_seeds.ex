defmodule Gobusgo.Test.TransitSeeds do
  @moduledoc """
  Fills the application's global views for a test with records built the way
  the processors build them, so a test states the agencies, routes, stops,
  vehicles, and arrivals it needs and nothing else of a fetch.

  Every fetch gets a request identifier no earlier fetch of the run had, so
  an answer held under the identity of one fetch is never found under
  another's. Fetches are made at the time the test runs, for the arrivals
  view drops a fetch by the real clock.
  """

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleBatch
  alias Gobusgo.OneBusAway.VehicleView

  @arrival_view Gobusgo.OneBusAway.ArrivalView
  @route_view Gobusgo.OneBusAway.RouteView
  @views [AgencyView, VehicleView, StopView, @arrival_view, @route_view]
  @sha String.duplicate("ab", 32)

  @doc "Restarts every view the seeds fill, so the next test starts from none."
  @spec restart_views() :: :ok
  def restart_views do
    for view <- @views do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end

    :ok
  end

  @doc "A request identifier that no other call of the run returned."
  @spec request_id() :: String.t()
  def request_id do
    sequence = System.unique_integer([:positive, :monotonic])
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  @doc "A fetch of agencies, each `{id, name}`, now."
  @spec agencies([{String.t(), String.t()}]) :: :ok
  def agencies(agencies) do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
        fetched_at: now(),
        data_sha256: @sha,
        request_id: request_id(),
        agencies:
          for {id, name} <- agencies do
            %{
              id: id,
              name: name,
              url: "https://agency-#{id}.example.test",
              timezone: "America/Los_Angeles",
              coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
            }
          end
      })

    AgencyView.apply_records(AgencyView, Enum.map(records ++ [manifest], & &1.value))
  end

  @doc "A fetch of the routes `routes` of `agency_id`, each `{id, short name, long name}`, now."
  @spec routes(String.t(), [{String.t(), String.t() | nil, String.t() | nil}]) :: :ok
  def routes(agency_id, routes) do
    record =
      RouteBatch.Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/routes-for-agency/dt=2026-10-05/agency=#{agency_id}/file.json.gz",
        fetched_at: now(),
        data_sha256: @sha,
        request_id: request_id(),
        routes:
          for {id, short_name, long_name} <- routes do
            %{
              id: id,
              agency_id: agency_id,
              short_name: short_name,
              long_name: long_name,
              description: nil,
              type: 3,
              color: nil,
              text_color: nil,
              url: nil
            }
          end
      })

    FetchView.apply_records(@route_view, [record.value])
  end

  @doc """
  A fetch of the stops of one route, each `{id, name, code}`, now. The
  route's identifier makes the fetch the route's, so two calls with the
  same route replace each other.
  """
  @spec stops(String.t(), [{String.t(), String.t(), String.t() | nil}]) :: :ok
  def stops(route_id, stops) do
    stop_ids = for {id, _name, _code} <- stops, do: id

    record =
      StopRecords.build(%{
        route_id: route_id,
        destination: "raw/oba/stops-for-route/dt=2026-10-07/route=#{route_id}/file.json.gz",
        fetched_at: now(),
        data_sha256: @sha,
        request_id: request_id(),
        route_path: %{
          route_id: route_id,
          stop_ids: stop_ids,
          polylines: [],
          stop_groupings: [],
          stops:
            for {id, name, code} <- stops do
              %{
                id: id,
                name: name,
                lat: 47.6,
                lon: -122.3,
                code: code,
                direction: "N",
                location_type: 0,
                parent: nil,
                wheelchair_boarding: "UNKNOWN",
                route_ids: [route_id]
              }
            end,
          parent_stops: []
        }
      })

    StopView.apply_records(StopView, [record.value])
  end

  @doc "A fetch of the vehicles of `agency_id`, each `{id, route id}`, now."
  @spec vehicles(String.t(), [{String.t(), String.t() | nil}]) :: :ok
  def vehicles(agency_id, vehicles) do
    fetched_at = now()

    %{vehicles: records, manifest: manifest} =
      VehicleBatch.Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/vehicles-for-agency/dt=2026-10-02/agency=#{agency_id}/file.json",
        fetched_at: fetched_at,
        data_sha256: @sha,
        request_id: request_id(),
        vehicles:
          for {id, route_id} <- vehicles do
            %{
              id: id,
              active_trip_id: nil,
              route_id: route_id,
              route_short_name: nil,
              route_long_name: nil,
              trip_headsign: nil,
              position: %{lat: 47.66, lon: -122.34},
              orientation: nil,
              last_known_location: nil,
              last_known_orientation: nil,
              last_update_time_ms: nil,
              last_location_update_time_ms: DateTime.to_unix(fetched_at, :millisecond),
              predicted: true,
              schedule_deviation_seconds: nil,
              next_stop_id: nil,
              next_stop_time_offset_seconds: nil,
              service_date_ms: nil
            }
          end
      })

    VehicleView.apply_records(VehicleView, Enum.map(records ++ [manifest], & &1.value))
  end

  @doc """
  A fetch of the arrivals at `stop_id`, each arrival a trip of route `36`
  scheduled `{trip identifier, minutes from now}`, now.
  """
  @spec arrivals(String.t(), [{String.t(), pos_integer()}]) :: :ok
  def arrivals(stop_id, arrivals) do
    now_ms = DateTime.to_unix(now(), :millisecond)

    record =
      ArrivalBatch.Records.build(%{
        stop_id: stop_id,
        destination:
          "raw/oba/arrivals-and-departures-for-stop/dt=2026-10-07/stop=#{stop_id}/file.json.gz",
        fetched_at: now(),
        data_sha256: @sha,
        request_id: request_id(),
        arrivals:
          for {trip_id, minutes} <- arrivals do
            time_ms = now_ms + minutes * 60_000 + 30_000

            %{
              trip_id: trip_id,
              service_date_ms: 1_791_270_000_000,
              stop_sequence: 5,
              route_id: "1_100210",
              route_short_name: "36",
              route_long_name: nil,
              trip_headsign: "Othello Station",
              arrival_enabled: true,
              departure_enabled: true,
              scheduled_arrival_time_ms: time_ms,
              scheduled_departure_time_ms: time_ms,
              predicted: false,
              predicted_arrival_time_ms: nil,
              predicted_departure_time_ms: nil,
              vehicle_id: nil,
              vehicle_schedule_deviation_seconds: nil
            }
          end
      })

    FetchView.apply_records(@arrival_view, [record.value])
  end

  # Each call is later than the last by at least a millisecond, which is
  # how a view tells a newer fetch of one identifier from an older.
  defp now do
    millisecond_count = System.unique_integer([:positive, :monotonic])
    DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), millisecond_count, :millisecond)
  end
end
