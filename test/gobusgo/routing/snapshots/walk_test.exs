defmodule Gobusgo.Routing.Snapshots.WalkTest do
  # Checks what a run decides of its walks: the straight line gives exactly
  # the links the straight-line rule gives, reads no walk graph, and needs no
  # process; and what the manifest entry says of each plan.
  use ExUnit.Case, async: true

  alias Gobusgo.Routing.Snapshots.Walk
  alias Gobusgo.Routing.Transfers

  @positions %{
    "1_a" => %{lat: 47.6097, lon: -122.3331},
    "1_b" => %{lat: 47.6101, lon: -122.3331},
    "1_c" => %{lat: 47.6190, lon: -122.3331}
  }

  defp options do
    [
      server: :no_such_process,
      walk_basis: :straight,
      walk_read_options: [backend: :no_such_backend],
      walk_heap_words_max: 1,
      walk_deadline_ms: 1
    ]
  end

  test "plans the straight line without a process, a read, or a backend" do
    assert Walk.plan(options(), @positions) == %{kind: :straight, key: :straight}
  end

  test "gives the straight line's links to the stops of a snapshot as the rule gives them" do
    stop_ids = ["1_a", "1_b", "1_c", "1_unknown"]
    plan = Walk.plan(options(), @positions)

    assert Walk.links(plan, stop_ids, @positions) == Transfers.walking_links(stop_ids, @positions)
  end

  test "names how the walks of a plan were measured" do
    assert Walk.entry_basis(%{kind: :straight, key: :straight}) == %{
             kind: :straight,
             build_id: nil
           }

    assert Walk.entry_basis(%{kind: :streets, build_id: "0123456789abcdef", table: <<>>, key: 1}) ==
             %{kind: :streets, build_id: "0123456789abcdef"}
  end

  test "takes the basis the application is configured with when none is given" do
    plan = Walk.plan(Keyword.put(options(), :walk_basis, nil), @positions)

    assert plan.kind == :straight
  end
end
