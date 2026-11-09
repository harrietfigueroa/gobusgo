defmodule Gobusgo.Test.RoutingNamesFixture do
  @moduledoc """
  The input of the shared routing names fixture under
  `test/fixtures/routing/names-v1/`: `names.json.gz`, the names file built
  from it, and `expected.json`, the names as the JavaScript reader returns
  them. They cover a name outside ASCII, a stop the stop view does not hold,
  a stop with no code, two runs of one trip with their own headsigns, a trip
  with no headsign, a route with no short name and no color, a route no trip
  names, and an agency the agency view does not hold.
  """

  alias Gobusgo.Routing.Names

  @directory Path.expand("../fixtures/routing/names-v1", __DIR__)

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The input `Gobusgo.Routing.Names.build/1` builds the fixture from."
  @spec input() :: map()
  def input do
    %{
      stop_ids: ["1_100", "1_200", "29_Café 3"],
      trips: [
        %{id: "1_trip-a", route_id: "1_100479", service_day_offset: 0},
        %{id: "29_trip-b", route_id: "29_7", service_day_offset: 0},
        %{id: "1_trip-a", route_id: "1_100479", service_day_offset: 1}
      ],
      headsigns: %{
        {0, "1_trip-a"} => "Downtown Seattle",
        {1, "1_trip-a"} => "Othello Station",
        {0, "29_trip-b"} => nil
      },
      stops: %{
        "1_100" => %{name: "3rd Ave & Pike St", code: "1100"},
        "29_Café 3" => %{name: "Café Ünïcode Transit Center", code: nil}
      },
      routes: %{
        "1_100479" => %{
          short_name: "36",
          long_name: "Beacon Hill",
          color: "0070C0",
          agency_id: "1"
        },
        "29_7" => %{short_name: nil, long_name: "Everett Station", color: nil, agency_id: "29"},
        "1_999" => %{short_name: "999", long_name: nil, color: nil, agency_id: "1"}
      },
      agency_names: %{"1" => "Metro Transit", "40" => "Sound Transit"}
    }
  end

  @doc "The number of stops and trips of the snapshot the fixture names."
  @spec counts() :: %{stop_count: pos_integer(), trip_count: pos_integer()}
  def counts do
    %{stop_ids: stop_ids, trips: trips} = input()
    %{stop_count: length(stop_ids), trip_count: length(trips)}
  end

  @doc "The names as `expected.json` holds them, the JavaScript reader's result."
  @spec expected() :: map()
  def expected do
    %{
      "stopNames" => ["3rd Ave & Pike St", nil, "Café Ünïcode Transit Center"],
      "stopCodes" => ["1100", nil, nil],
      "tripHeadsigns" => ["Downtown Seattle", nil, "Othello Station"],
      "routes" => %{
        "1_100479" => %{
          "shortName" => "36",
          "longName" => "Beacon Hill",
          "color" => "0070C0",
          "agencyId" => "1"
        },
        "29_7" => %{
          "shortName" => nil,
          "longName" => "Everett Station",
          "color" => nil,
          "agencyId" => "29"
        }
      },
      "agencyNames" => %{"1" => "Metro Transit"}
    }
  end

  @doc "The names file's content, the names `Gobusgo.Routing.Names.build/1` builds from `input/0`."
  @spec content() :: binary()
  def content, do: input() |> Names.build() |> Names.encode()
end
