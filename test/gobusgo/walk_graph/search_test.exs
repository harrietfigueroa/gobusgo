defmodule Gobusgo.WalkGraph.SearchTest do
  # Checks the walk graph search against the browser's answers: the golden
  # file holds what the core's path search gives for 153 pairs of points over
  # the walk graph fixture's shards, and each answer must agree within
  # @tolerance_meters, through the tiles this module selects for itself. The
  # rest are cases built here: a shard order that must not matter, the bounds,
  # and the inputs a function refuses.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Search

  @golden_path Path.expand("../../fixtures/walk_links/v1/expected.json", __DIR__)
  @shard_directory Path.expand("../../fixtures/walk_graph/v1", __DIR__)
  @tolerance_meters 0.1
  @street_class 4
  @units 100_000
  @lat 4_760_000
  @lon -12_234_000

  @golden @golden_path |> File.read!() |> JSON.decode!()

  defp limits do
    %{
      distance_meters_max: @golden["limits"]["distanceMetersMax"],
      margin_meters: @golden["limits"]["marginMeters"],
      snap_meters_max: @golden["limits"]["snapMetersMax"],
      tile_count_max: @golden["limits"]["tileCountMax"],
      edge_count_max: @golden["limits"]["edgeCountMax"],
      visited_node_count_max: @golden["limits"]["visitedNodeCountMax"],
      street_meters_max: 600,
      target_count_max: 64
    }
  end

  defp shard!(name) do
    {:ok, shard} = @shard_directory |> Path.join(name) |> File.read!() |> Format.decode_shard()
    shard
  end

  defp shards_by_tile do
    %{{4761, -8156} => shard!("shard-west.bin"), {4761, -8155} => shard!("shard-east.bin")}
  end

  defp tile_of_key(key) do
    [row, column] = String.split(key, "_")
    {String.to_integer(row), String.to_integer(column)}
  end

  defp index, do: MapSet.new(@golden["indexTileKeys"], &tile_of_key/1)

  defp position(%{"lat" => lat, "lon" => lon}), do: %{lat: lat, lon: lon}

  defp held_shards(tiles) do
    for tile <- tiles, shard = Map.get(shards_by_tile(), tile), do: shard
  end

  defp tiles_of(query), do: Enum.map(query["tiles"], fn [row, column] -> {row, column} end)

  defp line(lat, lon_from, lon_to) do
    %{class: @street_class, points: [{lat, lon_from}, {lat, lon_to}]}
  end

  defp degrees(units), do: units / @units

  describe "tiles_needed/1" do
    test "reads the tiles the browser reads for every golden pair" do
      mismatches =
        for query <- @golden["queries"],
            answer = tiles_answer(query),
            answer != expected_tiles(query),
            do: {query["name"], answer}

      assert mismatches == []
    end
  end

  defp tiles_answer(query) do
    Search.tiles_needed(%{
      from: position(query["from"]),
      to: position(query["to"]),
      index: index(),
      limits: limits()
    })
  end

  defp expected_tiles(%{"kind" => "tooFar"}), do: :too_far
  defp expected_tiles(query), do: {:tiles, tiles_of(query)}

  describe "find_path/1" do
    test "agrees with the browser within a tenth of a meter on every golden pair" do
      mismatches =
        for query <- @golden["queries"],
            query["kind"] != "tooFar",
            answer = golden_answer(query),
            not agrees?(answer, query),
            do: {query["name"], answer, query["meters"] || query["reason"]}

      assert mismatches == []
    end

    test "answers each kind of outcome the golden file holds" do
      kinds =
        for query <- @golden["queries"], query["kind"] != "tooFar", into: MapSet.new() do
          golden_answer(query) |> elem(0)
        end

      assert MapSet.member?(kinds, :found)
      assert MapSet.member?(kinds, :no_path)
    end

    test "chooses the same answer whichever order the shards come in" do
      above = %{pieces: [line(@lat + 18, @lon - 400, @lon + 400)]}
      below = %{pieces: [line(@lat - 18, @lon - 400, @lon + 400)]}

      request = %{
        from: %{lat: degrees(@lat), lon: degrees(@lon - 200)},
        to: %{lat: degrees(@lat), lon: degrees(@lon + 200)},
        limits: limits()
      }

      forward = Search.find_path(Map.put(request, :shards, [above, below]))
      backward = Search.find_path(Map.put(request, :shards, [below, above]))

      assert {:found, _meters} = forward
      assert forward == backward
    end

    test "says there is no shard when none is given" do
      assert {:no_path, :no_shards} =
               Search.find_path(%{
                 from: %{lat: 47.6, lon: -122.3},
                 to: %{lat: 47.601, lon: -122.3},
                 shards: [],
                 limits: limits()
               })
    end

    test "stops at the settled node bound" do
      assert {:no_path, :cap_reached} =
               Search.find_path(%{
                 from: %{lat: degrees(@lat), lon: degrees(@lon - 380)},
                 to: %{lat: degrees(@lat), lon: degrees(@lon + 380)},
                 shards: [%{pieces: grid_pieces()}],
                 limits: %{limits() | visited_node_count_max: 1}
               })
    end

    test "stops at the piece bound" do
      assert {:no_path, :cap_reached} =
               Search.find_path(%{
                 from: %{lat: degrees(@lat), lon: degrees(@lon)},
                 to: %{lat: degrees(@lat), lon: degrees(@lon + 100)},
                 shards: [%{pieces: grid_pieces()}],
                 limits: %{limits() | edge_count_max: 1}
               })
    end

    test "refuses a position off the globe" do
      assert_raise AssertionError, fn ->
        Search.find_path(%{
          from: %{lat: 91.0, lon: 0.0},
          to: %{lat: 0.0, lon: 0.0},
          shards: [],
          limits: limits()
        })
      end
    end
  end

  describe "reach/1" do
    test "agrees with the browser within a tenth of a meter on every golden pair, one target at a time" do
      mismatches =
        for query <- @golden["queries"],
            query["kind"] != "tooFar",
            answer = reach_one(query),
            not reach_agrees?(answer, query),
            do: {query["name"], answer, query["meters"] || query["reason"]}

      assert mismatches == []
    end

    test "answers many targets of one start in one search, each as it would alone" do
      shards = Map.values(shards_by_tile())
      from = %{lat: degrees(4_761_450), lon: degrees(-12_233_600)}

      targets = [
        %{lat: degrees(4_761_450), lon: degrees(-12_233_400)},
        %{lat: degrees(4_761_300), lon: degrees(-12_233_600)},
        %{lat: degrees(4_761_800), lon: degrees(-12_233_600)},
        %{lat: degrees(4_761_600), lon: degrees(-12_233_400)}
      ]

      many = Search.reach(%{from: from, targets: targets, shards: shards, limits: limits()})

      alone =
        for target <- targets do
          [answer] =
            Search.reach(%{from: from, targets: [target], shards: shards, limits: limits()})

          answer
        end

      assert many == alone

      assert [
               {:found, _near},
               {:found, _detour},
               {:no_path, :disconnected},
               {:no_path, :off_graph}
             ] = many
    end

    test "leaves a connected target past the street bound as beyond the bound" do
      far = %{lat: degrees(4_761_300), lon: degrees(-12_231_800)}
      from = %{lat: degrees(4_761_300), lon: degrees(-12_233_600)}
      shards = Map.values(shards_by_tile())

      assert [{:no_path, :beyond_bound}] =
               Search.reach(%{from: from, targets: [far], shards: shards, limits: limits()})
    end

    test "answers off the graph for every target when the start is off it" do
      from = %{lat: degrees(4_761_600), lon: degrees(-12_233_400)}
      target = %{lat: degrees(4_761_450), lon: degrees(-12_233_400)}
      shards = Map.values(shards_by_tile())

      assert [{:no_path, :off_graph}] =
               Search.reach(%{from: from, targets: [target], shards: shards, limits: limits()})
    end

    test "reports a search that ran out of settled nodes as capped" do
      from = %{lat: degrees(@lat), lon: degrees(@lon - 380)}
      target = %{lat: degrees(@lat), lon: degrees(@lon + 380)}

      assert [{:no_path, :cap_reached}] =
               Search.reach(%{
                 from: from,
                 targets: [target],
                 shards: [%{pieces: grid_pieces()}],
                 limits: %{limits() | visited_node_count_max: 1}
               })
    end

    test "refuses more targets than the bound" do
      from = %{lat: 47.6, lon: -122.3}
      targets = List.duplicate(from, limits().target_count_max + 1)

      assert_raise AssertionError, fn ->
        Search.reach(%{from: from, targets: targets, shards: [], limits: limits()})
      end
    end

    test "chooses the same answer whichever order the shards come in" do
      above = %{pieces: [line(@lat + 18, @lon - 400, @lon + 400)]}
      below = %{pieces: [line(@lat - 18, @lon - 400, @lon + 400)]}
      from = %{lat: degrees(@lat), lon: degrees(@lon - 200)}
      target = %{lat: degrees(@lat), lon: degrees(@lon + 200)}
      request = %{from: from, targets: [target], limits: limits()}

      forward = Search.reach(Map.put(request, :shards, [above, below]))
      backward = Search.reach(Map.put(request, :shards, [below, above]))

      assert [{:found, _meters}] = forward
      assert forward == backward
    end
  end

  # A grid of streets a few hundred units on a side, so a search settles
  # more than one node.
  defp grid_pieces do
    for row <- 0..2, column <- 0..2, piece <- grid_cell(row, column), do: piece
  end

  defp grid_cell(row, column) do
    lat = @lat + row * 100
    lon = @lon - 400 + column * 400

    [line(lat, lon, lon + 400), %{class: @street_class, points: [{lat, lon}, {lat + 100, lon}]}]
  end

  defp golden_answer(query) do
    from = position(query["from"])
    to = position(query["to"])

    Search.find_path(%{
      from: from,
      to: to,
      shards: held_shards(tiles_of(query)),
      limits: limits()
    })
  end

  defp reach_one(query) do
    [answer] =
      Search.reach(%{
        from: position(query["from"]),
        targets: [position(query["to"])],
        shards: held_shards(tiles_of(query)),
        limits: limits()
      })

    answer
  end

  defp agrees?({:found, meters}, %{"kind" => "found", "meters" => expected}) do
    abs(meters - expected) <= @tolerance_meters
  end

  defp agrees?({:no_path, reason}, %{"kind" => "noPath", "reason" => expected}) do
    Atom.to_string(reason) == Macro.underscore(expected)
  end

  defp agrees?(_answer, _query), do: false

  defp reach_agrees?({:no_path, :beyond_bound}, %{"kind" => "found", "meters" => meters}) do
    meters > limits().street_meters_max
  end

  defp reach_agrees?({:found, meters} = answer, %{"kind" => "found", "meters" => expected}) do
    expected <= limits().street_meters_max and
      agrees?(answer, %{"kind" => "found", "meters" => expected}) and
      meters > 0
  end

  defp reach_agrees?(answer, query), do: agrees?(answer, query)
end
