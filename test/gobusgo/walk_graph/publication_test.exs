defmodule Gobusgo.WalkGraph.PublicationTest do
  # Publishes small tiles through the local file writer and deleter into the
  # test's temporary directory, and reads back what was stored: the shards
  # by their build-named destinations, the index by its hash, and the
  # manifest that names them.
  use ExUnit.Case, async: true

  alias Gobusgo.Deleter
  alias Gobusgo.Packed
  alias Gobusgo.Reader
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.Writer

  @moduletag :tmp_dir

  @built_at ~U[2026-11-10 22:00:00Z]

  defp piece(class, points) do
    binary = for {lat, lon} <- points, into: <<>>, do: <<lat::signed-32, lon::signed-32>>
    {class, binary}
  end

  defp request do
    %{
      source_date: "2026-11-08T21:21:00Z",
      tiles: %{
        {4_761, -8_156} => [
          piece(4, [{4_761_100, -12_233_900}, {4_761_100, -12_233_800}]),
          piece(1, [{4_761_100, -12_233_800}, {4_761_200, -12_233_800}])
        ],
        {4_761, -8_155} => [piece(0, [{4_761_100, -12_232_400}, {4_761_100, -12_232_300}])]
      },
      built_at: @built_at
    }
  end

  defp options(tmp_dir) do
    [
      read_options: [backend: Reader.LocalFile, base_dir: tmp_dir],
      write_options: [backend: Writer.LocalFile, base_dir: tmp_dir],
      delete_options: [backend: Deleter.LocalFile, base_dir: tmp_dir]
    ]
  end

  defp manifest_files(tmp_dir),
    do:
      tmp_dir
      |> Path.join("intersections/walking-manifest-*.json")
      |> Path.wildcard()
      |> Enum.sort()

  defp manifest(tmp_dir),
    do: tmp_dir |> manifest_files() |> List.last() |> File.read!() |> JSON.decode!()

  defp expand(tmp_dir, path, kind) do
    stream = tmp_dir |> Path.join(path) |> File.read!()
    {:ok, content} = Packed.expand(stream, Format.expanded_bytes_max(kind))
    {stream, content}
  end

  test "stores a shard per tile under the build and the tile, and the index under its hash", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))
    manifest = manifest(tmp_dir)

    assert manifest["index"]["path"] =~
             ~r"\A/intersections/walk-graph-index-[0-9a-f]{64}\.bin\.gz\z"

    {stream, content} = expand(tmp_dir, manifest["index"]["path"], :index)

    assert :crypto.hash(:sha256, stream) |> Base.encode16(case: :lower) ==
             manifest["index"]["sha256"]

    assert {:ok, %{build_id: build_id, tiles: [{4_761, -8_156}, {4_761, -8_155}]}} =
             Format.decode_index(content)

    assert build_id == published.build_id

    for tile <- [{4_761, -8_156}, {4_761, -8_155}] do
      name = Format.shard_file_name(%{build_id: build_id, tile: tile})
      {_stream, shard} = expand(tmp_dir, "intersections/" <> name, :shard)
      assert {:ok, %{pieces: [_first | _rest]}} = Format.decode_shard(shard)
    end
  end

  test "orders a shard's pieces by their Morton code, not by the order given", %{tmp_dir: tmp_dir} do
    assert {:ok, %{build_id: build_id}} = Publication.publish(request(), options(tmp_dir))
    name = Format.shard_file_name(%{build_id: build_id, tile: {4_761, -8_156}})
    {_stream, shard} = expand(tmp_dir, "intersections/" <> name, :shard)
    assert {:ok, %{pieces: [%{class: 4}, %{class: 1}]}} = Format.decode_shard(shard)
  end

  test "states the counts, the tile, the source, and the license in the manifest", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))

    assert %{
             "attribution" => "© OpenStreetMap contributors",
             "buildId" => build_id,
             "builtAt" => "2026-11-10T22:00:00Z",
             "license" => %{
               "name" => "Open Database License 1.0",
               "url" => "https://opendatacommons.org/licenses/odbl/1-0/"
             },
             "pieceCount" => 3,
             "shardCount" => 2,
             "sourceDate" => "2026-11-08T21:21:00Z",
             "tile" => %{"latUnits" => 1_000, "lonUnits" => 1_500},
             "unitsPerDegree" => 100_000
           } = manifest(tmp_dir)

    assert build_id == published.build_id
  end

  test "names the same build for the same shards and another for changed ones", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, first} = Publication.publish(request(), options(tmp_dir))
    assert {:ok, again} = Publication.publish(request(), options(tmp_dir))
    assert first.build_id == again.build_id

    changed =
      put_in(request().tiles[{4_761, -8_155}], [
        piece(0, [{4_761_100, -12_232_400}, {4_761_100, -12_232_200}])
      ])

    assert {:ok, other} = Publication.publish(changed, options(tmp_dir))
    assert other.build_id != first.build_id
  end

  test "stores the manifest after the files it names", %{tmp_dir: tmp_dir} do
    assert {:ok, _published} = Publication.publish(request(), options(tmp_dir))
    manifest = manifest(tmp_dir)
    assert File.exists?(Path.join(tmp_dir, manifest["index"]["path"]))
  end

  test "deletes an earlier build's manifest and leaves its files", %{tmp_dir: tmp_dir} do
    assert {:ok, first} = Publication.publish(request(), options(tmp_dir))

    changed =
      put_in(request().tiles[{4_761, -8_155}], [
        piece(0, [{4_761_100, -12_232_400}, {4_761_100, -12_232_200}])
      ])

    later = %{changed | built_at: ~U[2026-11-11 22:00:00Z]}
    assert {:ok, second} = Publication.publish(later, options(tmp_dir))

    assert [only] = manifest_files(tmp_dir)
    assert only =~ "20261111T220000Z"

    old_name = Format.shard_file_name(%{build_id: first.build_id, tile: {4_761, -8_156}})
    assert File.exists?(Path.join(tmp_dir, "intersections/" <> old_name))
    assert second.build_id != first.build_id
  end

  test "reads the newest manifest back and the reason there is none", %{tmp_dir: tmp_dir} do
    options = options(tmp_dir)
    assert Publication.manifest(options[:read_options]) == {:error, :not_found}
    assert {:ok, _published} = Publication.publish(request(), options)
    assert {:ok, body} = Publication.manifest(options[:read_options])
    assert %{"buildId" => _id} = JSON.decode!(body)
  end

  test "keeps the manifest of the intersections apart from this one's prefix" do
    refute String.starts_with?(
             Publication.manifest_prefix(),
             Gobusgo.Intersections.Publication.manifest_prefix()
           )

    refute String.starts_with?(
             Gobusgo.Intersections.Publication.manifest_prefix(),
             Publication.manifest_prefix()
           )
  end
end
