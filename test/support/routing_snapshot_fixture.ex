defmodule Gobusgo.Test.RoutingSnapshotFixture do
  @moduledoc """
  The records of the shared routing snapshot fixtures under
  `test/fixtures/routing/v2/`: one file of each kind, and `expected.json`,
  the records as the JavaScript reader returns them. They cover a stop
  identifier outside ASCII, a trip of the previous service date, a time past
  midnight, every pair of the two flags, a stop with no position, and
  positions at the extremes of each sign.
  """

  @directory Path.expand("../fixtures/routing/v2", __DIR__)

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The records of each fixture file, by kind."
  @spec records() :: %{atom() => list()}
  def records do
    %{
      stops: ["1_100", "1_200", "29_Café 3"],
      trips: [
        %{id: "1_trip-a", route_id: "1_100479", service_day_offset: 0},
        %{id: "1_trip-a", route_id: "1_100479", service_day_offset: 1}
      ],
      transfers: [
        %{from_stop: 0, to_stop: 2, duration_s: 95},
        %{from_stop: 2, to_stop: 0, duration_s: 95}
      ],
      positions: [
        %{lat_microdegrees: 47_608_013, lon_microdegrees: -122_335_167},
        :unknown,
        %{lat_microdegrees: -90_000_000, lon_microdegrees: 180_000_000}
      ],
      connections: [
        connection(%{
          departure_s: 600,
          arrival_s: 840,
          from: 1,
          to: 0,
          trip: 1,
          sequence: 7,
          boarding: true,
          alighting: true
        }),
        connection(%{
          departure_s: 21_600,
          arrival_s: 21_780,
          from: 0,
          to: 1,
          trip: 0,
          sequence: 0,
          boarding: true,
          alighting: false
        }),
        connection(%{
          departure_s: 21_780,
          arrival_s: 21_900,
          from: 1,
          to: 2,
          trip: 0,
          sequence: 1,
          boarding: false,
          alighting: true
        }),
        connection(%{
          departure_s: 90_000,
          arrival_s: 90_060,
          from: 2,
          to: 0,
          trip: 0,
          sequence: 2,
          boarding: false,
          alighting: false
        })
      ]
    }
  end

  defp connection(fields) do
    %{
      departure_s: fields.departure_s,
      arrival_s: fields.arrival_s,
      departure_stop: fields.from,
      arrival_stop: fields.to,
      trip: fields.trip,
      sequence: fields.sequence,
      boarding: fields.boarding,
      alighting: fields.alighting
    }
  end

  @doc "The records as `expected.json` holds them, with the reader's field names."
  @spec expected() :: map()
  def expected do
    %{
      stops: stops,
      trips: trips,
      transfers: transfers,
      positions: positions,
      connections: connections
    } = records()

    %{
      "stops" => stops,
      "trips" =>
        for(
          trip <- trips,
          do: %{
            "id" => trip.id,
            "routeId" => trip.route_id,
            "serviceDayOffset" => trip.service_day_offset
          }
        ),
      "transfers" =>
        for(
          link <- transfers,
          do: %{
            "fromStop" => link.from_stop,
            "toStop" => link.to_stop,
            "durationS" => link.duration_s
          }
        ),
      "positions" => Enum.map(positions, &expected_position/1),
      "connections" =>
        for connection <- connections do
          %{
            "departureS" => connection.departure_s,
            "arrivalS" => connection.arrival_s,
            "departureStop" => connection.departure_stop,
            "arrivalStop" => connection.arrival_stop,
            "trip" => connection.trip,
            "sequence" => connection.sequence,
            "boarding" => connection.boarding,
            "alighting" => connection.alighting
          }
        end
    }
  end

  # The JavaScript reader gives a stop with no position the `i32` minimum on
  # both axes, the value the file holds for it.
  defp expected_position(:unknown) do
    %{"latMicrodegrees" => -2_147_483_648, "lonMicrodegrees" => -2_147_483_648}
  end

  defp expected_position(position) do
    %{
      "latMicrodegrees" => position.lat_microdegrees,
      "lonMicrodegrees" => position.lon_microdegrees
    }
  end
end
