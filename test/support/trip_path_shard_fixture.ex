defmodule Gobusgo.Test.TripPathShardFixture do
  @moduledoc """
  The input of the shared trip path fixtures under
  `test/fixtures/routing/trip-paths-v1/`: `shard.bin`, the shard of King
  County Metro's loop route 1_7994 on 2026-11-09, built from its stored
  route path and schedule by `Gobusgo.Routing.TripPathShard.build/1`,
  `shard.bin.gz`, the same bytes as one gzip stream, `index.bin` and
  `index.bin.gz`, an index of two hand-written records, and
  `expected.json`, what a reader decodes from them. The index names fixed
  hashes, since a shard's stream hash depends on the compressor.
  """

  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.RoutePaths
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.Routing.TripPathIndex
  alias Gobusgo.Routing.TripPathShard

  @directory Path.expand("../fixtures/routing/trip-paths-v1", __DIR__)
  @source_directory Path.expand("../fixtures/one_bus_away/trip_path", __DIR__)
  @route_id "1_7994"

  @index_shards [
    %{
      route_id: "1_100479",
      path:
        "/routing/snapshots/dt=2026-11-09/trip-paths-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.bin.gz",
      byte_size: 3_100,
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    },
    %{
      route_id: @route_id,
      path:
        "/routing/snapshots/dt=2026-11-09/trip-paths-fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210.bin.gz",
      byte_size: 4_294_967_295,
      sha256: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    }
  ]

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The route the shard fixture holds."
  @spec route_id() :: String.t()
  def route_id, do: @route_id

  defp source(name) do
    @source_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  @doc "The route path of the loop route, as `Gobusgo.OneBusAway.RoutePaths.parse/2` returns it."
  @spec route_path() :: map()
  def route_path do
    {:ok, route_path} = RoutePaths.parse(source("stops_for_route_loop")["data"], @route_id)
    route_path
  end

  @doc "The loop route's schedule, as `Gobusgo.OneBusAway.RouteSchedules.parse/2` returns it."
  @spec parsed_schedule() :: map()
  def parsed_schedule do
    {:ok, schedule} = RouteSchedules.parse(source("schedule_for_route_loop")["data"], @route_id)
    schedule
  end

  @doc "The loop route's schedule, packed as the schedule view holds it."
  @spec schedule() :: CompactSchedule.t()
  def schedule do
    {:ok, compact} = parsed_schedule() |> CompactSchedule.list() |> CompactSchedule.pack()
    compact
  end

  @doc "The input `Gobusgo.Routing.TripPathShard.build/1` builds the shard from."
  @spec input() :: map()
  def input do
    route_path = route_path()
    schedule = schedule()

    group_polylines =
      for grouping <- route_path.stop_groupings,
          group <- grouping.stop_groups,
          polyline <- group.polylines,
          do: polyline.points

    %{
      polylines: Enum.map(route_path.polylines, & &1.points) ++ group_polylines,
      stop_positions: Map.new(route_path.stops, &{&1.id, {&1.lat, &1.lon}}),
      trips:
        for trip <- schedule.trips do
          %{id: trip.id, stop_times: CompactSchedule.stop_times(schedule, trip)}
        end
    }
  end

  @doc "The expanded bytes of the shard."
  @spec shard_content() :: binary()
  def shard_content do
    {:ok, %{content: content}} = TripPathShard.build(input())
    content
  end

  @doc "The shards of the index, written by hand."
  @spec index_shards() :: [TripPathIndex.shard()]
  def index_shards, do: @index_shards

  @doc "The expanded bytes of the index."
  @spec index_content() :: binary()
  def index_content, do: TripPathIndex.build(@index_shards)

  @doc "What a reader decodes from the fixtures, as `expected.json` holds it."
  @spec expected() :: map()
  def expected do
    {:ok, trips} = TripPathShard.decode(shard_content())
    {:ok, built} = TripPathShard.build(input())

    %{
      "shard" => %{
        "tripCount" => built.trip_count,
        "patternCount" => built.pattern_count,
        "geometryCount" => built.geometry_count,
        "trips" => Enum.map(trips, &expected_trip/1)
      },
      "index" => %{
        "records" =>
          for shard <- Enum.sort_by(@index_shards, & &1.route_id) do
            %{
              "routeId" => shard.route_id,
              "path" => shard.path,
              "byteSize" => shard.byte_size,
              "sha256" => shard.sha256
            }
          end
      }
    }
  end

  defp expected_trip(trip) do
    {first_latitude, first_longitude} = hd(trip.points)
    {last_latitude, last_longitude} = List.last(trip.points)

    %{
      "id" => trip.id,
      "pointCount" => length(trip.points),
      "firstPointMicrodegrees" => [first_latitude, first_longitude],
      "lastPointMicrodegrees" => [last_latitude, last_longitude],
      "stopDistancesM" => Enum.map(trip.stops, & &1.distance_m),
      "arrivalS" => Enum.map(trip.stops, & &1.arrival_s),
      "departureS" => Enum.map(trip.stops, & &1.departure_s)
    }
  end
end
