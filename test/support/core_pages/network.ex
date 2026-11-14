defmodule Gobusgo.Test.CorePages.Network do
  @moduledoc """
  The transit network the core page check plans over, and the files the
  test server serves for it. The network is two routes of one agency:
  route 10 runs north and south along one street every ten minutes, and
  route 20 east and west every fifteen, from the start of each service day
  to past its midnight, and they share the stop at their crossing, where a
  journey changes. `seed/2` fills the application's views with it the way
  the processors would, for the service dates around the instant it is
  given, builds their routing snapshots with
  `Gobusgo.Routing.Snapshots.Build`, and writes a basemap manifest and an
  empty basemap archive, so the vehicle page draws its map and plans trips
  in the browser from files the server built.

  The page tells a copy from a cache by the server's render time against
  its own clock, so a browser's clock is pinned to the time of the run and
  the network runs on the dates around it. A service day here starts at
  08:00 UTC, midnight in Pacific Standard Time and 01:00 in Pacific Daylight
  Time, since the application carries no time zone database; the check
  compares the two cores at one instant, which that hour moves for both.
  """

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Routing.Snapshots.Build

  @agency_id "1"
  @agency_name "Metro Transit"
  @sha String.duplicate("ab", 32)
  @service_day_start_time ~T[08:00:00]
  @service_day_offset_s 8 * 60 * 60
  @basemap_archive "basemap-20261118-01.pmtiles"
  @bounds %{"south" => 47.58, "west" => -122.37, "north" => 47.64, "east" => -122.30}

  @first_departure_s 0
  @last_departure_s 26 * 60 * 60

  @routes [
    %{
      id: "1_10",
      short_name: "10",
      long_name: "Belltown - Pioneer Square",
      color: "005BAA",
      headway_s: 10 * 60,
      hop_s: 2 * 60,
      offset_s: 0,
      headsigns: {"Belltown", "Pioneer Square"},
      stops: ["1_1001", "1_1002", "1_1003", "1_1004", "1_1005", "1_1006"]
    },
    %{
      id: "1_20",
      short_name: "20",
      long_name: "Elliott Bay - Capitol Hill",
      color: "C8102E",
      headway_s: 15 * 60,
      hop_s: 3 * 60,
      offset_s: 5 * 60,
      headsigns: {"Capitol Hill", "Elliott Bay"},
      stops: ["1_2001", "1_2002", "1_1003", "1_2004", "1_2005"]
    }
  ]

  @stops %{
    "1_1001" => %{name: "3rd Ave & Yesler Way", code: "1001", lat: 47.6010, lon: -122.3330},
    "1_1002" => %{name: "3rd Ave & Columbia St", code: "1002", lat: 47.6045, lon: -122.3345},
    "1_1003" => %{name: "3rd Ave & Pike St", code: "1003", lat: 47.6085, lon: -122.3380},
    "1_1004" => %{name: "3rd Ave & Virginia St", code: "1004", lat: 47.6120, lon: -122.3420},
    "1_1005" => %{name: "3rd Ave & Bell St", code: "1005", lat: 47.6155, lon: -122.3460},
    "1_1006" => %{name: "3rd Ave & Cedar St", code: "1006", lat: 47.6190, lon: -122.3500},
    "1_2001" => %{name: "Alaskan Way & Pike St", code: "2001", lat: 47.6075, lon: -122.3440},
    "1_2002" => %{name: "1st Ave & Pike St", code: "2002", lat: 47.6080, lon: -122.3410},
    "1_2004" => %{name: "6th Ave & Pike St", code: "2004", lat: 47.6105, lon: -122.3330},
    "1_2005" => %{name: "Broadway & Pike St", code: "2005", lat: 47.6140, lon: -122.3210}
  }

  @doc "The name of the stop `stop_id`."
  @spec stop_name(String.t()) :: String.t()
  def stop_name(stop_id), do: Map.fetch!(@stops, stop_id).name

  @doc """
  Fills the views for the service date `now` falls in and the two after
  it, the three dates the schedule view holds of a route, so a scenario of
  tomorrow finds its date in either Pacific offset; builds their routing
  snapshots into `base_dir`; and writes the basemap there, under the
  directories the application's settings name once `configure/1` has
  pointed them at `base_dir`.
  """
  @spec seed(String.t(), DateTime.t()) :: :ok
  def seed(base_dir, %DateTime{} = now) when is_binary(base_dir) do
    today = now |> DateTime.add(-@service_day_offset_s, :second) |> DateTime.to_date()
    service_dates = Enum.map(0..2, &Date.add(today, &1))
    :ok = seed_agency()
    :ok = seed_routes()
    :ok = seed_stops()
    :ok = seed_schedules(service_dates)

    {:ok, %{built_count: 3}} =
      Build.run(
        server: Gobusgo.Routing.Snapshots,
        clock: fn -> now end,
        write_options: [base_dir: base_dir]
      )

    write_basemap(Path.join(base_dir, "basemap"))
  end

  @doc """
  Points the directories the endpoint serves and the local reader and
  writer at `base_dir`, starts the tile archive's process again so it
  finds no archive there, and returns a function that puts back the
  settings as they were.
  """
  @spec configure(String.t()) :: (-> :ok)
  def configure(base_dir) when is_binary(base_dir) do
    keys = [
      :basemap,
      :routing,
      :tiles,
      :places,
      :addresses,
      :intersections,
      :shared_vehicle_tiles
    ]

    storage_keys = [Gobusgo.Reader.LocalFile, Gobusgo.Writer.LocalFile, Gobusgo.Deleter.LocalFile]
    configured = Map.new(keys ++ storage_keys, &{&1, Application.get_env(:gobusgo, &1)})

    for key <- keys do
      Application.put_env(:gobusgo, key, dir: Path.join(base_dir, directory(key)))
    end

    for key <- storage_keys, do: Application.put_env(:gobusgo, key, base_dir: base_dir)
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, GobusgoWeb.RouteStopTiles)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, GobusgoWeb.RouteStopTiles)

    fn ->
      for {key, value} <- configured, do: Application.put_env(:gobusgo, key, value)
      :ok
    end
  end

  defp directory(:basemap), do: "basemap"
  defp directory(:routing), do: "routing"
  defp directory(:tiles), do: "tiles"
  defp directory(:places), do: "places"
  defp directory(:addresses), do: "addresses"
  defp directory(:intersections), do: "intersections"
  defp directory(:shared_vehicle_tiles), do: "shared-vehicles"

  defp seed_agency do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-11-18/file.json",
        fetched_at: DateTime.utc_now(),
        data_sha256: @sha,
        request_id: Gobusgo.RequestId.generate(),
        agencies: [
          %{
            id: @agency_id,
            name: @agency_name,
            url: "https://agency-1.example.test",
            timezone: "America/Los_Angeles",
            coverage: %{lat: 47.61, lon: -122.335, lat_span: 0.06, lon_span: 0.07}
          }
        ]
      })

    AgencyView.apply_records(AgencyView, Enum.map(records ++ [manifest], & &1.value))
  end

  defp seed_routes do
    record =
      RouteBatch.Records.build(%{
        agency_id: @agency_id,
        destination: "raw/oba/routes-for-agency/dt=2026-11-18/agency=1/file.json.gz",
        fetched_at: DateTime.utc_now(),
        data_sha256: @sha,
        request_id: Gobusgo.RequestId.generate(),
        routes:
          for route <- @routes do
            %{
              id: route.id,
              agency_id: @agency_id,
              short_name: route.short_name,
              long_name: route.long_name,
              description: nil,
              type: 3,
              color: route.color,
              text_color: nil,
              url: nil
            }
          end
      })

    FetchView.apply_records(Gobusgo.OneBusAway.RouteView, [record.value])
  end

  defp seed_stops do
    records =
      for route <- @routes do
        StopRecords.build(%{
          route_id: route.id,
          destination: "raw/oba/stops-for-route/dt=2026-11-18/route=#{route.id}/file.json.gz",
          fetched_at: DateTime.utc_now(),
          data_sha256: @sha,
          request_id: Gobusgo.RequestId.generate(),
          route_path: %{
            route_id: route.id,
            stop_ids: route.stops,
            polylines: [],
            stop_groupings: [],
            stops: Enum.map(route.stops, &stop_of(&1, route.id)),
            parent_stops: []
          }
        }).value
      end

    StopView.apply_records(StopView, records)
  end

  defp stop_of(stop_id, route_id) do
    stop = Map.fetch!(@stops, stop_id)

    %{
      id: stop_id,
      name: stop.name,
      lat: stop.lat,
      lon: stop.lon,
      code: stop.code,
      direction: "N",
      location_type: 0,
      parent: nil,
      wheelchair_boarding: "UNKNOWN",
      route_ids: route_ids_at(stop_id, route_id)
    }
  end

  defp route_ids_at(stop_id, route_id) do
    for route <- @routes, stop_id in route.stops or route.id == route_id, do: route.id
  end

  defp seed_schedules(service_dates) do
    records =
      for service_date <- service_dates, route <- @routes do
        {:ok, schedule} = RouteSchedules.parse(schedule_data(route, service_date), route.id)

        RouteScheduleBatch.Records.build(%{
          route_id: route.id,
          service_date: service_date,
          request_id: Gobusgo.RequestId.generate(),
          fetched_at: DateTime.utc_now(),
          data_sha256: @sha,
          destination: "raw/oba/schedule-for-route/dt=#{service_date}/route=#{route.id}",
          schedule: schedule
        }).value
      end

    RouteScheduleView.apply_records(RouteScheduleView, records)
  end

  # The `data` member of a schedule-for-route response: every trip of both
  # directions of `route` on `service_date`.
  defp schedule_data(route, service_date) do
    day_start = DateTime.new!(service_date, @service_day_start_time, "Etc/UTC")
    {outbound, inbound} = route.headsigns

    directions = [
      {"0", outbound, route.stops},
      {"1", inbound, Enum.reverse(route.stops)}
    ]

    trips =
      for {direction_id, headsign, stop_ids} <- directions,
          departure_s <- departures(route) do
        %{
          id: "#{route.id}_#{direction_id}_#{departure_s}",
          direction_id: direction_id,
          headsign: headsign,
          stop_ids: stop_ids,
          departure_s: departure_s
        }
      end

    %{
      "entry" => %{
        "routeId" => route.id,
        "scheduleDate" => DateTime.to_unix(day_start, :millisecond),
        "serviceIds" => ["1_weekday"],
        "stopTripGroupings" =>
          for {direction_id, headsign, stop_ids} <- directions do
            direction_trips = Enum.filter(trips, &(&1.direction_id == direction_id))

            %{
              "directionId" => direction_id,
              "stopIds" => stop_ids,
              "tripHeadsigns" => [headsign],
              "tripIds" => Enum.map(direction_trips, & &1.id),
              "tripsWithStopTimes" =>
                Enum.map(direction_trips, &trip_with_stop_times(&1, route.hop_s))
            }
          end
      },
      "references" => %{
        "trips" =>
          for trip <- trips do
            %{
              "id" => trip.id,
              "directionId" => trip.direction_id,
              "tripHeadsign" => trip.headsign,
              "blockId" => "",
              "serviceId" => "1_weekday",
              "shapeId" => "",
              "routeId" => route.id
            }
          end
      }
    }
  end

  defp departures(route) do
    Enum.to_list((@first_departure_s + route.offset_s)..@last_departure_s//route.headway_s)
  end

  defp trip_with_stop_times(trip, hop_s) do
    last_index = length(trip.stop_ids) - 1

    %{
      "tripId" => trip.id,
      "stopTimes" =>
        for {stop_id, index} <- Enum.with_index(trip.stop_ids) do
          time_s = trip.departure_s + index * hop_s

          %{
            "stopId" => stop_id,
            "tripId" => trip.id,
            "arrivalTime" => time_s,
            "departureTime" => time_s,
            "arrivalEnabled" => index > 0,
            "departureEnabled" => index < last_index
          }
        end
    }
  end

  defp write_basemap(dir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, @basemap_archive), empty_archive())

    manifest = %{
      "snapshot" => "20261118",
      "archives" => [%{"name" => @basemap_archive, "bounds" => @bounds}],
      "agencies" => [
        %{"agencyId" => @agency_id, "archive" => @basemap_archive, "bounds" => @bounds}
      ]
    }

    File.write!(Path.join(dir, "manifest.json"), JSON.encode!(manifest))
  end

  # A PMTiles archive of version 3 that holds no tile: the header, a root
  # directory of no entries, and the metadata, uncompressed, so the map
  # draws its style over an empty basemap and the check depends on no
  # extracted archive.
  # https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md — checked 2026-11-14
  defp empty_archive do
    header_bytes = 127
    root_directory = <<0>>
    metadata = JSON.encode!(%{"vector_layers" => []})
    root_offset = header_bytes
    metadata_offset = root_offset + byte_size(root_directory)
    data_offset = metadata_offset + byte_size(metadata)
    compression_none = 1
    tile_type_mvt = 1

    header =
      <<"PMTiles", 3, root_offset::little-64, byte_size(root_directory)::little-64,
        metadata_offset::little-64, byte_size(metadata)::little-64, 0::little-64, 0::little-64,
        data_offset::little-64, 0::little-64, 0::little-64, 0::little-64, 0::little-64, 1,
        compression_none, compression_none, tile_type_mvt, 0, 14,
        microdegrees_e7(@bounds["west"])::little-signed-32,
        microdegrees_e7(@bounds["south"])::little-signed-32,
        microdegrees_e7(@bounds["east"])::little-signed-32,
        microdegrees_e7(@bounds["north"])::little-signed-32, 13,
        microdegrees_e7(-122.335)::little-signed-32, microdegrees_e7(47.61)::little-signed-32>>

    ^header_bytes = byte_size(header)
    header <> root_directory <> metadata
  end

  defp microdegrees_e7(degrees), do: round(degrees * 10_000_000)
end
