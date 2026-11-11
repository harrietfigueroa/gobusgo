defmodule Gobusgo.Addresses.AccumulatorTest do
  # Feeds hand-written county records to the accumulator and reads back the
  # streets, the counts, and the hash of what it holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Accumulator
  alias Gobusgo.Addresses.Rows

  @seattle_bounds %{south: 47.0, west: -123.0, north: 48.0, east: -121.0}

  defp record(overrides) do
    Map.merge(
      %{
        house_number: "85",
        pre_direction: "",
        name: "PIKE",
        type: "ST",
        suf_direction: "",
        city: "SEATTLE",
        lat: 47.6097,
        lon: -122.3422
      },
      Map.new(overrides)
    )
  end

  defp finish(records, bounds \\ nil) do
    records
    |> Enum.reduce(Accumulator.new(bounds), &Accumulator.add(&2, &1))
    |> Accumulator.finish()
  end

  test "records of one street in one city are one street with their addresses sorted by number" do
    result =
      finish([
        record(house_number: "100"),
        record(house_number: "85"),
        record(house_number: "100 B", lat: 47.61, lon: -122.34),
        record(house_number: "100 A", lat: 47.61, lon: -122.34)
      ])

    assert [%{city: "SEATTLE", name_key: "PIKE", rows: rows}] = result.streets

    assert Enum.map(Rows.unpack(rows), &{&1.number, &1.suffix}) ==
             [{85, ""}, {100, ""}, {100, "A"}, {100, "B"}]

    assert result.address_count == 4
  end

  test "the same street in two cities is two streets" do
    result = finish([record([]), record(city: "KENT")])
    assert Enum.map(result.streets, & &1.city) == ["KENT", "SEATTLE"]
  end

  test "spellings of one street reach one street" do
    result =
      finish([
        record(name: "12TH", type: "AVENUE", suf_direction: "SOUTH"),
        record(name: "TWELFTH", type: "AVE", suf_direction: "S", house_number: "86")
      ])

    assert [%{rows: rows}] = result.streets
    assert Rows.count(rows) == 2
  end

  test "a repeated address is one address at the mean of its positions" do
    result = finish([record(lat: 47.0, lon: -122.0), record(lat: 47.000002, lon: -122.000004)])

    assert [%{rows: rows}] = result.streets
    assert [%{lat_microdegrees: 47_000_001, lon_microdegrees: -122_000_002}] = Rows.unpack(rows)
  end

  test "a street of more rows than a tail holds keeps every row" do
    records = for number <- 1..1_000, do: record(house_number: Integer.to_string(number))
    result = finish(records)

    assert [%{rows: rows}] = result.streets
    assert rows |> Rows.unpack() |> Enum.map(& &1.number) == Enum.to_list(1..1_000)
  end

  test "each cause a record is left out has its own count" do
    result =
      finish(
        [
          record([]),
          record(house_number: "no number"),
          record(house_number: ""),
          record(house_number: "12 1/2"),
          record(name: "", type: ""),
          record(lat: nil),
          record(lat: 95.0),
          record(lat: 40.0, lon: -100.0)
        ],
        @seattle_bounds
      )

    assert result.counts == %{
             read: 8,
             accepted: 1,
             invalid: 5,
             suffix_unsupported: 1,
             outside_bounds: 1
           }
  end

  test "with no bounds a position outside the region is kept" do
    result = finish([record(lat: 40.0, lon: -100.0)])
    assert result.counts.accepted == 1
  end

  test "the hash is the same for the same addresses in another order" do
    left = finish([record(house_number: "1"), record(house_number: "2")])
    right = finish([record(house_number: "2"), record(house_number: "1")])
    assert left.sha256 == right.sha256
  end

  test "the hash changes with a position, a number, a street, and a city" do
    base = finish([record([])]).sha256

    for change <- [[lat: 47.6098], [house_number: "86"], [name: "PINE"], [city: "KENT"]] do
      refute finish([record(change)]).sha256 == base, "unchanged by #{inspect(change)}"
    end
  end
end
