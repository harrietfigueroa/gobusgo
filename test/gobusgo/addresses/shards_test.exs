defmodule Gobusgo.Addresses.ShardsTest do
  # Cuts hand-written streets with an encoder defined here, whose content is
  # the name key and the rows of each street, so a group's size is the sum
  # of what its streets hold and a bound is easy to set by hand.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Rows
  alias Gobusgo.Addresses.Shards

  # Each street is a name key of the length it has, a separator, and one row.
  defp street(name_key, city \\ "SEATTLE") do
    row =
      Rows.pack(%{
        number: 1,
        suffix: "",
        lat_microdegrees: 47_000_000,
        lon_microdegrees: -122_000_000
      })

    %{
      street: %{pre_direction: "", name: name_key, type: "ST", suf_direction: ""},
      name_key: name_key,
      city: city,
      rows: row
    }
  end

  defp encode(streets), do: IO.iodata_to_binary(for s <- streets, do: [s.name_key, 0, s.rows])

  defp split(streets, bytes_max) do
    streets
    |> Enum.sort_by(&{&1.name_key, &1.city})
    |> Shards.split(%{encode: &encode/1, bytes_min: fn _group -> 0 end, bytes_max: bytes_max})
  end

  defp prefixes(shards), do: Enum.map(shards, & &1.prefix)

  test "streets that fit the bound are one shard with the empty prefix" do
    shards = split([street("PIKE"), street("PINE")], 10_000)
    assert prefixes(shards) == [""]
    assert [%{streets: [_, _], content: content}] = shards
    assert content == encode(Enum.sort_by([street("PIKE"), street("PINE")], & &1.name_key))
  end

  test "an oversize group splits by the next letter and every street lands in one shard" do
    streets = for name <- ~w(APPLE ASH BIRCH CEDAR CHERRY ELM), do: street(name)
    shards = split(streets, 30)

    assert prefixes(shards) == ["AP", "AS", "B", "CE", "CH", "E"]

    assert shards |> Enum.flat_map(& &1.streets) |> Enum.map(& &1.name_key) |> Enum.sort() ==
             Enum.sort(Enum.map(streets, & &1.name_key))
  end

  test "a name that is the prefix of longer names stays in a shard of its own" do
    streets = for name <- ~w(MAIN MAINE MAINLAND MAPLE), do: street(name)
    shards = split(streets, 40)

    own = Enum.find(shards, &(&1.prefix == "MAIN$"))
    assert Enum.map(own.streets, & &1.name_key) == ["MAIN"]
  end

  test "a group whose names all continue with one letter descends without a shard of its own" do
    streets = for name <- ~w(ZEBRA ZONE ZULU), do: street(name)
    shards = split(streets, 40)

    refute "" in prefixes(shards)
    refute "Z" in prefixes(shards)
  end

  test "streets of one name over the bound stay together in one shard as large as they are" do
    streets = for city <- ~w(AUBURN KENT RENTON SEATTLE), do: street("MAIN", city)
    shards = split(streets, 20)

    assert [%{prefix: prefix, streets: grouped}] = shards
    assert length(grouped) == 4
    assert String.length(prefix) <= Shards.prefix_length_max()
  end

  test "a name longer than the longest prefix is cut at the longest prefix" do
    long = String.duplicate("A", 40)
    shards = split([street(long), street(long <> "B"), street(long <> "C")], 20)

    assert Enum.all?(shards, &(String.length(&1.prefix) <= Shards.prefix_length_max() + 1))
    assert Enum.sum(for shard <- shards, do: length(shard.streets)) == 3
  end

  test "the same streets give the same shards" do
    streets = for name <- ~w(APPLE ASH BIRCH CEDAR CHERRY ELM), do: street(name)
    assert split(streets, 40) == split(Enum.reverse(streets), 40)
  end

  test "no streets give no shards" do
    assert split([], 40) == []
  end

  test "a lower bound that rules out a group gives the shards that encoding every group does" do
    streets =
      for name <- ~w(APPLE ASH BIRCH CEDAR CHERRY ELM MAIN MAINE MAINLAND), do: street(name)

    sorted = Enum.sort_by(streets, &{&1.name_key, &1.city})

    lower_bound = fn group ->
      Enum.sum(for street <- group, do: byte_size(street.name_key) + 1)
    end

    by_lower_bound =
      Shards.split(sorted, %{encode: &encode/1, bytes_min: lower_bound, bytes_max: 40})

    assert by_lower_bound == split(streets, 40)
  end
end
