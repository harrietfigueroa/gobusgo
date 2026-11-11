defmodule Gobusgo.Routing.TripPathShardTest do
  # Builds shards from King County Metro's stored loop route 1_7994 of
  # 2026-11-09, whose two trips serve one stop sequence, and from trips
  # derived from them by changing one input each case names. What a shard
  # holds is read back with `decode/1` and compared with
  # `Gobusgo.OneBusAway.TripPath.build_route/1` over the same input; the
  # decoder's refusals are checked on bytes damaged one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Varint
  alias Gobusgo.Polyline
  alias Gobusgo.Routing.TripPathShard
  alias Gobusgo.Test.TripPathShardFixture

  @fixture_directory TripPathShardFixture.directory()
  @microdegrees_per_e5 10

  defp fixture_bytes(name), do: @fixture_directory |> Path.join(name) |> File.read!()

  defp built(input \\ TripPathShardFixture.input()) do
    {:ok, built} = TripPathShard.build(input)
    built
  end

  defp decoded(input \\ TripPathShardFixture.input()) do
    {:ok, trips} = input |> built() |> Map.fetch!(:content) |> TripPathShard.decode()
    trips
  end

  # A trip of the loop route's first trip's stops with one stop dropped, so
  # it serves a stop sequence of its own.
  defp skipping_trip(input) do
    [first | _rest] = input.trips
    %{first | id: "1_skipping", stop_times: List.delete_at(first.stop_times, 3)}
  end

  defp replace_section(content, index, section) do
    {:ok, decoded} =
      Packed.decode(content, %{kind: 1, versions: [1], section_count: 4})

    sections = List.replace_at(decoded.sections, index, section)

    Packed.encode(%{
      kind: 1,
      version: 1,
      record_count: decoded.record_count,
      strings: Tuple.to_list(decoded.strings),
      sections: sections
    })
  end

  defp section(content, index) do
    {:ok, decoded} = Packed.decode(content, %{kind: 1, versions: [1], section_count: 4})
    Enum.at(decoded.sections, index)
  end

  describe "the fixture" do
    test "is the expanded bytes the builder writes" do
      assert fixture_bytes("shard.bin") == TripPathShardFixture.shard_content()
    end

    test "is the same content as its gzip stream" do
      {:ok, content} =
        Packed.expand(fixture_bytes("shard.bin.gz"), Compression.content_bytes_max())

      assert content == fixture_bytes("shard.bin")
    end
  end

  describe "build/1" do
    test "holds every trip of the route in identifier order" do
      assert Enum.map(decoded(), & &1.id) == ["1_1137791", "1_1137792"]
    end

    test "holds each trip's points as the whole microdegrees of the path's points" do
      input = TripPathShardFixture.input()
      %{paths: paths} = TripPath.build_route(input)
      {:ok, %{points: encoded}} = Map.fetch!(paths, "1_1137791")
      {:ok, numbers} = Polyline.decode_integers(encoded)

      [%{points: points} | _trips] = decoded(input)

      cumulative =
        numbers
        |> Enum.chunk_every(2)
        |> Enum.scan({0, 0}, fn [latitude, longitude], {latitude_before, longitude_before} ->
          {latitude_before + latitude, longitude_before + longitude}
        end)
        |> Enum.map(fn {latitude, longitude} ->
          {latitude * @microdegrees_per_e5, longitude * @microdegrees_per_e5}
        end)

      assert points == cumulative
    end

    test "holds each trip's stop distances and times as the path builder gives them" do
      input = TripPathShardFixture.input()
      %{paths: paths} = TripPath.build_route(input)

      for trip <- decoded(input) do
        {:ok, path} = Map.fetch!(paths, trip.id)
        reference = TripPath.decode(path)

        assert {
                 Enum.map(trip.stops, & &1.distance_m),
                 Enum.map(trip.stops, & &1.arrival_s),
                 Enum.map(trip.stops, & &1.departure_s)
               } == {reference.stop_distances_m, reference.arrival_s, reference.departure_s}
      end
    end

    test "gives trips that serve one stop sequence one pattern and one geometry" do
      assert %{trip_count: 2, pattern_count: 1, geometry_count: 1} =
               Map.delete(built(), :content)
    end

    test "gives a trip with a stop sequence of its own a pattern of its own" do
      input = TripPathShardFixture.input()
      input = %{input | trips: input.trips ++ [skipping_trip(input)]}

      assert %{trip_count: 3, pattern_count: 2} = Map.delete(built(input), :content)
    end

    test "writes the same bytes whatever the order of the trips" do
      input = TripPathShardFixture.input()
      reversed = %{input | trips: Enum.reverse(input.trips)}

      assert built(reversed).content == built(input).content
    end

    test "writes the same bytes for a second build of the same input" do
      assert built().content == built().content
    end

    test "keeps the first of two trips that share an identifier" do
      input = TripPathShardFixture.input()
      [first | _rest] = input.trips
      shifted = %{first | stop_times: Enum.map(first.stop_times, &%{&1 | arrival_s: 0})}
      input = %{input | trips: [first, shifted]}

      assert [%{id: "1_1137791", stops: [%{arrival_s: arrival_s} | _stops]}] = decoded(input)
      assert arrival_s == hd(first.stop_times).arrival_s
    end

    test "returns :no_paths when no stop has a position" do
      input = %{TripPathShardFixture.input() | stop_positions: %{}}

      assert :no_paths == TripPathShard.build(input)
    end

    test "leaves out only the trips with a missing stop position" do
      input = TripPathShardFixture.input()
      [first | _rest] = input.trips

      stranger = %{
        first
        | id: "1_stranger",
          stop_times: [%{hd(first.stop_times) | stop_id: "1_none"}]
      }

      input = %{input | trips: input.trips ++ [stranger]}

      assert Enum.map(decoded(input), & &1.id) == ["1_1137791", "1_1137792"]
    end

    test "returns :no_paths for a route with no trips" do
      input = %{TripPathShardFixture.input() | trips: []}

      assert :no_paths == TripPathShard.build(input)
    end
  end

  describe "decode/1" do
    test "reads the fixture's stored stream's content" do
      {:ok, content} =
        Packed.expand(fixture_bytes("shard.bin.gz"), Compression.content_bytes_max())

      assert {:ok, [%{id: "1_1137791"}, %{id: "1_1137792"}]} = TripPathShard.decode(content)
    end

    test "refuses an index file as another kind" do
      assert {:error, :kind_mismatch} = TripPathShard.decode(fixture_bytes("index.bin"))
    end

    test "refuses a version it does not know" do
      <<head::binary-size(4), _version::little-16, rest::binary>> = fixture_bytes("shard.bin")

      assert {:error, :unsupported_version} =
               TripPathShard.decode(<<head::binary, 2::little-16, rest::binary>>)
    end

    test "refuses a file cut short" do
      content = fixture_bytes("shard.bin")

      assert {:error, :truncated} =
               TripPathShard.decode(binary_part(content, 0, byte_size(content) - 1))
    end

    test "refuses a pattern that names a geometry the shard lacks" do
      content = fixture_bytes("shard.bin")
      damaged = replace_section(content, 1, <<1, 5, 1, 0>>)

      assert {:error, :bad_index} = TripPathShard.decode(damaged)
    end

    test "refuses a trip that names a pattern the shard lacks" do
      content = fixture_bytes("shard.bin")
      columns = section(content, 2)
      <<strings::binary-size(8), _patterns::binary-size(8), offsets::binary>> = columns

      damaged =
        replace_section(
          content,
          2,
          <<strings::binary, 7::little-32, 7::little-32, offsets::binary>>
        )

      assert {:error, :bad_index} = TripPathShard.decode(damaged)
    end

    test "refuses times that stop short of the section's end" do
      content = fixture_bytes("shard.bin")
      times = section(content, 3)
      damaged = replace_section(content, 3, <<times::binary, 0>>)

      assert {:error, :bad_section_size} = TripPathShard.decode(damaged)
    end

    test "refuses a trip column that is not three values a trip" do
      content = fixture_bytes("shard.bin")
      columns = section(content, 2)
      damaged = replace_section(content, 2, binary_part(columns, 0, byte_size(columns) - 4))

      assert {:error, :bad_section_size} = TripPathShard.decode(damaged)
    end

    test "refuses a geometry of no point" do
      damaged = replace_section(fixture_bytes("shard.bin"), 0, <<1, 0>>)

      assert {:error, :bad_index} = TripPathShard.decode(damaged)
    end

    test "refuses a pattern of no stop" do
      damaged = replace_section(fixture_bytes("shard.bin"), 1, <<1, 0, 0>>)

      assert {:error, :bad_index} = TripPathShard.decode(damaged)
    end

    test "refuses a pattern with a stop before the stop before it" do
      damaged = replace_section(fixture_bytes("shard.bin"), 1, <<1, 0, 2, 0, 1>>)

      assert {:error, :bad_index} = TripPathShard.decode(damaged)
    end

    test "refuses two trips of one identifier" do
      content = fixture_bytes("shard.bin")
      <<_strings::binary-size(8), rest::binary>> = section(content, 2)
      damaged = replace_section(content, 2, <<0::little-32, 0::little-32, rest::binary>>)

      assert {:error, :bad_index} = TripPathShard.decode(damaged)
    end

    test "refuses a geometry section with bytes after its last geometry" do
      content = fixture_bytes("shard.bin")
      geometries = section(content, 0)
      damaged = replace_section(content, 0, <<geometries::binary, Varint.encode(0)::binary>>)

      assert {:error, :bad_section_size} = TripPathShard.decode(damaged)
    end
  end
end
