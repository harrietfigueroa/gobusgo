defmodule Gobusgo.Pace.TableTest do
  # Checks the table's sums and its cell bound on values.
  use ExUnit.Case, async: true

  alias Gobusgo.Pace.Table

  @date ~D[2026-11-11]

  defp table(cell_count_max), do: Table.new(%{date: @date, cell_count_max: cell_count_max})

  test "sums the seconds and meters of a cell it holds" do
    table = Table.add(table(10), [{{1, 2, 0}, 4.0, 40.0}, {{1, 2, 0}, 6.0, 60.0}])
    assert table.cells == %{{1, 2, 0} => {10.0, 100.0}}
  end

  test "keeps the directions of one place apart" do
    table = Table.add(table(10), [{{1, 2, 0}, 4.0, 40.0}, {{1, 2, 4}, 6.0, 60.0}])
    assert map_size(table.cells) == 2
  end

  test "counts a cell past the bound and leaves it out" do
    table = Table.add(table(1), [{{1, 2, 0}, 4.0, 40.0}, {{9, 9, 0}, 1.0, 10.0}])
    assert table.cells == %{{1, 2, 0} => {4.0, 40.0}}
    assert table.dropped_count == 1
  end

  test "still sums a held cell at the bound" do
    table = Table.add(table(1), [{{1, 2, 0}, 4.0, 40.0}, {{1, 2, 0}, 1.0, 10.0}])
    assert table.cells == %{{1, 2, 0} => {5.0, 50.0}}
    assert table.dropped_count == 0
  end

  test "refuses a cell with no seconds" do
    assert_raise Gobusgo.Assert.AssertionError, fn ->
      Table.add(table(1), [{{1, 2, 0}, 0, 0}])
    end
  end

  test "totals the meters of every cell" do
    table = Table.add(table(10), [{{1, 2, 0}, 4.0, 40.0}, {{9, 9, 0}, 1.0, 10.0}])
    assert Table.meters_total(table) == 50.0
  end
end
