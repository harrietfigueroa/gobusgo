defmodule Gobusgo.Places.RecordsTest do
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Classification
  alias Gobusgo.Places.Records

  @place %{
    name: "Central Library",
    aliases: ["Main Library"],
    lat: 47.6067,
    lon: -122.3325,
    category: "amenity",
    prominence: 140,
    area: 5_000.0,
    area_score: 14,
    locality: "First Hill, Seattle"
  }

  test "row holds integer microdegrees, the category index, the two scores, and the locality" do
    index = Enum.find_index(Classification.categories(), &(&1 == "amenity"))

    assert Records.row(@place) == [
             "Central Library",
             ["Main Library"],
             47_606_700,
             -122_332_500,
             index,
             140,
             14,
             "First Hill, Seattle"
           ]
  end

  test "encode names the source date and the categories in index order" do
    decoded =
      %{source_date: "2026-11-08T21:21:00Z", places: [@place]}
      |> Records.encode()
      |> JSON.decode!()

    assert decoded["sourceDate"] == "2026-11-08T21:21:00Z"
    assert decoded["categories"] == Classification.categories()

    assert [[_name, _aliases, 47_606_700, -122_332_500, _index, 140, 14, "First Hill, Seattle"]] =
             decoded["places"]
  end
end
