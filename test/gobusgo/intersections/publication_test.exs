defmodule Gobusgo.Intersections.PublicationTest do
  # Publishes the fixture streets through the local file writer and deleter
  # into the test's temporary directory, and reads back what was stored: the
  # files by their hash-named destinations and the manifest that names them.
  use ExUnit.Case, async: true

  alias Gobusgo.Deleter
  alias Gobusgo.Intersections.Format
  alias Gobusgo.Intersections.Publication
  alias Gobusgo.Packed
  alias Gobusgo.Reader
  alias Gobusgo.Test.IntersectionFixture
  alias Gobusgo.Writer

  @moduletag :tmp_dir

  @built_at ~U[2026-11-10 22:00:00Z]

  defp request(streets \\ IntersectionFixture.streets()) do
    %{
      source_date: "2026-11-08T21:21:00Z",
      streets: streets,
      intersection_count: 5,
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
    do: tmp_dir |> Path.join("intersections/manifest-*.json") |> Path.wildcard() |> Enum.sort()

  defp manifest(tmp_dir) do
    tmp_dir |> manifest_files() |> List.last() |> File.read!() |> JSON.decode!()
  end

  defp expand(tmp_dir, path, kind) do
    stream = tmp_dir |> Path.join(path) |> File.read!()
    {:ok, content} = Packed.expand(stream, Format.expanded_bytes_max(kind))
    {stream, content}
  end

  test "stores each file under its hash, and the files decode back", %{tmp_dir: tmp_dir} do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))
    manifest = manifest(tmp_dir)

    assert manifest["index"]["path"] =~
             ~r"\A/intersections/intersections-index-[0-9a-f]{64}\.bin\.gz\z"

    {stream, content} = expand(tmp_dir, manifest["index"]["path"], :index)

    assert :crypto.hash(:sha256, stream) |> Base.encode16(case: :lower) ==
             manifest["index"]["sha256"]

    assert {:ok, %{entries: entries}} = Format.decode_index(content)
    assert length(entries) == published.shard_count

    name = Packed.file_name(%{kind: Format.shard_kind(), sha256: hd(entries).sha256})
    {_stream, shard} = expand(tmp_dir, "/intersections/" <> name, :shard)
    assert {:ok, %{streets: [%{key: "3RD AVE"} | _rest]}} = Format.decode_shard(shard)
  end

  test "names the shards in the manifest as the index does", %{tmp_dir: tmp_dir} do
    assert {:ok, _published} = Publication.publish(request(), options(tmp_dir))
    manifest = manifest(tmp_dir)

    {_stream, content} = expand(tmp_dir, manifest["index"]["path"], :index)
    {:ok, %{entries: entries}} = Format.decode_index(content)

    assert Enum.map(manifest["shards"], &{&1["prefix"], Path.basename(&1["path"]), &1["sha256"]}) ==
             Enum.map(entries, fn entry ->
               name = Packed.file_name(%{kind: Format.shard_kind(), sha256: entry.sha256})
               {entry.prefix, name, entry.sha256}
             end)
  end

  test "states the counts, the source, and the license in the manifest", %{tmp_dir: tmp_dir} do
    assert {:ok, _published} = Publication.publish(request(), options(tmp_dir))

    assert %{
             "attribution" => "© OpenStreetMap contributors",
             "builtAt" => "2026-11-10T22:00:00Z",
             "intersectionCount" => 5,
             "license" => %{
               "name" => "Open Database License 1.0",
               "url" => "https://opendatacommons.org/licenses/odbl/1-0/"
             },
             "sourceDate" => "2026-11-08T21:21:00Z",
             "streetCount" => 6
           } = manifest(tmp_dir)
  end

  test "stores the manifest after the files it names", %{tmp_dir: tmp_dir} do
    assert {:ok, _published} = Publication.publish(request(), options(tmp_dir))
    manifest = manifest(tmp_dir)

    for entry <- [manifest["index"] | manifest["shards"]] do
      assert File.exists?(Path.join(tmp_dir, entry["path"]))
    end
  end

  test "cuts a shard at the bound and keeps every street in a shard", %{tmp_dir: tmp_dir} do
    streets =
      for number <- 1..1_200 do
        crossings =
          for other <- 1..40 do
            %{
              other: "ROAD #{other} ST",
              lat_microdegrees: number * 1_000 + other * 10,
              lon_microdegrees: -number * 1_000
            }
          end

        key = "AVENUE#{String.pad_leading(Integer.to_string(number), 4, "0")} ST"
        %{key: key, name_key: String.replace(key, " ", ""), crossings: crossings}
      end

    assert {:ok, published} = Publication.publish(request(streets), options(tmp_dir))
    assert published.shard_count > 1
    assert Enum.all?(published.shard_expanded_byte_sizes, &(&1 <= Publication.shard_bytes_max()))

    total =
      for entry <- manifest(tmp_dir)["shards"], reduce: 0 do
        total ->
          {_stream, content} = expand(tmp_dir, entry["path"], :shard)
          {:ok, %{streets: shard_streets}} = Format.decode_shard(content)
          total + length(shard_streets)
      end

    assert total == 1_200
  end

  defp later_request do
    %{request(Enum.take(IntersectionFixture.streets(), 2)) | built_at: ~U[2026-11-11 22:00:00Z]}
  end

  test "keeps one manifest, the newest, and the earlier files", %{tmp_dir: tmp_dir} do
    assert {:ok, _first} = Publication.publish(request(), options(tmp_dir))
    first = manifest(tmp_dir)

    assert {:ok, second} = Publication.publish(later_request(), options(tmp_dir))

    assert manifest_files(tmp_dir) == [Path.join(tmp_dir, second.manifest_destination)]
    assert manifest(tmp_dir)["index"]["path"] != first["index"]["path"]
    assert File.exists?(Path.join(tmp_dir, first["index"]["path"]))
  end

  test "names a manifest by the build time and the index's hash", %{tmp_dir: tmp_dir} do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))
    sha256 = manifest(tmp_dir)["index"]["sha256"]

    assert published.manifest_destination ==
             "intersections/manifest-20261110T220000Z-#{sha256}.json"
  end

  test "reads the newest manifest through the reader", %{tmp_dir: tmp_dir} do
    assert Publication.manifest(options(tmp_dir)[:read_options]) == {:error, :not_found}
    assert {:ok, _first} = Publication.publish(request(), options(tmp_dir))
    assert {:ok, _second} = Publication.publish(later_request(), options(tmp_dir))

    assert {:ok, content} = Publication.manifest(options(tmp_dir)[:read_options])
    assert JSON.decode!(content)["builtAt"] == "2026-11-11T22:00:00Z"
  end

  test "cuts shards at the address shards' bound" do
    assert Publication.shard_bytes_max() == Gobusgo.Addresses.Build.shard_bytes_max()
  end

  test "publishes the same build twice", %{tmp_dir: tmp_dir} do
    assert {:ok, first} = Publication.publish(request(), options(tmp_dir))
    assert {:ok, ^first} = Publication.publish(request(), options(tmp_dir))
  end

  test "stores the stream the container's own hash names", %{tmp_dir: tmp_dir} do
    assert {:ok, _published} = Publication.publish(request(), options(tmp_dir))
    {_stream, content} = expand(tmp_dir, manifest(tmp_dir)["index"]["path"], :index)
    stored = Packed.stored(content)
    assert manifest(tmp_dir)["index"]["sha256"] == stored.sha256
  end
end
