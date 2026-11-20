defmodule Gobusgo.WalkGraph.SearchTest do
  # Checks the walk graph search against the browser's answers: the golden
  # file holds what the core's path search gives for pairs of points over the
  # walk graph fixture's shards and two shards of its own, and each answer
  # must agree within @tolerance_meters, through the tiles this module
  # selects for itself. The rest are cases built here: a shard order that
  # must not matter, the bounds, and the inputs a function refuses.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Graph
  alias Gobusgo.WalkGraph.Search

  @golden_path Path.expand("../../fixtures/walk_links/v1/expected.json", __DIR__)
  @shard_directory Path.expand("../../fixtures/walk_graph/v1", __DIR__)
  @tolerance_meters 0.1
  @street_class 4
  @units 100_000
  @lat 4_760_000
  @lon -12_234_000
  @tie_offset_units 18
  @tie_bump_units 100
  @tie_expected_meters 339.9466612406429
  @street_meters_unbounded 10_000

  @golden @golden_path |> File.read!() |> JSON.decode!()

  defp limits do
    %{
      distance_meters_max: @golden["limits"]["distanceMetersMax"],
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
    fixture = %{
      {4761, -8156} => shard!("shard-west.bin"),
      {4761, -8155} => shard!("shard-east.bin")
    }

    extra =
      Map.new(@golden["extraShards"], fn %{"tile" => [row, column], "pieces" => pieces} ->
        {{row, column}, %{pieces: Enum.map(pieces, &extra_piece/1)}}
      end)

    Map.merge(fixture, extra)
  end

  defp extra_piece(%{"class" => class, "points" => points}) do
    %{class: class, points: Enum.map(points, fn [lat, lon] -> {lat, lon} end)}
  end

  defp tile_of_key(key) do
    [row, column] = String.split(key, "_")
    {String.to_integer(row), String.to_integer(column)}
  end

  defp index, do: MapSet.new(@golden["indexTileKeys"], &tile_of_key/1)

  defp position(%{"lat" => lat, "lon" => lon}), do: %{lat: lat, lon: lon}

  defp held_shards(tiles) do
    held = shards_by_tile()
    tiles |> Enum.filter(&Map.has_key?(held, &1)) |> Enum.map(&Map.fetch!(held, &1))
  end

  defp tiles_of(query), do: Enum.map(query["tiles"], fn [row, column] -> {row, column} end)

  defp line(lat, lon_from, lon_to) do
    %{class: @street_class, points: [{lat, lon_from}, {lat, lon_to}]}
  end

  defp degrees(units), do: units / @units

  # The queries whose answer, by `answer_of`, `agrees?` does not accept.
  defp mismatches(queries, answer_of, agrees?) do
    queries
    |> Enum.map(fn query -> {query, answer_of.(query)} end)
    |> Enum.reject(fn {query, answer} -> agrees?.(answer, query) end)
    |> Enum.map(fn {query, answer} -> {query["name"], answer} end)
  end

  defp answered_queries, do: Enum.filter(@golden["queries"], &(&1["kind"] != "tooFar"))

  describe "limits/0" do
    test "holds the bounds the browser's search uses" do
      expected = %{
        distance_meters_max: @golden["limits"]["distanceMetersMax"],
        snap_meters_max: @golden["limits"]["snapMetersMax"],
        tile_count_max: @golden["limits"]["tileCountMax"],
        edge_count_max: @golden["limits"]["edgeCountMax"],
        visited_node_count_max: @golden["limits"]["visitedNodeCountMax"]
      }

      assert Map.take(Search.limits(), Map.keys(expected)) == expected
    end
  end

  describe "tiles_needed/1" do
    test "reads the tiles the browser reads for every golden pair" do
      assert mismatches(@golden["queries"], &tiles_answer/1, &tiles_agree?/2) == []
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

  defp tiles_agree?(answer, %{"kind" => "tooFar", "tiles" => []}), do: answer == :too_far
  defp tiles_agree?(answer, query), do: answer == {:tiles, tiles_of(query)}

  describe "plan/1" do
    test "agrees with the browser within a tenth of a meter on every golden pair" do
      assert mismatches(@golden["queries"], &golden_answer/1, &agrees?/2) == []
    end

    test "answers each kind of outcome the golden file holds" do
      kinds = MapSet.new(@golden["queries"], fn query -> query |> golden_answer() |> elem(0) end)

      assert MapSet.member?(kinds, :found)
      assert MapSet.member?(kinds, :no_path)
    end

    test "names the tiles it lacks before it answers" do
      query = hd(@golden["queries"])

      assert {:not_loaded, [_first | _rest] = tiles} =
               Search.plan(%{
                 from: position(query["from"]),
                 to: position(query["to"]),
                 index: index(),
                 held: %{},
                 limits: limits()
               })

      assert tiles == tiles_of(query)
    end

    test "checks the distance between the ends once the tiles are held" do
      query = Enum.find(@golden["queries"], &(&1["kind"] == "tooFar" and &1["tiles"] != []))

      assert {:no_path, :too_far} =
               Search.plan(%{
                 from: position(query["from"]),
                 to: position(query["to"]),
                 index: index(),
                 held: shards_by_tile(),
                 limits: limits()
               })

      assert {:not_loaded, _tiles} =
               Search.plan(%{
                 from: position(query["from"]),
                 to: position(query["to"]),
                 index: index(),
                 held: %{},
                 limits: limits()
               })
    end
  end

  # Two components 20 m north and south of a pair of ends. The northern has
  # a bump between the ends, so the answer says which a tie chose; the
  # southern is the lesser y, which the tie goes to.
  defp tie_shards do
    bump = %{
      class: @street_class,
      points: [
        {@lat + @tie_offset_units, @lon - 400},
        {@lat + @tie_offset_units, @lon - 200},
        {@lat + @tie_offset_units + @tie_bump_units, @lon - 200},
        {@lat + @tie_offset_units + @tie_bump_units, @lon + 200},
        {@lat + @tie_offset_units, @lon + 200},
        {@lat + @tie_offset_units, @lon + 400}
      ]
    }

    {%{pieces: [bump]}, %{pieces: [line(@lat - @tie_offset_units, @lon - 400, @lon + 400)]}}
  end

  defp tie_ends do
    %{
      from: %{lat: degrees(@lat), lon: degrees(@lon - 200)},
      to: %{lat: degrees(@lat), lon: degrees(@lon + 200)}
    }
  end

  describe "snapping" do
    test "chooses the southern component of a tie in either order of the shards" do
      {above, below} = tie_shards()
      %{from: from, to: to} = tie_ends()
      plane = Graph.plane(from, to)
      {_from_x, ends_y} = Graph.to_plane(plane, from)

      for shards <- [[above, below], [below, above]] do
        graph = shards |> Enum.flat_map(& &1.pieces) |> Graph.build(plane)
        start_snaps = Graph.snaps(graph, Graph.to_plane(plane, from), 100)
        goal_snaps = Graph.snaps(graph, Graph.to_plane(plane, to), 100)

        assert map_size(start_snaps) == 2
        assert {:chosen, start, goal} = Graph.choose(start_snaps, goal_snaps)
        assert start.y < ends_y
        assert goal.y < ends_y
      end
    end

    test "chooses between two streets that cross at the point by their lesser ends" do
      crossing = %{lat: degrees(@lat), lon: degrees(@lon)}
      plane = Graph.plane(crossing, crossing)
      across = line(@lat, @lon - 100, @lon + 100)
      along = %{class: @street_class, points: [{@lat - 100, @lon}, {@lat + 100, @lon}]}

      for pieces <- [[across, along], [along, across]] do
        graph = Graph.build(pieces, plane)
        snaps = Graph.snaps(graph, Graph.to_plane(plane, crossing), 100)

        assert map_size(snaps) == 2
        assert {:chosen, start, _goal} = Graph.choose(snaps, snaps)
        assert start.ends == {{@lat - 100, @lon}, {@lat + 100, @lon}}
      end
    end

    test "finds only the segments within the bound of a point" do
      graph = Graph.build(grid_pieces(), Graph.plane(tie_ends().from, tie_ends().from))
      plane = Graph.plane(tie_ends().from, tie_ends().from)
      near = Graph.snaps(graph, Graph.to_plane(plane, tie_ends().from), 100)
      far = Graph.snaps(graph, {50_000.0, 50_000.0}, 100)

      assert map_size(near) == 1
      assert far == %{}
    end
  end

  describe "find_path/1" do
    test "walks the southern street of a tie in either order of the shards" do
      {above, below} = tie_shards()
      %{from: from, to: to} = tie_ends()
      request = %{from: from, to: to, limits: limits()}

      forward = Search.find_path(Map.put(request, :shards, [above, below]))
      backward = Search.find_path(Map.put(request, :shards, [below, above]))
      southern = Search.find_path(Map.put(request, :shards, [below]))

      assert {:found, meters} = forward
      assert abs(meters - @tie_expected_meters) < @tolerance_meters
      assert forward == backward
      assert forward == southern
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

  describe "prepare/1 and reach_prepared/1" do
    test "answer as reach/1 does for a start at the reference, over one graph for many starts" do
      shards = Map.values(shards_by_tile())
      reference = %{lat: degrees(4_761_450), lon: degrees(-12_233_600)}
      targets = [%{lat: degrees(4_761_450), lon: degrees(-12_233_400)}]

      assert {:ok, prepared} =
               Search.prepare(%{reference: reference, shards: shards, limits: limits()})

      prepared_answers =
        Search.reach_prepared(%{
          prepared: prepared,
          from: reference,
          targets: targets,
          limits: limits()
        })

      assert prepared_answers ==
               Search.reach(%{
                 from: reference,
                 targets: targets,
                 shards: shards,
                 limits: limits()
               })

      other = %{lat: degrees(4_761_300), lon: degrees(-12_233_600)}

      assert [{:found, meters}] =
               Search.reach_prepared(%{
                 prepared: prepared,
                 from: other,
                 targets: [reference],
                 limits: limits()
               })

      assert meters > 0
    end

    test "say there is no shard, and refuse more pieces than the bound" do
      reference = %{lat: degrees(4_761_450), lon: degrees(-12_233_600)}

      assert {:no_path, :no_shards} =
               Search.prepare(%{reference: reference, shards: [], limits: limits()})

      assert {:no_path, :cap_reached} =
               Search.prepare(%{
                 reference: reference,
                 shards: Map.values(shards_by_tile()),
                 limits: %{limits() | edge_count_max: 1}
               })
    end
  end

  describe "reach/1" do
    test "agrees with the browser within a tenth of a meter on every golden pair, one target at a time" do
      assert mismatches(answered_queries(), &reach_one/1, &reach_agrees?/2) == []
    end

    test "agrees over the tiles around the start alone, as the browser's walks are planned" do
      assert mismatches(answered_queries(), &reach_start_window/1, &reach_agrees?/2) == []
    end

    test "misses a join that lies outside the tiles around the start" do
      # Two streets that meet only through a loop that is outside the shards
      # the start's window holds.
      north = line(100, 100, 1_400)
      south = line(200, 100, 1_400)

      loop = %{
        class: @street_class,
        points: [{100, 1_400}, {100, 3_100}, {200, 3_100}, {200, 1_400}]
      }

      from = %{lat: degrees(100), lon: degrees(100)}
      target = %{lat: degrees(200), lon: degrees(100)}
      wide = %{limits() | street_meters_max: @street_meters_unbounded}

      request = %{from: from, targets: [target], limits: wide}
      window = Search.reach(Map.put(request, :shards, [%{pieces: [north, south]}]))
      whole = Search.reach(Map.put(request, :shards, [%{pieces: [north, south, loop]}]))

      planned =
        Search.find_path(%{
          from: from,
          to: target,
          shards: [%{pieces: [north, south, loop]}],
          limits: wide
        })

      assert window == [{:no_path, :disconnected}]
      assert [{:found, meters}] = whole
      assert {:found, planned_meters} = planned
      assert abs(meters - planned_meters) < @tolerance_meters
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

    test "answers exactly the targets a capped search settled past, and caps the rest" do
      from = %{lat: degrees(@lat), lon: degrees(@lon - 400)}
      near = %{lat: degrees(@lat), lon: degrees(@lon - 350)}
      far = %{lat: degrees(@lat + 100), lon: degrees(@lon)}
      pieces = [%{pieces: grid_pieces()}]
      request = %{from: from, targets: [near, far], shards: pieces}

      uncapped = Search.reach(Map.put(request, :limits, limits()))
      capped = Search.reach(Map.put(request, :limits, %{limits() | visited_node_count_max: 1}))

      assert [{:found, _near}, {:found, _far}] = uncapped
      assert capped == [hd(uncapped), {:no_path, :cap_reached}]
    end

    test "refuses more targets than the bound" do
      from = %{lat: 47.6, lon: -122.3}
      targets = List.duplicate(from, limits().target_count_max + 1)

      assert_raise AssertionError, fn ->
        Search.reach(%{from: from, targets: targets, shards: [], limits: limits()})
      end
    end

    test "walks the southern street of a tie in either order of the shards" do
      {above, below} = tie_shards()
      %{from: from, to: to} = tie_ends()
      request = %{from: from, targets: [to], limits: limits()}

      forward = Search.reach(Map.put(request, :shards, [above, below]))
      backward = Search.reach(Map.put(request, :shards, [below, above]))

      assert [{:found, meters}] = forward
      assert abs(meters - @tie_expected_meters) < @tolerance_meters
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
    Search.plan(%{
      from: position(query["from"]),
      to: position(query["to"]),
      index: index(),
      held: shards_by_tile(),
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

  # The browser plans a walk from a position over the tiles around it alone.
  defp reach_start_window(query) do
    from = position(query["from"])

    {:tiles, tiles} =
      Search.tiles_needed(%{from: from, to: from, index: index(), limits: limits()})

    [answer] =
      Search.reach(%{
        from: from,
        targets: [position(query["to"])],
        shards: held_shards(tiles),
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

  defp agrees?({:no_path, :too_far}, %{"kind" => "tooFar"}), do: true

  defp agrees?(_answer, _query), do: false

  defp reach_agrees?({:no_path, :beyond_bound}, %{"kind" => "found", "meters" => meters}) do
    meters > limits().street_meters_max
  end

  defp reach_agrees?({:found, _meters} = answer, %{"kind" => "found", "meters" => expected}) do
    expected <= limits().street_meters_max and
      agrees?(answer, %{"kind" => "found", "meters" => expected})
  end

  defp reach_agrees?(answer, query), do: agrees?(answer, query)
end
