defmodule Gobusgo.Routing.Snapshots.WalkFallbackTest do
  # Drives Walk.plan/2 and Walk.fallback/2 against a Snapshots process that
  # holds a table measured over the walk graph fixture, then asks for the
  # plan of positions the table was not measured for: what stands in for the
  # table that is not current, and what the entry says of it. The streets are
  # told from the straight line by the stop pairs the fixture's streets
  # lengthen.
  use ExUnit.Case, async: true

  alias Gobusgo.Reader
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Snapshots.Walk
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.Routing.WalkLinks
  alias Gobusgo.Test.WalkGraphFixture
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @units 100_000
  @settle_attempts_max 200
  @settle_pause_ms 25
  @heap_words 40_000_000
  @deadline_ms 60_000
  @west_tile {4761, -8156}
  @east_tile {4761, -8155}

  setup context do
    server = Module.concat(__MODULE__, "Server#{context.line}")
    start_supervised!({Snapshots, name: server})
    read_options = [backend: Reader.LocalFile, base_dir: context.tmp_dir]
    context = Map.put(context, :read_options, read_options)

    publish(context, %{
      built_at: ~U[2026-11-14 12:00:00Z],
      tiles: %{@west_tile => :west, @east_tile => :east}
    })

    %{server: server, read_options: read_options, tmp_dir: context.tmp_dir}
  end

  defp publish(context, %{built_at: built_at, tiles: tiles}) do
    packed = fn pieces ->
      for %{class: class, points: points} <- pieces do
        {class, for({lat, lon} <- points, into: <<>>, do: <<lat::signed-32, lon::signed-32>>)}
      end
    end

    {:ok, _published} =
      Publication.publish(
        %{
          built_at: built_at,
          source_date: "2026-11-08T21:21:00Z",
          tiles:
            Map.new(tiles, fn {tile, side} -> {tile, packed.(WalkGraphFixture.pieces(side))} end)
        },
        read_options: context.read_options,
        write_options: [backend: Writer.LocalFile, base_dir: context.tmp_dir],
        delete_options: [backend: Gobusgo.Deleter.LocalFile, base_dir: context.tmp_dir]
      )
  end

  defp place(lat_units, lon_units), do: %{lat: lat_units / @units, lon: lon_units / @units}

  defp positions do
    %{
      "a" => place(4_761_450, -12_233_600),
      "b" => place(4_761_450, -12_233_400),
      "c" => place(4_761_300, -12_233_600)
    }
  end

  defp options(context, overrides \\ []) do
    Keyword.merge(
      [
        server: context.server,
        walk_basis: :streets,
        walk_read_options: context.read_options,
        walk_heap_words_max: @heap_words,
        walk_deadline_ms: @deadline_ms
      ],
      overrides
    )
  end

  # Measures the table of `positions` and waits for it to be held.
  defp hold_table(context, positions) do
    plan = Walk.plan(options(context), positions)
    Walk.measure(plan, options(context))

    Enum.find_value(1..@settle_attempts_max, fn _attempt ->
      case Walk.plan(options(context), positions) do
        %{kind: :streets} = held ->
          held

        _pending ->
          Process.sleep(@settle_pause_ms)
          nil
      end
    end)
  end

  defp rows_from(links, stop_index), do: Enum.filter(links, &(&1.from_stop == stop_index))
  defp rows_to(links, stop_index), do: Enum.filter(links, &(&1.to_stop == stop_index))

  test "gives a new stop the straight line while the measuring is pending", context do
    %{table: table} = hold_table(context, Map.take(positions(), ["a", "b"]))
    stop_ids = ["a", "b", "c"]

    plan = Walk.plan(options(context), positions())
    assert %{kind: :unavailable, measure: _request} = plan
    fallback = Walk.fallback(plan, positions())

    assert %{kind: :mixed, straight: straight} = fallback
    assert straight == MapSet.new(["c"])
    assert Walk.entry_basis(fallback) == %{kind: :mixed, build_id: plan.build_id}

    links = Walk.links(fallback, stop_ids, positions())
    straight_links = Transfers.walking_links(stop_ids, positions())

    assert rows_from(links, 2) == rows_from(straight_links, 2)
    assert rows_from(links, 2) != []
    assert rows_to(links, 2) == rows_to(straight_links, 2)

    street_links =
      WalkLinks.links(%{
        stop_ids: ["a", "b"],
        positions: positions(),
        table: WalkLinks.unpack(table)
      })

    assert Enum.filter(links, &(&1.from_stop == 0 and &1.to_stop == 1)) ==
             Enum.filter(street_links, &(&1.from_stop == 0 and &1.to_stop == 1))
  end

  test "gives a moved stop the straight line while the measuring was killed", context do
    hold_table(context, positions())
    moved = Map.put(positions(), "b", place(4_761_450, -12_233_500))
    stop_ids = ["a", "b", "c"]
    killed = options(context, walk_heap_words_max: 1_000)

    plan = Walk.plan(killed, moved)
    Walk.measure(plan, killed)
    settle_failed(context, moved)

    fallback = killed |> Walk.plan(moved) |> Walk.fallback(moved)

    assert %{kind: :mixed, straight: straight} = fallback
    assert straight == MapSet.new(["b"])

    links = Walk.links(fallback, stop_ids, moved)
    straight_links = Transfers.walking_links(stop_ids, moved)

    assert rows_from(links, 1) == rows_from(straight_links, 1)
    assert rows_to(links, 1) == rows_to(straight_links, 1)
  end

  test "builds by the straight line when only a table of an older graph build is held",
       context do
    hold_table(context, positions())
    publish(context, %{built_at: ~U[2026-11-14 13:00:00Z], tiles: %{@west_tile => :west}})

    plan = Walk.plan(options(context), positions())
    assert %{kind: :unavailable} = plan
    fallback = Walk.fallback(plan, positions())

    assert %{kind: :straight} = fallback
    assert Walk.entry_basis(fallback) == %{kind: :straight, build_id: nil}

    assert Walk.links(fallback, ["a", "b", "c"], positions()) ==
             Transfers.walking_links(["a", "b", "c"], positions())
  end

  test "keeps the table whole where every stop stands where it was measured", context do
    hold_table(context, positions())
    plan = Walk.plan(options(context), Map.take(positions(), ["a", "b"]))

    assert %{kind: :unavailable} = plan
    assert %{kind: :streets} = Walk.fallback(plan, Map.take(positions(), ["a", "b"]))
  end

  defp settle_failed(context, positions) do
    {:ok, graph} = Gobusgo.Routing.WalkLinks.Store.manifest(context.read_options)

    request = %{
      manifest: graph,
      positions: positions,
      read_options: context.read_options,
      heap_words_max: 1_000,
      deadline_ms: @deadline_ms,
      deadline_grace_ms: Snapshots.deadline_grace_ms(),
      start?: false
    }

    Enum.find_value(1..@settle_attempts_max, fn _attempt ->
      case Snapshots.walk_links(context.server, request) do
        {:failed, :killed} ->
          :failed

        _pending ->
          Process.sleep(@settle_pause_ms)
          nil
      end
    end)
  end
end
