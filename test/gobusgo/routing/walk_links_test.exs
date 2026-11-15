defmodule Gobusgo.Routing.WalkLinksTest do
  # Checks the walking links measured along the walk graph over the shards of
  # the walk graph fixture: the street a pair of stops takes, the pairs that
  # have none, which stops a table measures again, and how a snapshot takes
  # a stop's links from a table. The shards are read by a function the test
  # holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.Routing.WalkLinks
  alias Gobusgo.Test.WalkGraphFixture

  @build_id "0123456789abcdef"
  @units 100_000
  @north 4_761_450
  @south 4_761_300
  @west -12_233_600
  @middle -12_233_400
  @tolerance_meters 0.1
  @far_future_ms 4_000_000_000_000
  @crowd_stop_count 1_100
  @crowd_heap_words_max 100_000_000
  @tile_start_timeout_ms 30_000
  @tile_end_timeout_ms 1_000

  @west_tile {4761, -8156}
  @east_tile {4761, -8155}

  defp shards do
    %{
      @west_tile => WalkGraphFixture.encode_shard(:west),
      @east_tile => WalkGraphFixture.encode_shard(:east)
    }
  end

  defp index, do: MapSet.new([@west_tile, @east_tile])

  defp place(lat_units, lon_units), do: %{lat: lat_units / @units, lon: lon_units / @units}

  defp positions do
    %{
      "a" => place(@north, @west),
      "b" => place(@north, @middle),
      "c" => place(@south, @west),
      "d" => place(@south, @middle),
      "island" => place(4_761_800, @west),
      "off" => place(4_761_600, @middle)
    }
  end

  defp load_from(held), do: fn tile -> load(held, tile) end

  defp load(held, tile) do
    case Map.fetch(held, tile) do
      {:ok, shard} -> {:ok, shard}
      :error -> {:error, {:io, :not_found}}
    end
  end

  defp compute(overrides \\ %{}) do
    input =
      Map.merge(
        %{
          positions: positions(),
          stop_ids: positions() |> Map.keys() |> Enum.sort(),
          previous: nil,
          build_id: @build_id,
          index: index(),
          load_shard: load_from(shards()),
          deadline_ms: @far_future_ms
        },
        overrides
      )

    WalkLinks.compute(input)
  end

  defp links_of(table, stop_id), do: Map.fetch!(table.stops, stop_id).links

  # Runs a measuring that has the tile's process of `crowd`, many stops close
  # enough to keep it busy, once the test has set its tracing.
  defp measure_when_told(crowd) do
    receive do
      :go ->
        compute(%{
          positions: crowd,
          stop_ids: Map.keys(crowd),
          child_heap_words_max: @crowd_heap_words_max
        })
    end
  end

  # The tile's process is the one the measuring spawns from its own function.
  defp await_tile_process do
    assert_receive {:trace, _parent, :spawn, spawned, {:erlang, :apply, [spawned_fun, []]}},
                   @tile_start_timeout_ms

    {:name, name} = Function.info(spawned_fun, :name)

    if String.contains?(Atom.to_string(name), "measure_in_process") do
      spawned
    else
      await_tile_process()
    end
  end

  describe "compute/1" do
    test "measures a pair on one street as the street's length" do
      {:ok, %{table: table}} = compute()
      {"b", meters} = Enum.find(links_of(table, "a"), &(elem(&1, 0) == "b"))

      straight = Geodesy.distance_meters(positions()["a"], positions()["b"])
      assert abs(meters - straight) < @tolerance_meters
    end

    test "measures a pair whose street goes round a missing link as longer than the straight line" do
      {:ok, %{table: table}} = compute()
      {"d", meters} = Enum.find(links_of(table, "b"), &(elem(&1, 0) == "d"))

      straight = Geodesy.distance_meters(positions()["b"], positions()["d"])
      assert meters > 2 * straight
    end

    test "leaves a disconnected pair without a link" do
      {:ok, %{table: table, stats: stats}} = compute()

      refute "island" in Enum.map(links_of(table, "a"), &elem(&1, 0))
      assert stats.dropped_link_count > 0
    end

    test "keeps the straight line of a pair with an end off the graph" do
      {:ok, %{table: table, stats: stats}} = compute()
      {"off", meters} = Enum.find(links_of(table, "b"), &(elem(&1, 0) == "off"))

      assert abs(meters - Geodesy.distance_meters(positions()["b"], positions()["off"])) <
               @tolerance_meters

      assert stats.straight_link_count > 0
    end

    test "orders a stop's links nearest street first" do
      {:ok, %{table: table}} = compute()
      meters = Enum.map(links_of(table, "a"), &elem(&1, 1))

      assert meters == Enum.sort(meters)
    end

    test "measures again only the stops it is given, and keeps the rest of the table" do
      {:ok, %{table: full}} = compute()

      {:ok, %{table: partial, stats: stats}} =
        compute(%{stop_ids: ["a"], previous: full})

      assert partial == full
      assert stats.measured_stop_count == 1
    end

    test "gives the same table whether it measures every stop at once or after a move" do
      moved = Map.put(positions(), "b", place(@north, @middle + 20))
      {:ok, %{table: before_move}} = compute()

      stale =
        WalkLinks.stale_stop_ids(%{positions: moved, table: before_move, build_id: @build_id})

      {:ok, %{table: incremental}} =
        compute(%{positions: moved, stop_ids: stale, previous: before_move})

      {:ok, %{table: fresh}} =
        compute(%{positions: moved, stop_ids: moved |> Map.keys() |> Enum.sort()})

      assert incremental == fresh
    end

    test "answers a corrupt shard as corrupt, with the tile" do
      held = Map.new(shards(), fn {tile, shard} -> {tile, shard} end)

      load = fn tile ->
        if tile == @east_tile, do: {:error, :corrupt}, else: load(held, tile)
      end

      assert {:error, :corrupt, @east_tile} = compute(%{load_shard: load})
    end

    test "answers a shard that is not a shard as corrupt, with the tile" do
      held = Map.put(shards(), @east_tile, "not a shard")

      assert {:error, :corrupt, @east_tile} = compute(%{load_shard: load_from(held)})
    end

    test "answers a tile's process that outgrew its heap as killed, with the tile" do
      assert {:error, :killed, _tile} = compute(%{child_heap_words_max: 1_000})
    end

    test "ends a tile's process when the process measuring is killed" do
      crowd =
        for number <- 1..@crowd_stop_count, into: %{} do
          {"s#{number}",
           place(@north + rem(number, 30) * 3, @west + Integer.floor_div(number, 30) * 3)}
        end

      measuring = spawn(fn -> measure_when_told(crowd) end)
      1 = :erlang.trace(measuring, true, [:procs, :set_on_spawn])
      send(measuring, :go)

      tile_process = await_tile_process()
      monitor = Process.monitor(tile_process)
      assert Process.alive?(tile_process)

      Process.exit(measuring, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^tile_process, :killed}, @tile_end_timeout_ms
    end

    test "answers a read that failed as an io failure, with the tile" do
      load = fn tile -> {:error, {:io, {:timeout, tile}}} end

      assert {:error, :io, {tile, {:timeout, tile}}} = compute(%{load_shard: load})
    end

    test "answers a computation past its deadline as a deadline" do
      passed_ms = System.monotonic_time(:millisecond) - 1

      assert {:error, :deadline, _tile} = compute(%{deadline_ms: passed_ms})
    end

    test "refuses a stop to measure that has no position" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> compute(%{stop_ids: ["nowhere"]}) end
    end
  end

  describe "stale_stop_ids/1" do
    setup do
      {:ok, %{table: table}} = compute()
      %{table: table}
    end

    test "names every stop for no table, and for a table of another build", %{table: table} do
      every = positions() |> Map.keys() |> Enum.sort()

      assert Enum.sort(
               WalkLinks.stale_stop_ids(%{
                 positions: positions(),
                 table: nil,
                 build_id: @build_id
               })
             ) ==
               every

      assert Enum.sort(
               WalkLinks.stale_stop_ids(%{
                 positions: positions(),
                 table: table,
                 build_id: "fedcba9876543210"
               })
             ) == every
    end

    test "names no stop where nothing changed", %{table: table} do
      assert WalkLinks.stale_stop_ids(%{
               positions: positions(),
               table: table,
               build_id: @build_id
             }) == []
    end

    test "names a moved stop and the stops within the radius of where it was and is", %{
      table: table
    } do
      moved = Map.put(positions(), "island", place(4_761_800, @west + 10))
      stale = WalkLinks.stale_stop_ids(%{positions: moved, table: table, build_id: @build_id})

      assert "island" in stale
      refute "d" in stale
    end

    test "names the stops within the radius of an added stop", %{table: table} do
      added = Map.put(positions(), "new", place(@north, @middle + 40))
      stale = WalkLinks.stale_stop_ids(%{positions: added, table: table, build_id: @build_id})

      assert "new" in stale
      assert "b" in stale
    end

    test "names the stops within the radius of a stop that left", %{table: table} do
      left = Map.delete(positions(), "d")
      stale = WalkLinks.stale_stop_ids(%{positions: left, table: table, build_id: @build_id})

      assert "c" in stale
      refute "d" in stale
    end
  end

  describe "links/1" do
    test "gives a snapshot's stops their links by position in it, as seconds of the street" do
      {:ok, %{table: table}} = compute()
      stop_ids = ["d", "a", "b"]
      links = WalkLinks.links(%{stop_ids: stop_ids, positions: positions(), table: table})

      {"b", meters} = Enum.find(links_of(table, "a"), &(elem(&1, 0) == "b"))
      from_a = Enum.find(links, &(&1.from_stop == 1 and &1.to_stop == 2))

      assert from_a.duration_s == ceil(meters * 1_000 / 1_200)
      assert links == Enum.sort_by(links, &{&1.from_stop, &1.to_stop})
      assert Enum.all?(links, &(&1.to_stop in 0..2))
    end

    test "gives a stop with no position no link" do
      {:ok, %{table: table}} = compute()
      links = WalkLinks.links(%{stop_ids: ["a", "ghost"], positions: positions(), table: table})

      assert Enum.all?(links, &((&1.from_stop == 0 and &1.to_stop == 0) or &1.to_stop != 1))
      refute Enum.any?(links, &(&1.from_stop == 1))
    end

    test "keeps a stop's 64 nearest links" do
      many = for number <- 1..70, into: %{}, do: {"s#{number}", place(@north, @west + number)}
      {:ok, %{table: table}} = compute(%{positions: many, stop_ids: Map.keys(many)})
      links = WalkLinks.links(%{stop_ids: Map.keys(many), positions: many, table: table})

      per_stop = Enum.frequencies_by(links, & &1.from_stop)
      assert per_stop |> Map.values() |> Enum.max() == 64
    end
  end

  describe "mixed_links/1" do
    setup do
      {:ok, %{table: table}} = compute()
      %{table: table}
    end

    test "gives a stop in straight_ids the straight line, and every link to it", %{table: table} do
      stop_ids = ["a", "b", "c"]

      links =
        WalkLinks.mixed_links(%{
          stop_ids: stop_ids,
          positions: positions(),
          table: table,
          straight_ids: MapSet.new(["b"])
        })

      straight_links = Transfers.walking_links(stop_ids, positions())

      assert Enum.filter(links, &(&1.from_stop == 1 or &1.to_stop == 1)) ==
               Enum.filter(straight_links, &(&1.from_stop == 1 or &1.to_stop == 1))
    end

    test "gives the stops outside straight_ids their street links", %{table: table} do
      input = %{stop_ids: ["a", "c", "d"], positions: positions(), table: table}

      assert WalkLinks.mixed_links(Map.put(input, :straight_ids, MapSet.new())) ==
               WalkLinks.links(input)
    end
  end

  describe "unmeasured_stop_ids/1" do
    test "names a stop with no entry and a stop whose position differs from its entry's" do
      {:ok, %{table: table}} = compute()

      changed =
        positions()
        |> Map.put("a", place(@north + 1, @west))
        |> Map.put("new", place(@north, @middle + 40))

      assert WalkLinks.unmeasured_stop_ids(%{positions: changed, table: table}) ==
               MapSet.new(["a", "new"])
    end
  end

  describe "pack/1 and key/1" do
    test "a table packs to one binary and back" do
      {:ok, %{table: table}} = compute()

      assert table |> WalkLinks.pack() |> WalkLinks.unpack() == table
    end

    test "the key changes with the build and with a position" do
      base = WalkLinks.key(%{build_id: @build_id, positions: positions()})
      other_build = WalkLinks.key(%{build_id: "fedcba9876543210", positions: positions()})

      moved =
        WalkLinks.key(%{build_id: @build_id, positions: Map.put(positions(), "a", place(1, 1))})

      assert base == WalkLinks.key(%{build_id: @build_id, positions: positions()})
      assert length(Enum.uniq([base, other_build, moved])) == 3
    end
  end
end
