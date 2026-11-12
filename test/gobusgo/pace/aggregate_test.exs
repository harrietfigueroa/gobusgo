defmodule Gobusgo.Pace.AggregateTest do
  # Checks the stored form of one table: its destination, the encoding of
  # its cells, and what its meta says.
  use ExUnit.Case, async: true

  alias Gobusgo.Pace.Aggregate
  alias Gobusgo.Pace.Table

  @written_at ~U[2026-11-12 00:00:30Z]
  @file_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  defp build(cells, overrides \\ %{}) do
    table = Table.add(Table.new(%{date: ~D[2026-11-11], cell_count_max: 10}), cells)

    Aggregate.build(
      Map.merge(
        %{table: table, node: "nonode@nohost", file_id: @file_id, written_at: @written_at},
        overrides
      )
    )
  end

  test "names the day and the node and run in the destination" do
    file = build([{{1, 2, 0, 0}, 1.0, 1.0}])
    assert file.destination == "paces/daily/dt=2026-11-11/nonode.40nohost-#{@file_id}.json.gz"
    assert String.starts_with?(file.destination, Aggregate.prefix() <> "/")
  end

  test "keys each cell by its grid cells, direction, and band and rounds its sums" do
    file = build([{{-271_867, 158_666, 2, 1}, 1.23456, 10.98765}])
    assert %{"cells" => %{"-271867,158666,2,1" => [1.235, 10.988]}} = JSON.decode!(file.content)
  end

  test "keeps the bands of one place apart" do
    file = build([{{1, 2, 0, 0}, 1.0, 1.0}, {{1, 2, 0, 1}, 2.0, 2.0}])
    assert %{"cells" => cells} = JSON.decode!(file.content)
    assert Map.keys(cells) == ["1,2,0,0", "1,2,0,1"]
  end

  test "states the format in its meta" do
    file = build([{{1, 2, 0, 0}, 1.0, 40.0}, {{1, 2, 0, 1}, 2.0, 2.0}])

    assert %{"meta" => meta} = JSON.decode!(file.content)

    assert meta == %{
             "bandStartHours" => [0, 6, 9, 15, 19],
             "cellCount" => 2,
             "cellDegrees" => %{"lat" => 0.0003, "lon" => 0.00045},
             "date" => "2026-11-11",
             "directionCount" => 8,
             "droppedCellCount" => 0,
             "fileId" => @file_id,
             "formatVersion" => 1,
             "metersTotal" => 42.0,
             "node" => "nonode@nohost",
             "stepMeters" => 10,
             "writtenAt" => "2026-11-12T00:00:30Z"
           }

    assert file.cell_count == 2
    assert file.meters_total == 42.0
  end

  test "refuses an empty file id" do
    assert_raise FunctionClauseError, fn -> build([{{1, 2, 0, 0}, 1.0, 1.0}], %{file_id: ""}) end
  end
end
