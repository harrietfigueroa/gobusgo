defmodule Gobusgo.Places.FormatTest do
  # Checks the places kind against the shared fixture under
  # test/fixtures/places/v2/, which the JavaScript reader decodes too, against
  # the published version 1 files, which it still reads, and against the rules
  # the kind refuses a file for.
  use ExUnit.Case, async: true

  alias Gobusgo.Packed
  alias Gobusgo.Places.Format
  alias Gobusgo.Places.Records
  alias Gobusgo.Test.PlaceFixture

  @directory PlaceFixture.directory()
  @expectation %{kind: 5, versions: [2], section_count: 9}
  defp fixture_bytes, do: File.read!(Path.join(@directory, "places.bin"))

  # Replaces one section after the string table, counted from 0, in a container.
  defp with_section(binary, index, replacement) do
    {:ok, container} = Packed.decode(binary, @expectation)
    sections = List.replace_at(container.sections, index, replacement)

    Packed.encode(%{
      kind: container.kind,
      version: container.version,
      record_count: container.record_count,
      strings: Tuple.to_list(container.strings),
      sections: sections
    })
  end

  test "encodes the fixture places to the bytes of places.bin" do
    assert PlaceFixture.encode() == fixture_bytes()
  end

  test "places.bin.gz expands to places.bin" do
    stream = File.read!(Path.join(@directory, "places.bin.gz"))
    assert Packed.expand(stream, Format.expanded_bytes_max()) == {:ok, fixture_bytes()}
  end

  test "decodes the rows the fixture places were written from" do
    assert {:ok, decoded} = Format.decode(fixture_bytes())
    assert decoded.places == Enum.map(PlaceFixture.places(), &Records.row/1)

    assert Enum.map(decoded.places, &List.last/1) ==
             Enum.map(PlaceFixture.places(), & &1.locality)

    assert decoded.source_date == PlaceFixture.source_date()
    assert decoded.categories == Gobusgo.Places.Classification.categories()
  end

  test "reads a version 1 file with no locality for any place" do
    bytes = File.read!(Path.join(PlaceFixture.version_one_directory(), "places.bin"))

    assert {:ok, decoded} = Format.decode(bytes)
    assert length(decoded.places) == 5
    assert Enum.all?(decoded.places, &(List.last(&1) == ""))
    assert Enum.map(decoded.places, &hd/1) == Enum.map(PlaceFixture.places(), & &1.name)
  end

  test "refuses a version 2 header that holds the 8 sections of version 1" do
    {:ok, container} = Packed.decode(fixture_bytes(), @expectation)

    bytes =
      Packed.encode(%{
        kind: container.kind,
        version: container.version,
        record_count: container.record_count,
        strings: Tuple.to_list(container.strings),
        sections: Enum.take(container.sections, 8)
      })

    assert Format.decode(bytes) == {:error, :section_count}
  end

  test "refuses a locality index past the string table" do
    localities = Gobusgo.Packed.Columns.encode(:u32, [0, 0, 0, 0, 999])

    assert Format.decode(with_section(fixture_bytes(), 8, localities)) ==
             {:error, :bad_string_index}
  end

  test "refuses a locality past the length bound" do
    bytes = File.read!(Path.join(@directory, "locality_over_bound.bin"))
    assert bytes == PlaceFixture.encode_locality_over_bound()
    assert Format.decode(bytes) == {:error, :bad_locality}
  end

  test "stores a name two places share once" do
    assert {:ok, %{strings: strings}} = Packed.decode(fixture_bytes(), @expectation)
    assert Enum.count(Tuple.to_list(strings), &(&1 == "Seattle Center")) == 1
  end

  test "refuses another version" do
    <<magic::binary-size(4), _version::little-16, rest::binary>> = fixture_bytes()

    assert Format.decode(<<magic::binary, 3::little-16, rest::binary>>) ==
             {:error, :unsupported_version}
  end

  test "refuses another section count" do
    bytes = fixture_bytes()
    assert Format.decode(bytes <> <<0, 0, 0, 0>>) == {:error, :section_count}
  end

  test "refuses alias counts that run past the alias column" do
    bytes = with_section(fixture_bytes(), 1, <<9, 0, 0, 0, 0>>)
    assert Format.decode(bytes) == {:error, :alias_counts}
  end

  test "refuses a category index past the categories" do
    bytes = with_section(fixture_bytes(), 4, <<0, 0, 0, 0, 99>>)
    assert Format.decode(bytes) == {:error, :bad_category}
  end

  test "refuses a name index past the string table" do
    bytes =
      with_section(fixture_bytes(), 0, Gobusgo.Packed.Columns.encode(:u32, [0, 1, 2, 3, 999]))

    assert Format.decode(bytes) == {:error, :bad_string_index}
  end

  test "refuses a place with an unknown position" do
    positions = Gobusgo.Packed.Positions.encode([:unknown, {1, 1}, {1, 1}, {1, 1}, {1, 1}])

    assert Format.decode(with_section(fixture_bytes(), 3, positions)) ==
             {:error, :unknown_position}
  end

  test "refuses labels with no category" do
    labels = Gobusgo.Packed.Columns.encode(:u32, [0])
    assert Format.decode(with_section(fixture_bytes(), 7, labels)) == {:error, :bad_labels}
  end

  test "asserts at most 255 aliases a place" do
    aliases = for number <- 1..256, do: "Alias #{number}"
    place = %{hd(PlaceFixture.places()) | aliases: aliases}

    assert_raise Gobusgo.Assert.AssertionError, ~r/at most 255 aliases/, fn ->
      Format.encode(%{source_date: PlaceFixture.source_date(), places: [place]})
    end
  end

  test "asserts a position in range" do
    place = %{hd(PlaceFixture.places()) | lat: 91.0}

    assert_raise Gobusgo.Assert.AssertionError, fn ->
      Format.encode(%{source_date: PlaceFixture.source_date(), places: [place]})
    end
  end

  test "inspect describes the container by its columns" do
    {:ok, container} = Packed.decode(fixture_bytes(), @expectation)
    description = Format.inspect(container)
    assert description["placeCount"] == 5
    assert description["sourceDate"] == PlaceFixture.source_date()
    assert length(description["places"]) == 5
  end
end
