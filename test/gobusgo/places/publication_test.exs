defmodule Gobusgo.Places.PublicationTest do
  # Publishes the fixture places through the local file writer and deleter
  # into the test's temporary directory, and reads back what was stored: the
  # file by its hash-named destination and the manifest that names it.
  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.Deleter
  alias Gobusgo.Packed
  alias Gobusgo.Places.Format
  alias Gobusgo.Places.Publication
  alias Gobusgo.Test.PlaceFixture
  alias Gobusgo.Writer

  @moduletag :tmp_dir

  @built_at ~U[2026-11-10 22:00:00Z]

  defp request(places \\ PlaceFixture.places()) do
    %{source_date: PlaceFixture.source_date(), places: places, built_at: @built_at}
  end

  defp options(tmp_dir) do
    [
      write_options: [backend: Writer.LocalFile, base_dir: tmp_dir],
      delete_options: [backend: Deleter.LocalFile, base_dir: tmp_dir]
    ]
  end

  defp manifest(tmp_dir) do
    tmp_dir |> Path.join("places/manifest.json") |> File.read!() |> JSON.decode!()
  end

  test "stores the file under its hash and decodes back to the places", %{tmp_dir: tmp_dir} do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))

    assert published.file_destination =~ ~r"\Aplaces/places-[0-9a-f]{64}\.bin\.gz\z"
    stream = File.read!(Path.join(tmp_dir, published.file_destination))
    assert :crypto.hash(:sha256, stream) |> Base.encode16(case: :lower) == published.sha256
    assert {:ok, content} = Packed.expand(stream, Format.expanded_bytes_max())
    assert {:ok, %{places: places}} = Format.decode(content)
    assert length(places) == published.place_count
  end

  test "names the file in the manifest", %{tmp_dir: tmp_dir} do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))

    assert manifest(tmp_dir) == %{
             "file" => %{
               "path" => published.file_destination,
               "byteSize" => published.byte_size,
               "sha256" => published.sha256
             },
             "kind" => 5,
             "kindVersion" => 1,
             "placeCount" => 5,
             "sourceDate" => PlaceFixture.source_date(),
             "builtAt" => "2026-11-10T22:00:00Z"
           }
  end

  test "replaces the manifest of an earlier build and keeps the earlier file", %{tmp_dir: tmp_dir} do
    assert {:ok, first} = Publication.publish(request(), options(tmp_dir))

    assert {:ok, second} =
             Publication.publish(request(Enum.take(PlaceFixture.places(), 2)), options(tmp_dir))

    assert second.file_destination != first.file_destination
    assert manifest(tmp_dir)["file"]["path"] == second.file_destination
    assert File.exists?(Path.join(tmp_dir, first.file_destination))
  end

  test "publishes the same build twice", %{tmp_dir: tmp_dir} do
    assert {:ok, first} = Publication.publish(request(), options(tmp_dir))
    assert {:ok, ^first} = Publication.publish(request(), options(tmp_dir))
  end

  test "stores the stream the container's own hash names", %{tmp_dir: tmp_dir} do
    assert {:ok, published} = Publication.publish(request(), options(tmp_dir))
    stored = PlaceFixture.encode() |> Packed.stored()
    assert published.sha256 == stored.sha256
    assert published.byte_size == byte_size(Compression.compress(PlaceFixture.encode()))
  end
end
